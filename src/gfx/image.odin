package gfx

import "core:log"
import "core:math"

import vma "shared:vma"
import vk "vendor:vulkan"


AllocatedImage :: struct {
	image:      vk.Image,
	view:       vk.ImageView,
	extent:     vk.Extent3D,
	format:     vk.Format,
	allocation: vma.Allocation,
}

@(private)
image_subresource_range :: proc(aspect_mask: vk.ImageAspectFlags) -> vk.ImageSubresourceRange {
	return {
		aspectMask = aspect_mask,
		levelCount = vk.REMAINING_MIP_LEVELS,
		layerCount = vk.REMAINING_ARRAY_LAYERS,
	}
}

transition_image :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	current_layout, new_layout: vk.ImageLayout,
) {
	aspect_mask: vk.ImageAspectFlags = {.COLOR}

	#partial switch new_layout {
	case .DEPTH_ATTACHMENT_OPTIMAL, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL, .DEPTH_READ_ONLY_OPTIMAL:
		aspect_mask = {.DEPTH}
	case .DEPTH_STENCIL_READ_ONLY_OPTIMAL:
		aspect_mask = {.DEPTH, .STENCIL}
	}

	image_barrier: vk.ImageMemoryBarrier2 = {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.ALL_COMMANDS},
		srcAccessMask    = {.MEMORY_WRITE},
		dstStageMask     = {.ALL_GRAPHICS},
		dstAccessMask    = {.MEMORY_WRITE, .MEMORY_READ},
		oldLayout        = current_layout,
		newLayout        = new_layout,
		subresourceRange = image_subresource_range(aspect_mask),
		image            = image,
	}

	dep_info: vk.DependencyInfo = {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &image_barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dep_info)
}

copy_image_to_image :: proc(
	cmd: vk.CommandBuffer,
	src, dst: vk.Image,
	src_size, dst_size: vk.Extent2D,
) {
	blit_region: vk.ImageBlit2 = {
		sType = .IMAGE_BLIT_2,
	}

	blit_region.srcOffsets[1] = {
		x = i32(src_size.width),
		y = i32(src_size.height),
		z = 1,
	}

	blit_region.dstOffsets[1] = {
		x = i32(dst_size.width),
		y = i32(dst_size.height),
		z = 1,
	}

	blit_region.srcSubresource.aspectMask = {.COLOR}
	blit_region.srcSubresource.layerCount = 1

	blit_region.dstSubresource.aspectMask = {.COLOR}
	blit_region.dstSubresource.layerCount = 1

	blit_info: vk.BlitImageInfo2 = {
		sType          = .BLIT_IMAGE_INFO_2,
		dstImage       = dst,
		dstImageLayout = .TRANSFER_DST_OPTIMAL,
		srcImage       = src,
		srcImageLayout = .TRANSFER_SRC_OPTIMAL,
		filter         = .LINEAR,
		regionCount    = 1,
		pRegions       = &blit_region,
	}

	vk.CmdBlitImage2(cmd, &blit_info)
}

@(private)
image_create_info :: proc(
	format: vk.Format,
	usage_flags: vk.ImageUsageFlags,
	extent: vk.Extent3D,
) -> vk.ImageCreateInfo {
	return {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = format,
		extent = extent,
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = usage_flags,
	}
}

@(private)
image_view_create_info :: proc(
	format: vk.Format,
	image: vk.Image,
	aspect_flags: vk.ImageAspectFlags,
) -> vk.ImageViewCreateInfo {
	return {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image,
		viewType = .D2,
		format = format,
		subresourceRange = {
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
			aspectMask = aspect_flags,
		},
	}
}

create_image :: proc(
	r: ^RenderContext,
	size: vk.Extent3D,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	mipmapped: bool = false,
) -> (
	img: AllocatedImage,
) {
	img.format = format
	img.extent = size

	img_info := image_create_info(format, usage, size)
	if mipmapped {
		img_info.mipLevels = u32(math.floor(math.log2_f32(f32(max(size.width, size.height))))) + 1
	}

	alloc_info: vma.Allocation_Create_Info = {
		usage          = .Gpu_Only,
		required_flags = {.DEVICE_LOCAL},
	}

	vk_check(
		vma.create_image(r.allocators.gpu, img_info, alloc_info, &img.image, &img.allocation, nil),
	)

	aspect_flag: vk.ImageAspectFlags = {.DEPTH} if format == .D32_SFLOAT else {.COLOR}

	view_info := image_view_create_info(format, img.image, aspect_flag)
	view_info.subresourceRange.levelCount = img_info.mipLevels

	vk_check(vk.CreateImageView(r.device.device, &view_info, nil, &img.view))

	return
}

write_image :: proc(
	r: ^RenderContext,
	data: rawptr,
	size: vk.Extent3D,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	mipmapped: bool = false,
) -> (
	img: AllocatedImage,
) {
	data_size := u64(size.depth * size.height * size.width * 4)
	upload_buffer := create_staging_buffer(r.allocators.gpu, data_size)
	defer destroy_buffer(r.allocators.gpu, upload_buffer)

	upload_buffer_data(upload_buffer, data, int(data_size))

	img = create_image(r, size, format, usage | {.TRANSFER_SRC, .TRANSFER_DST}, mipmapped)

	cmd, ok := immediate_submit(r); if ok {
		transition_image(cmd, img.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)

		copy_region: vk.BufferImageCopy = {
			bufferOffset = 0,
			bufferRowLength = 0,
			bufferImageHeight = 0,
			imageExtent = size,
			imageSubresource = {
				aspectMask = {.COLOR},
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}

		vk.CmdCopyBufferToImage(
			cmd,
			upload_buffer.buffer,
			img.image,
			.TRANSFER_DST_OPTIMAL,
			1,
			&copy_region,
		)

		transition_image(cmd, img.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)
	}

	return
}

destroy_image :: proc(r: ^RenderContext, img: AllocatedImage) {
	vk.DestroyImageView(r.device.device, img.view, nil)
	vma.destroy_image(r.allocators.gpu, img.image, img.allocation)
}

generate_mipmaps :: proc(cmd: vk.CommandBuffer, image: vk.Image, extent: vk.Extent2D) {
	mip_levels := u32(math.floor(math.log2_f32(f32(max(extent.width, extent.height))))) + 1

	for i in 1 ..< mip_levels {
		barrier: vk.ImageMemoryBarrier2 = {
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.ALL_COMMANDS},
			srcAccessMask = {.MEMORY_WRITE},
			dstStageMask = {.ALL_COMMANDS},
			dstAccessMask = {.MEMORY_READ},
			oldLayout = .TRANSFER_DST_OPTIMAL,
			newLayout = .TRANSFER_SRC_OPTIMAL,
			image = image,
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = i - 1,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}

		dep_info: vk.DependencyInfo = {
			sType                   = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers    = &barrier,
		}

		vk.CmdPipelineBarrier2(cmd, &dep_info)

		blit: vk.ImageBlit2 = {
			sType = .IMAGE_BLIT_2,
			srcSubresource = {
				aspectMask = {.COLOR},
				mipLevel = i - 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			srcOffsets = {
				{0, 0, 0},
				{i32(extent.width >> (i - 1)), i32(extent.height >> (i - 1)), 1},
			},
			dstSubresource = {
				aspectMask = {.COLOR},
				mipLevel = i,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			dstOffsets = {{0, 0, 0}, {i32(extent.width >> i), i32(extent.height >> i), 1}},
		}

		blit_info: vk.BlitImageInfo2 = {
			sType          = .BLIT_IMAGE_INFO_2,
			srcImage       = image,
			srcImageLayout = .TRANSFER_SRC_OPTIMAL,
			dstImage       = image,
			dstImageLayout = .TRANSFER_DST_OPTIMAL,
			regionCount    = 1,
			pRegions       = &blit,
			filter         = .LINEAR,
		}

		vk.CmdBlitImage2(cmd, &blit_info)
	}

	barrier: vk.ImageMemoryBarrier2 = {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.ALL_COMMANDS},
		srcAccessMask = {.MEMORY_WRITE},
		dstStageMask = {.ALL_COMMANDS},
		dstAccessMask = {.MEMORY_READ},
		oldLayout = .TRANSFER_SRC_OPTIMAL,
		newLayout = .SHADER_READ_ONLY_OPTIMAL,
		image = image,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	dep_info: vk.DependencyInfo = {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dep_info)
}
