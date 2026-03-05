package gfx

import "core:os"
import "core:slice"

import vk "vendor:vulkan"

create_shader_module :: proc {
	create_shader_module_from_data,
	create_shader_module_from_filepath,
}

create_shader_module_from_data :: proc(
	device: vk.Device,
	code: []byte,
) -> (
	shader: vk.ShaderModule,
) {
	as_u32 := slice.reinterpret([]u32, code)
	create_info: vk.ShaderModuleCreateInfo = {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(as_u32) * size_of(u32),
		pCode    = raw_data(as_u32),
	}

	vk_check(vk.CreateShaderModule(device, &create_info, nil, &shader))
	return
}

create_shader_module_from_filepath :: proc(
	device: vk.Device,
	filepath: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	shader: vk.ShaderModule,
	ok: bool,
) {
	code := os.read_entire_file(filepath, allocator, loc) or_return
	defer delete(code)
	return create_shader_module_from_data(device, code), true
}
