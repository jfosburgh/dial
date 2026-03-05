package gfx

import "core:log"
import vma "shared:vma"
import vk "vendor:vulkan"


AllocatedImage :: struct {
	image:      vk.Image,
	view:       vk.ImageView,
	allocation: vma.Allocation,
	mip_levels: u32,
}

SampledImage :: struct {
	using allocated_image: AllocatedImage,
	sampler:               vk.Sampler,
}

create_image :: proc(
	device: vk.Device,
	image: ^AllocatedImage,
	width, height, depth: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	allocator: vma.Allocator,
	mip_levels: u32 = 1,
	msaa_samples: vk.SampleCountFlags = {._1},
) -> (
	ok: bool,
) {
	dims: int
	if width > 0 do dims += 1
	if height > 0 do dims += 1
	if depth > 0 do dims += 1

	if dims < 1 || dims > 3 {
		log.errorf(
			"image dimension must be >0 and <= 3, got %s from %dx%dx%d",
			dims,
			width,
			height,
			depth,
		)
		return
	}

	// TODO: better image support
	image_type: vk.ImageType = .D1 if dims == 1 else (.D2 if dims == 2 else .D3)
	image_view_type: vk.ImageViewType = .D1 if dims == 1 else (.D2 if dims == 2 else .D3)

	image_info: vk.ImageCreateInfo = {
		sType = .IMAGE_CREATE_INFO,
		imageType = image_type,
		format = format,
		extent = {width = width, height = height, depth = 1},
		mipLevels = mip_levels,
		arrayLayers = 1,
		samples = msaa_samples,
		tiling = .OPTIMAL,
		usage = usage,
		initialLayout = .UNDEFINED,
	}
	alloc_info: vma.Allocation_Create_Info = {
		usage = .Auto,
	}
	vk_check(
		vma.create_image(allocator, image_info, alloc_info, &image.image, &image.allocation, nil),
	)

	aspect: vk.ImageAspectFlags = {.COLOR}
	#partial switch format {
	case .D32_SFLOAT:
		aspect = {.DEPTH}
	case .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT:
		aspect = {.DEPTH, .STENCIL}
	}
	view_info: vk.ImageViewCreateInfo = {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image.image,
		viewType = image_view_type,
		format = format,
		subresourceRange = {
			aspectMask = aspect,
			layerCount = 1,
			baseArrayLayer = 0,
			levelCount = mip_levels,
			baseMipLevel = 0,
		},
	}
	vk_check(vk.CreateImageView(device, &view_info, nil, &image.view))
	image.mip_levels = mip_levels

	return true
}

generate_mipmaps :: proc(
	image: AllocatedImage,
	physical_device: vk.PhysicalDevice,
	buf: vk.CommandBuffer,
	format: vk.Format,
	#any_int width, height: u32,
) {
	properties: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(physical_device, format, &properties)
	if properties.optimalTilingFeatures & {.SAMPLED_IMAGE_FILTER_LINEAR} !=
	   {.SAMPLED_IMAGE_FILTER_LINEAR} {
		panic("texture image format does not support linear blitting")
	}

	barrier: vk.ImageMemoryBarrier = {
		sType = .IMAGE_MEMORY_BARRIER,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseArrayLayer = 0,
			layerCount = 1,
			levelCount = 1,
		},
		image = image.image,
	}

	mip_width := i32(width)
	mip_height := i32(height)

	for i in 1 ..< image.mip_levels {
		barrier.subresourceRange.baseMipLevel = i - 1
		barrier.oldLayout = .TRANSFER_DST_OPTIMAL
		barrier.newLayout = .TRANSFER_SRC_OPTIMAL
		barrier.srcAccessMask = {.TRANSFER_WRITE}
		barrier.dstAccessMask = {.TRANSFER_READ}
		vk.CmdPipelineBarrier(buf, {.TRANSFER}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)

		offsets, dst_offsets: [2]vk.Offset3D
		offsets[0] = {0, 0, 0}
		offsets[1] = {mip_width, mip_height, 1}
		dst_offsets[0] = {0, 0, 0}
		dst_offsets[1] = {
			1 if mip_width == 1 else mip_width / 2,
			1 if mip_height == 1 else mip_height / 2,
			1,
		}
		blit: vk.ImageBlit = {
			srcOffsets = offsets,
			dstOffsets = dst_offsets,
			srcSubresource = {
				aspectMask = {.COLOR},
				baseArrayLayer = 0,
				layerCount = 1,
				mipLevel = i - 1,
			},
			dstSubresource = {
				aspectMask = {.COLOR},
				baseArrayLayer = 0,
				layerCount = 1,
				mipLevel = i,
			},
		}
		vk.CmdBlitImage(
			buf,
			image.image,
			.TRANSFER_SRC_OPTIMAL,
			image.image,
			.TRANSFER_DST_OPTIMAL,
			1,
			&blit,
			.LINEAR,
		)

		barrier.oldLayout = .TRANSFER_SRC_OPTIMAL
		barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
		barrier.srcAccessMask = {.TRANSFER_READ}
		barrier.dstAccessMask = {.SHADER_READ}
		vk.CmdPipelineBarrier(
			buf,
			{.TRANSFER},
			{.FRAGMENT_SHADER},
			{},
			0,
			nil,
			0,
			nil,
			1,
			&barrier,
		)

		if mip_width > 1 do mip_width /= 2
		if mip_height > 1 do mip_height /= 2
	}

	barrier.subresourceRange.baseMipLevel = image.mip_levels - 1
	barrier.oldLayout = .TRANSFER_DST_OPTIMAL
	barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
	barrier.srcAccessMask = {.TRANSFER_READ}
	barrier.dstAccessMask = {.SHADER_READ}
	vk.CmdPipelineBarrier(buf, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)
}

transition_image :: proc(
	buf: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access_mask, dst_access_mask: vk.AccessFlags2,
	src_stage_mask, dst_stage_mask: vk.PipelineStageFlags2,
	aspect_mask: vk.ImageAspectFlags = {.COLOR},
	mip_levels: u32 = 1,
) {
	barrier: vk.ImageMemoryBarrier2 = {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage_mask,
		srcAccessMask = src_access_mask,
		dstStageMask = dst_stage_mask,
		dstAccessMask = dst_access_mask,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = aspect_mask,
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	dependency_info: vk.DependencyInfo = {
		sType                   = .DEPENDENCY_INFO,
		dependencyFlags         = {},
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}

	vk.CmdPipelineBarrier2(buf, &dependency_info)
}
