package gfx

import hm "core:container/handle_map"
import "core:log"

import vk "vendor:vulkan"


PipelineBuilder :: struct {
	shader_stages:           [dynamic]vk.PipelineShaderStageCreateInfo,
	input_assembly:          vk.PipelineInputAssemblyStateCreateInfo,
	rasterizer:              vk.PipelineRasterizationStateCreateInfo,
	color_blend_attachment:  vk.PipelineColorBlendAttachmentState,
	multisampling:           vk.PipelineMultisampleStateCreateInfo,
	layout:                  vk.PipelineLayout,
	depth_stencil:           vk.PipelineDepthStencilStateCreateInfo,
	render_info:             vk.PipelineRenderingCreateInfo,
	color_attachment_format: vk.Format,
	push_constant_range:     vk.PushConstantRange,
	descriptor_set_layout:   vk.DescriptorSetLayout,
}

pb_init :: proc(p: ^PipelineBuilder) {
	p.input_assembly = {
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
	}
	p.rasterizer = {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
	}
	p.color_blend_attachment = {}
	p.multisampling = {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
	}
	p.layout = {}
	p.depth_stencil = {
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
	}
	p.render_info = {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
	}
	p.color_attachment_format = {}
	p.shader_stages = make([dynamic]vk.PipelineShaderStageCreateInfo, r.allocators.cpu)
}

pb_destroy :: proc(p: ^PipelineBuilder) {
	pb_clear(p)
	delete(p.shader_stages)
}

pb_clear :: proc(p: ^PipelineBuilder) {
	p.input_assembly = {
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
	}
	p.rasterizer = {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
	}
	p.color_blend_attachment = {}
	p.multisampling = {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
	}
	p.layout = {}
	p.depth_stencil = {
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
	}
	p.render_info = {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
	}
	p.color_attachment_format = {}
	clear(&p.shader_stages)
}

pb_build :: proc(b: ^PipelineBuilder) -> (h: Handle) {
	p: GpuPipeline
	dynamic_states: [2]vk.DynamicState = {.VIEWPORT, .SCISSOR}
	dynamic_state: vk.PipelineDynamicStateCreateInfo = {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states[:]),
	}

	vertex_input: vk.PipelineVertexInputStateCreateInfo = {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	viewport_state: vk.PipelineViewportStateCreateInfo = {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		scissorCount  = 1,
		viewportCount = 1,
	}

	color_blend_state: vk.PipelineColorBlendStateCreateInfo = {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &b.color_blend_attachment,
	}

	pipeline_layout_info: vk.PipelineLayoutCreateInfo = {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &b.descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &b.push_constant_range,
	}
	vk_check(vk.CreatePipelineLayout(r.device, &pipeline_layout_info, nil, &p.layout))


	pipeline_info: vk.GraphicsPipelineCreateInfo = {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &b.render_info,
		stageCount          = u32(len(b.shader_stages)),
		pStages             = raw_data(b.shader_stages[:]),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &b.input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &b.rasterizer,
		pMultisampleState   = &b.multisampling,
		pColorBlendState    = &color_blend_state,
		pDynamicState       = &dynamic_state,
		layout              = p.layout,
		pDepthStencilState  = &b.depth_stencil,
	}

	vk_check(vk.CreateGraphicsPipelines(r.device, {}, 1, &pipeline_info, nil, &p.pipeline))
	p.descriptor_set_layout = b.descriptor_set_layout

	h, _ = hm.dynamic_add(&r.graphics_pipelines, p)

	return h
}

pb_add_shaders :: proc(b: ^PipelineBuilder, shaders: ..vk.PipelineShaderStageCreateInfo) {
	for stage in shaders {
		append(&b.shader_stages, stage)
	}
}

pb_clear_shaders :: proc(b: ^PipelineBuilder) {
	clear(&b.shader_stages)
}

pb_set_input_topology :: proc(b: ^PipelineBuilder, topology: vk.PrimitiveTopology) {
	b.input_assembly.topology = topology
	b.input_assembly.primitiveRestartEnable = false
}

pb_set_polygon_mode :: proc(b: ^PipelineBuilder, mode: vk.PolygonMode, width: f32 = 1) {
	b.rasterizer.polygonMode = mode
	b.rasterizer.lineWidth = width
}

pb_set_cull_mode :: proc(b: ^PipelineBuilder, mode: vk.CullModeFlags, front: vk.FrontFace) {
	b.rasterizer.cullMode = mode
	b.rasterizer.frontFace = front
}

pb_disable_multisampling :: proc(b: ^PipelineBuilder) {
	b.multisampling.sampleShadingEnable = false
	b.multisampling.rasterizationSamples = {._1}
	b.multisampling.minSampleShading = 1
	b.multisampling.pSampleMask = nil
	b.multisampling.alphaToCoverageEnable = false
	b.multisampling.alphaToOneEnable = false
}

pb_enable_multisampling :: proc(
	b: ^PipelineBuilder,
	samples: vk.SampleCountFlags,
	min_sample_shading: f32,
) {
	b.multisampling.sampleShadingEnable = true
	b.multisampling.rasterizationSamples = samples
	b.multisampling.minSampleShading = min_sample_shading
}

pb_disable_blending :: proc(b: ^PipelineBuilder) {
	b.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	b.color_blend_attachment.blendEnable = false
}

pb_enable_blending_additive :: proc(b: ^PipelineBuilder) {
	b.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	b.color_blend_attachment.blendEnable = true
	b.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
	b.color_blend_attachment.dstColorBlendFactor = .ONE
	b.color_blend_attachment.colorBlendOp = .ADD
	b.color_blend_attachment.srcAlphaBlendFactor = .ONE
	b.color_blend_attachment.dstAlphaBlendFactor = .ZERO
	b.color_blend_attachment.alphaBlendOp = .ADD
}

pb_enable_blending_alphablend :: proc(b: ^PipelineBuilder) {
	b.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	b.color_blend_attachment.blendEnable = true
	b.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
	b.color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
	b.color_blend_attachment.colorBlendOp = .ADD
	b.color_blend_attachment.srcAlphaBlendFactor = .ONE
	b.color_blend_attachment.dstAlphaBlendFactor = .ZERO
	b.color_blend_attachment.alphaBlendOp = .ADD
}

pb_set_color_format :: proc(b: ^PipelineBuilder, format: vk.Format) {
	b.color_attachment_format = format
	b.render_info.colorAttachmentCount = 1
	b.render_info.pColorAttachmentFormats = &b.color_attachment_format
}

pb_set_depth_format :: proc(b: ^PipelineBuilder, format: vk.Format) {
	b.render_info.depthAttachmentFormat = format
}

pb_disable_depth_testing :: proc(b: ^PipelineBuilder) {
	b.depth_stencil.depthTestEnable = false
	b.depth_stencil.depthWriteEnable = false
	b.depth_stencil.depthCompareOp = .NEVER
	b.depth_stencil.depthBoundsTestEnable = false
	b.depth_stencil.stencilTestEnable = false
	b.depth_stencil.front = {}
	b.depth_stencil.back = {}
	b.depth_stencil.minDepthBounds = 0
	b.depth_stencil.maxDepthBounds = 1
}

pb_enable_depth_testing :: proc(b: ^PipelineBuilder) {
	b.depth_stencil.depthTestEnable = true
	b.depth_stencil.depthWriteEnable = true
	b.depth_stencil.depthCompareOp = .LESS_OR_EQUAL
	b.depth_stencil.depthBoundsTestEnable = false
	b.depth_stencil.stencilTestEnable = false
	b.depth_stencil.front = {}
	b.depth_stencil.back = {}
	b.depth_stencil.minDepthBounds = 0
	b.depth_stencil.maxDepthBounds = 1
}

pb_clear_descriptor_set_layout :: proc(b: ^PipelineBuilder) {
	b.descriptor_set_layout = {}
}

pb_set_descriptor_set_layout :: proc(b: ^PipelineBuilder, layout: vk.DescriptorSetLayout) {
	b.descriptor_set_layout = layout
}

pb_clear_push_constants :: proc(b: ^PipelineBuilder) {
	b.push_constant_range = {}
}

pb_set_push_constants :: proc(
	b: ^PipelineBuilder,
	stage_flags: vk.ShaderStageFlags,
	pc_size: u32,
) {
	b.push_constant_range = {
		stageFlags = stage_flags,
		offset     = 0,
		size       = pc_size,
	}
}
