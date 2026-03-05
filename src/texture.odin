package dial

import "core:log"
import "core:math"
import "core:mem"
import gfx "gfx/vk"
import vma "shared:vma"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"


Texture :: struct {
	image: gfx.SampledImage,
	index: u32,
}

create_texture :: proc {
	create_texture_from_filepath,
	create_texture_from_data,
}

create_texture_from_data :: proc(
	data: rawptr,
	width, height, channels: i32,
	index: u32, // TODO: replace with auto management
	mipped := true,
	norm := false,
	filter_mode: vk.Filter = .LINEAR,
	mipmap_mode: vk.SamplerMipmapMode = .LINEAR,
) -> (
	texture: Texture,
	ok: bool,
) {
	if index >= GLOBAL_TEXTURE_LIMIT {
		log.errorf(
			"texture index %d is greater than global texture count limit (%d)",
			index,
			GLOBAL_TEXTURE_LIMIT,
		)
		return
	}
	size := width * height * channels

	format: vk.Format
	if channels == 1 do format = .R8_SRGB if !norm else .R8_UNORM
	else if channels == 2 do format = .R8G8_SRGB if !norm else .R8G8_UNORM
	else if channels == 3 do format = .R8G8B8_SRGB if !norm else .R8G8B8_UNORM
	else if channels == 4 do format = .R8G8B8A8_SRGB if !norm else .R8G8B8A8_UNORM
	else do unreachable()

	gfx.create_image(
		e.vk_ctx.device,
		&texture.image,
		u32(width),
		u32(height),
		1,
		format,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		e.vk_ctx.allocator,
		mip_levels = u32(math.floor(math.log2(f32(max(width, height))))) + 1 if mipped else 1,
	)

	staging := gfx.create_staging_buffer(e.vk_ctx.allocator, vk.DeviceSize(size))
	mem.copy(staging.mapped, data, int(size))

	if gfx.immediate_begin(e.vk_ctx.device, &e.imm_ctx.buf, &e.imm_ctx.fence, e.vk_ctx.queue) {
		gfx.transition_image(
			e.imm_ctx.buf,
			texture.image.image,
			.UNDEFINED,
			.TRANSFER_DST_OPTIMAL,
			{},
			{.TRANSFER_WRITE_KHR},
			{},
			{.TRANSFER},
			mip_levels = texture.image.mip_levels,
		)

		copy: vk.BufferImageCopy = {
			bufferOffset = 0,
			imageOffset = {0, 0, 0},
			imageExtent = {width = u32(width), height = u32(height), depth = 1},
			imageSubresource = {
				layerCount = 1,
				baseArrayLayer = 0,
				aspectMask = {.COLOR},
				mipLevel = 0,
			},
		}
		vk.CmdCopyBufferToImage(
			e.imm_ctx.buf,
			staging.buffer,
			texture.image.image,
			.TRANSFER_DST_OPTIMAL,
			1,
			&copy,
		)
	}
	gfx.destroy_buffer(staging, e.vk_ctx.allocator)

	if gfx.immediate_begin(e.vk_ctx.device, &e.imm_ctx.buf, &e.imm_ctx.fence, e.vk_ctx.queue) {
		gfx.generate_mipmaps(
			texture.image,
			e.vk_ctx.physical_device_info.device,
			e.imm_ctx.buf,
			format,
			width,
			height,
		)
	}

	sampler_info: vk.SamplerCreateInfo = {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = filter_mode,
		minFilter               = filter_mode,
		mipmapMode              = mipmap_mode,
		mipLodBias              = 0,
		minLod                  = 0,
		maxLod                  = vk.LOD_CLAMP_NONE,
		addressModeU            = .REPEAT,
		addressModeV            = .REPEAT,
		addressModeW            = .REPEAT,
		anisotropyEnable        = true,
		maxAnisotropy           = e.vk_ctx.physical_device_info.properties.limits.maxSamplerAnisotropy,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
	}
	vk_check(vk.CreateSampler(e.vk_ctx.device, &sampler_info, nil, &texture.image.sampler))

	texture.index = index
	// TODO: validate there is enough space in descriptor set
	image_info: vk.DescriptorImageInfo = {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = texture.image.view,
		sampler     = texture.image.sampler,
	}

	write: vk.WriteDescriptorSet = {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = e.global_texture_descriptor.set,
		dstBinding      = 0,
		dstArrayElement = texture.index,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &image_info,
	}

	vk.UpdateDescriptorSets(e.vk_ctx.device, 1, &write, 0, nil)

	ok = true
	return
}

create_texture_from_filepath :: proc(
	filepath: cstring,
	index: u32,
	mipped := true,
	norm := false,
	filter_mode: vk.Filter = .LINEAR,
	mipmap_mode: vk.SamplerMipmapMode = .LINEAR,
) -> (
	texture: Texture,
	ok: bool,
) #optional_ok {
	if index >= GLOBAL_TEXTURE_LIMIT {
		log.errorf(
			"texture index %d is greater than global texture count limit (%d)",
			index,
			GLOBAL_TEXTURE_LIMIT,
		)
		return
	}

	width, height, channels: i32
	data := stbi.load(filepath, &width, &height, &channels, 4)

	if data == nil {
		log.fatalf("failed to load %s", filepath)
		return
	}
	defer stbi.image_free(data)

	return create_texture_from_data(
		data,
		width,
		height,
		4,
		index,
		mipped,
		norm,
		filter_mode,
		mipmap_mode,
	)
}

destroy_texture :: proc(device: vk.Device, texture: Texture, allocator: vma.Allocator) {
	vk.DestroySampler(device, texture.image.sampler, nil)
	vk.DestroyImageView(device, texture.image.view, nil)
	vma.destroy_image(allocator, texture.image.image, texture.image.allocation)
}
