package gfx

import vk "vendor:vulkan"

DescriptorBuilder :: struct {
	bindings:            [dynamic]vk.DescriptorSetLayoutBinding,
	binding_flags:       [dynamic]vk.DescriptorBindingFlags,
	layout_create_flags: vk.DescriptorSetLayoutCreateFlags,
	pool_create_flags:   vk.DescriptorPoolCreateFlags,
}

db_init :: proc(b: ^DescriptorBuilder, allocator := context.allocator) {
	b.bindings = make([dynamic]vk.DescriptorSetLayoutBinding, allocator)
	b.binding_flags = make([dynamic]vk.DescriptorBindingFlags, allocator)
}

db_destroy :: proc(b: DescriptorBuilder) {
	delete(b.bindings)
	delete(b.binding_flags)
}

db_add_binding :: proc(
	b: ^DescriptorBuilder,
	descriptor_type: vk.DescriptorType,
	count: u32,
	shader_stage_flags: vk.ShaderStageFlags,
	binding_flags: vk.DescriptorBindingFlags,
) {
	append(
		&b.bindings,
		vk.DescriptorSetLayoutBinding {
			binding = u32(len(b.bindings)),
			descriptorType = descriptor_type,
			descriptorCount = count,
			stageFlags = shader_stage_flags,
		},
	)

	append(&b.binding_flags, binding_flags)
}

db_enable_update_after_bind :: proc(b: ^DescriptorBuilder) {
	b.layout_create_flags |= {.UPDATE_AFTER_BIND_POOL}
	b.pool_create_flags |= {.UPDATE_AFTER_BIND}
}

db_build_descriptor :: proc(
	b: ^DescriptorBuilder,
	device: vk.Device,
	multiplier: u32,
	pool: ^vk.DescriptorPool,
	set: ^vk.DescriptorSet,
	layout: ^vk.DescriptorSetLayout,
	allocator := context.allocator,
) {
	binding_flags_create_info: vk.DescriptorSetLayoutBindingFlagsCreateInfo = {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(b.binding_flags)),
		pBindingFlags = raw_data(b.binding_flags[:]),
	}

	layout_info: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &binding_flags_create_info,
		bindingCount = u32(len(b.bindings)),
		pBindings    = raw_data(b.bindings[:]),
		flags        = b.layout_create_flags,
	}

	vk_check(vk.CreateDescriptorSetLayout(device, &layout_info, nil, layout))

	pool_sizes := make([]vk.DescriptorPoolSize, len(b.bindings), allocator)
	defer delete(pool_sizes)

	for binding, i in b.bindings {
		pool_sizes[i] = {
			descriptorCount = multiplier * binding.descriptorCount,
			type            = binding.descriptorType,
		}
	}

	pool_info: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = b.pool_create_flags,
		maxSets       = 1,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes[:]),
	}
	vk_check(vk.CreateDescriptorPool(device, &pool_info, nil, pool))

	alloc_info: vk.DescriptorSetAllocateInfo = {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = pool^,
		descriptorSetCount = 1,
		pSetLayouts        = layout,
	}
	vk_check(vk.AllocateDescriptorSets(device, &alloc_info, set))
}
