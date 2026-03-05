package gfx

import vma "shared:vma"
import vk "vendor:vulkan"


AllocatedBuffer :: struct {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	address:    vk.DeviceAddress,
	mapped:     rawptr,
}

create_buffer :: proc(buffer: ^AllocatedBuffer, size: u32, usage: vk.BufferUsageFlags) {
	buf_info: vk.BufferCreateInfo = {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(size),
		usage = usage,
	}
	alloc_info: vma.Allocation_Create_Info = {
		usage = .Auto,
	}
	if .TRANSFER_DST in usage {
		alloc_info.flags |= {.Mapped, .Host_Access_Sequential_Write}
	}
	vk_check(
		vma.create_buffer(
			r.allocators.gpu,
			buf_info,
			alloc_info,
			&buffer.buffer,
			&buffer.allocation,
			nil,
		),
	)

	if .Mapped in alloc_info.flags {
		vma.map_memory(r.allocators.gpu, buffer.allocation, &buffer.mapped)
	}

	if .SHADER_DEVICE_ADDRESS in usage {
		address_info: vk.BufferDeviceAddressInfo = {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = buffer.buffer,
		}
		buffer.address = vk.GetBufferDeviceAddress(r.device, &address_info)
	}
}

create_staging_buffer :: proc(
	allocator: vma.Allocator,
	size: vk.DeviceSize,
) -> (
	buf: AllocatedBuffer,
) {
	buf_info: vk.BufferCreateInfo = {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(size),
		usage = {.TRANSFER_SRC},
	}
	alloc_info: vma.Allocation_Create_Info = {
		flags = {.Host_Access_Sequential_Write, .Mapped},
		usage = .Auto,
	}
	vk_check(vma.create_buffer(allocator, buf_info, alloc_info, &buf.buffer, &buf.allocation, nil))
	vk_check(vma.map_memory(allocator, buf.allocation, &buf.mapped))

	return
}

destroy_buffer :: proc(buffer: AllocatedBuffer, allocator: vma.Allocator) {
	vma.unmap_memory(allocator, buffer.allocation)
	vma.destroy_buffer(allocator, buffer.buffer, buffer.allocation)
}
