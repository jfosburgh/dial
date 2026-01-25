package gfx

import "core:mem"
import "shared:vma"
import vk "vendor:vulkan"


AllocatedBuffer :: struct {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	info:       vma.Allocation_Info,
}

create_buffer :: proc(
	allocator: vma.Allocator,
	alloc_size: u64,
	usage: vk.BufferUsageFlags,
	memory_usage: vma.Memory_Usage,
) -> AllocatedBuffer {
	buffer_info: vk.BufferCreateInfo = {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(alloc_size),
		usage = usage,
	}

	vma_alloc_info: vma.Allocation_Create_Info = {
		usage = memory_usage,
		flags = {.Mapped},
	}

	new_buffer: AllocatedBuffer
	vk_check(
		vma.create_buffer(
			allocator,
			buffer_info,
			vma_alloc_info,
			&new_buffer.buffer,
			&new_buffer.allocation,
			&new_buffer.info,
		),
	)

	return new_buffer
}

destroy_buffer :: proc(allocator: vma.Allocator, buffer: AllocatedBuffer) {
	vma.destroy_buffer(allocator, buffer.buffer, buffer.allocation)
}

create_staging_buffer :: proc(allocator: vma.Allocator, size: u64) -> AllocatedBuffer {
	return create_buffer(allocator, size, {.TRANSFER_SRC}, .Cpu_To_Gpu)
}

upload_buffer_data :: proc(buffer: AllocatedBuffer, data: rawptr, size: int) {
	assert(buffer.info.mapped_data != nil, "Buffer must be mapped")
	mem.copy(buffer.info.mapped_data, data, size)
}
