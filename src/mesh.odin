package dial

import "core:log"
import "core:mem"
import gfx "gfx/vk"
import vk "vendor:vulkan"

Mesh :: struct {
	buffer:       gfx.AllocatedBuffer,
	index_offset: vk.DeviceSize,
	index_count:  u32,
}

create_mesh :: proc(vertices: []$Vertex, indices: []u32) -> (mesh: Mesh) {
	vertex_size := size_of(Vertex) * len(vertices)
	index_size := size_of(u32) * len(indices)

	mesh.index_offset = vk.DeviceSize(vertex_size)
	mesh.index_count = u32(len(indices))

	gfx.create_buffer(
		&mesh.buffer,
		u32(vertex_size + index_size),
		{.STORAGE_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS},
	)

	mem.copy(mesh.buffer.mapped, rawptr(&vertices[0]), int(vertex_size))

	target := rawptr(uintptr(mesh.buffer.mapped) + uintptr(mesh.index_offset))
	mem.copy(target, rawptr(&indices[0]), int(index_size))

	log.debugf("uploaded %d vertices and %d indices", len(vertices), len(indices))
	return
}

destroy_mesh :: proc(mesh: Mesh) {
	gfx.destroy_buffer(mesh.buffer, e.vk_ctx.allocator)
}
