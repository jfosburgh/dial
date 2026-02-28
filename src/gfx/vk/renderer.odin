package gfx

import "base:runtime"
import hm "core:container/handle_map"
import "core:log"
import "core:math"
import glm "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:time"

import obj "../../loaders/tinyobj"
import "shared:vma"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720

FRAMES_IN_FLIGHT :: 2
MAX_MODELS :: 128
MAX_UI_ELEMENTS :: 1024

// TODO: make this dynamic
MAX_INDIRECT_DRAW :: 1024

MODEL_PATH :: "assets/models/viking_room/viking_room.obj"
TEXTURE_IMAGE :: "assets/models/viking_room/viking_room.png"
DEFAULT_GRAPHICS_SHADER :: "./default_shaders/vertex_pulling_bda.spv"
DEFAULT_UI_SHADER :: "./default_shaders/ui.spv"
FONT_PATH :: "assets/fonts/iosevka.ttf"

ENABLE_DEBUG_MESSENGER :: true

REQUIRED_DEVICE_EXTENSIONS := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
MSAA_LIMIT :: 8

WindowConfig :: struct {
	window_title, app_id: cstring,
	width, height:        i32,
	window_flags:         sdl.WindowFlags,
}

Allocators :: struct {
	cpu:  runtime.Allocator,
	gpu:  vma.Allocator,
	temp: runtime.Allocator,
}

Swapchain :: struct {
	handle:     vk.SwapchainKHR,
	format:     vk.Format,
	extent:     vk.Extent2D,
	images:     []vk.Image,
	views:      []vk.ImageView,
	semaphores: []vk.Semaphore,
}

FrameData :: struct {
	buffer:    vk.CommandBuffer,
	semaphore: vk.Semaphore,
	fence:     vk.Fence,
}

RenderTarget :: struct {
	color:        AllocatedImage,
	depth:        AllocatedImage,
	color_format: vk.Format,
	depth_format: vk.Format,
}

FrameDrawInfo :: struct {
	models:      [dynamic]Model,
	ui_elements: [dynamic]UiData,
}

Renderer :: struct {
	allocators:                    Allocators,
	odin_ctx:                      runtime.Context,
	window:                        ^sdl.Window,
	instance:                      vk.Instance,
	debug_messenger:               vk.DebugUtilsMessengerEXT,
	physical_device:               vk.PhysicalDevice,
	device:                        vk.Device,
	surface:                       vk.SurfaceKHR,
	graphics_queue:                vk.Queue,
	graphics_index, present_index: u32,
	swapchain:                     Swapchain,
	descriptor_pool:               vk.DescriptorPool,
	command_pool:                  vk.CommandPool,
	frames:                        [FRAMES_IN_FLIGHT]FrameData,
	frame_index:                   uint,
	resize_requested:              bool,
	start_time:                    time.Time,
	render_target:                 RenderTarget,
	// ui_target:                     UITarget,
	msaa_samples:                  vk.SampleCountFlags,
	meshes:                        hm.Dynamic_Handle_Map(GpuMesh, Handle),
	textures:                      hm.Dynamic_Handle_Map(GpuTexture, Handle),
	graphics_pipelines:            hm.Dynamic_Handle_Map(GpuPipeline, Handle),
	default_pipeline:              Handle,
	ui_pipeline:                   Handle,
	object_buffers:                [FRAMES_IN_FLIGHT]AllocatedBuffer,
	ui_buffers:                    [FRAMES_IN_FLIGHT]AllocatedBuffer,
	indirect_buffers:              [FRAMES_IN_FLIGHT]AllocatedBuffer,
	global_data_buffers:           [FRAMES_IN_FLIGHT]AllocatedBuffer,
	global_descriptor_set:         vk.DescriptorSet,
	global_descriptor_set_layout:  vk.DescriptorSetLayout,
	draw_info:                     FrameDrawInfo,
}

r: ^Renderer

AllocatedBuffer :: struct {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	address:    vk.DeviceAddress,
	mapped:     rawptr,
}

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

Vertex :: struct {
	pos:   [3]f32,
	_p1:   f32,
	color: [3]f32,
	_p2:   f32,
	tex:   [2]f32,
	_p3:   [2]f32,
}

Handle :: struct {
	idx, gen: u32,
}

GpuMesh :: struct {
	buffer:       AllocatedBuffer,
	index_offset: vk.DeviceSize,
	index_count:  u32,
	handle:       Handle,
}

GpuTexture :: struct {
	image:  SampledImage,
	id:     u32,
	handle: Handle,
}

GpuPipeline :: struct {
	pipeline:              vk.Pipeline,
	layout:                vk.PipelineLayout,
	descriptor_set_layout: vk.DescriptorSetLayout,
	handle:                Handle,
}

Material :: struct {
	texture:  Handle,
	pipeline: Handle,
}

Model :: struct {
	pos, rot, scale: [3]f32,
	mesh:            Handle,
	material:        Material,
}

ObjectData :: struct {
	model:                         matrix[4, 4]f32,
	texture_id:                    u32,
	_p1:                           u32,
	vertex_address, index_address: vk.DeviceAddress,
	_p2:                           [2]u32,
}

GlobalData :: struct {
	view_proj: matrix[4, 4]f32,
}

PushConstant :: struct {
	global_data_address:   vk.DeviceAddress,
	object_buffer_address: vk.DeviceAddress,
}

CameraData :: struct {
	view, proj: matrix[4, 4]f32,
}

@(deferred_none = end_drawing)
begin_drawing :: proc() -> bool {
	r.draw_info.models = make([dynamic]Model, r.allocators.temp)
	r.draw_info.ui_elements = make([dynamic]UiData, r.allocators.temp)
	return true
}

end_drawing :: proc() {
	slice.sort_by(r.draw_info.models[:], proc(i, j: Model) -> bool {
		return(
			i.material.pipeline.idx < j.material.pipeline.idx &&
			i.material.pipeline.gen == j.material.pipeline.gen \
		)
	})
	draw_frame()
	delete(r.draw_info.models)
	delete(r.draw_info.ui_elements)
}

default_pipeline :: proc() -> Handle {
	return r.default_pipeline
}

elapsed_seconds :: proc() -> f32 {
	return f32(time.duration_seconds(time.since(r.start_time)))
}

draw_model :: proc(mesh: Handle, material: Material, pos, rot, scale: [3]f32) {
	append(&r.draw_info.models, Model{pos, rot, scale, mesh, material})
}

get_model_matrix :: proc(model: Model) -> glm.Matrix4f32 {
	m := glm.MATRIX4F32_IDENTITY
	m *= glm.matrix4_translate(model.pos)
	m *= glm.matrix4_rotate(model.rot.x, [3]f32{1, 0, 0})
	m *= glm.matrix4_rotate(model.rot.y, [3]f32{0, 1, 0})
	m *= glm.matrix4_rotate(model.rot.z, [3]f32{0, 0, 1})
	m *= glm.matrix4_scale(model.scale)

	return m
}

create_gpu_mesh :: proc(vertices: []Vertex, indices: []u32) -> (handle: Handle) {
	mesh: GpuMesh
	vertex_size := size_of(Vertex) * len(vertices)
	index_size := size_of(u32) * len(indices)
	mesh.index_offset = vk.DeviceSize(vertex_size)
	mesh.index_count = u32(len(indices))

	create_buffer(
		&mesh.buffer,
		u32(vertex_size + index_size),
		{.STORAGE_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS},
	)

	mem.copy(mesh.buffer.mapped, rawptr(&vertices[0]), int(vertex_size))

	target := rawptr(uintptr(mesh.buffer.mapped) + uintptr(mesh.index_offset))
	mem.copy(target, rawptr(&indices[0]), int(index_size))

	log.debugf("uploaded %d vertices and %d indices", len(vertices), len(indices))

	handle, _ = hm.dynamic_add(&r.meshes, mesh)
	return
}

destroy_gpu_mesh :: proc(mesh: GpuMesh) {
	vma.unmap_memory(r.allocators.gpu, mesh.buffer.allocation)
	vma.destroy_buffer(r.allocators.gpu, mesh.buffer.buffer, mesh.buffer.allocation)
}

load_model :: proc(filepath: string) -> ([]Vertex, []u32) {
	local_vertices := make([dynamic]Vertex, r.allocators.cpu)
	defer delete(local_vertices)
	local_indices := make([dynamic]u32, r.allocators.cpu)
	defer delete(local_indices)
	vert_map := make(map[Vertex]u32, r.allocators.cpu)
	defer delete(vert_map)

	model := obj.load_from_filepath(filepath, r.allocators.cpu)
	for tri in model.tris {
		for tri_vert in tri {
			v: Vertex

			v.pos = model.vertices[tri_vert.x - 1].xyz
			v.tex = model.tex_coords[tri_vert.y - 1].xy
			v.tex.y = 1 - v.tex.y

			if _, ok := vert_map[v]; !ok {
				vert_map[v] = u32(len(local_vertices))
				append(&local_vertices, v)
			}
			append(&local_indices, vert_map[v])
		}
	}

	log.debugf("loaded model from %s", filepath)

	return slice.clone(
		local_vertices[:],
		r.allocators.cpu,
	), slice.clone(local_indices[:], r.allocators.cpu)
}

vk_check :: proc(res: vk.Result, loc := #caller_location) {
	#partial switch res {
	case .SUCCESS:
	case:
		log.fatalf("Vulkan Error: %v", res, loc)
	}
}

// from Odin Vulkan example
// https://github.com/odin-lang/examples/blob/master/vulkan/triangle_glfw/main.odin
@(private)
vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = r.odin_ctx

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}

@(private)
log_sdl :: proc() {
	log.errorf("SDL Error: %s", sdl.GetError())
}

@(private)
current_frame :: proc() -> uint {
	return r.frame_index % FRAMES_IN_FLIGHT
}

request_resize :: proc() {
	r.resize_requested = true
}

@(private)
init_window :: proc(c: WindowConfig) -> (ok: bool) {
	sdl.SetAppMetadataProperty(sdl.PROP_APP_METADATA_IDENTIFIER_STRING, c.app_id) or_return
	sdl.Init({.VIDEO, .EVENTS}) or_return
	defer if !ok do sdl.Quit()

	sdl.Vulkan_LoadLibrary(nil) or_return
	defer if !ok do sdl.Vulkan_UnloadLibrary()

	vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))
	r.window = sdl.CreateWindow(c.window_title, c.width, c.height, c.window_flags)
	if r.window == nil {
		log_sdl()
		return false
	}

	return true
}

@(private)
destroy_window :: proc() {
	sdl.DestroyWindow(r.window)
	sdl.Quit()
}

@(private)
create_instance :: proc() -> (ok: bool) {
	app_info: vk.ApplicationInfo = {
		sType              = .APPLICATION_INFO,
		apiVersion         = vk.API_VERSION_1_4,
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "Dial",
		pApplicationName   = "com.boondax.dial",
	}

	create_info: vk.InstanceCreateInfo = {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app_info,
	}

	sdl_extension_count: u32
	sdl_extensions := sdl.Vulkan_GetInstanceExtensions(&sdl_extension_count)

	required_extensions := slice.clone_to_dynamic(
		sdl_extensions[:sdl_extension_count],
		r.allocators.cpu,
	)
	defer delete(required_extensions)

	debug_create_info: vk.DebugUtilsMessengerCreateInfoEXT
	when ENABLE_DEBUG_MESSENGER {
		create_info.ppEnabledLayerNames = raw_data([]cstring{"VK_LAYER_KHRONOS_validation"})
		create_info.enabledLayerCount = 1

		append(&required_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}
		// if context.logger.lowest_level <= .Info {
		// 	severity |= {.INFO}
		// }
		// if context.logger.lowest_level <= .Debug {
		// 	severity |= {.VERBOSE}
		// }

		debug_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = severity,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = vk_messenger_callback,
		}
		create_info.pNext = &debug_create_info
	}

	supported_extension_count: u32
	vk_check(vk.EnumerateInstanceExtensionProperties(nil, &supported_extension_count, nil))
	supported_extensions := make(
		[]vk.ExtensionProperties,
		supported_extension_count,
		r.allocators.cpu,
	)
	defer delete(supported_extensions)
	vk_check(
		vk.EnumerateInstanceExtensionProperties(
			nil,
			&supported_extension_count,
			raw_data(supported_extensions),
		),
	)

	for required_extension in required_extensions {
		found := false
		for &supported_extension in supported_extensions {
			if cstring(raw_data(supported_extension.extensionName[:])) == required_extension {
				found = true
				break
			}
		}

		if !found {
			log.fatalf("Required extension not found: %s", required_extension)
		}
	}

	create_info.enabledExtensionCount = u32(len(required_extensions))
	create_info.ppEnabledExtensionNames = raw_data(required_extensions)

	log.debug("creating instance")
	vk_check(vk.CreateInstance(&create_info, nil, &r.instance))
	defer if !ok do vk.DestroyInstance(r.instance, nil)
	log.debug("created instance")

	vk.load_proc_addresses_instance(r.instance)

	when ENABLE_DEBUG_MESSENGER {
		log.debug("creating debug messenger")
		vk_check(
			vk.CreateDebugUtilsMessengerEXT(
				r.instance,
				&debug_create_info,
				nil,
				&r.debug_messenger,
			),
		)
		log.debug("Debug messenger created")
	}

	defer if !ok {
		when ENABLE_DEBUG_MESSENGER {
			vk.DestroyDebugUtilsMessengerEXT(r.instance, r.debug_messenger, nil)
		}
	}

	if !sdl.Vulkan_CreateSurface(r.window, r.instance, nil, &r.surface) {
		log_sdl()
		return
	}

	return true
}

@(private)
destroy_instance :: proc() {
	sdl.Vulkan_DestroySurface(r.instance, r.surface, nil)
	when ENABLE_DEBUG_MESSENGER {
		vk.DestroyDebugUtilsMessengerEXT(r.instance, r.debug_messenger, nil)
	}
	vk.DestroyInstance(r.instance, nil)
}

SwapchainSupport :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

@(private)
query_swapchain_support :: proc(
	device: vk.PhysicalDevice,
) -> (
	support: SwapchainSupport,
	ok: bool,
) {
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, r.surface, &support.capabilities) != .SUCCESS do return support, false

	{
		count: u32
		if vk.GetPhysicalDeviceSurfaceFormatsKHR(device, r.surface, &count, nil) != .SUCCESS do return support, false

		support.formats = make([]vk.SurfaceFormatKHR, count, r.allocators.cpu)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, r.surface, &count, raw_data(support.formats))
	}
	defer if !ok do delete(support.formats)

	{
		count: u32
		if vk.GetPhysicalDeviceSurfacePresentModesKHR(device, r.surface, &count, nil) != .SUCCESS do return support, false

		support.present_modes = make([]vk.PresentModeKHR, count, r.allocators.cpu)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			r.surface,
			&count,
			raw_data(support.present_modes),
		)
	}

	return support, true
}

QueueFamilyIndices :: struct {
	compute:  Maybe(u32),
	graphics: Maybe(u32),
	present:  Maybe(u32),
	transfer: Maybe(u32),
}

@(private)
find_queue_families :: proc(
	device: vk.PhysicalDevice,
) -> (
	indices: QueueFamilyIndices,
	ok: bool,
) #optional_ok {
	queue_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_count, nil)

	families := make([]vk.QueueFamilyProperties, queue_count, r.allocators.cpu)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_count, raw_data(families))

	for family, i in families {
		if .COMPUTE in family.queueFlags &&
		   .GRAPHICS in family.queueFlags &&
		   .TRANSFER in family.queueFlags {
			present_supported: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), r.surface, &present_supported)
			if present_supported {
				index := u32(i)
				indices = {index, index, index, index}
				return indices, true
			}
		}

		// if _, ok := indices.compute.?; !ok && .COMPUTE in family.queueFlags {
		// 	indices.compute = u32(i)
		// }
		// if _, ok := indices.graphics.?; !ok && .GRAPHICS in family.queueFlags {
		// 	indices.graphics = u32(i)
		// }
		// if _, ok := indices.transfer.?; !ok && .TRANSFER in family.queueFlags {
		// 	indices.transfer = u32(i)
		// }
		//
		// if _, ok := indices.present.?; !ok {
		// 	present_supported: b32
		// 	vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), r.surface, &present_supported)
		//
		// 	if present_supported do indices.present = u32(i)
		// }
		//
		// _, has_compute := indices.compute.?
		// _, has_graphics := indices.graphics.?
		// _, has_transfer := indices.transfer.?
		// _, has_present := indices.present.?
		//
		// if has_compute && has_graphics && has_transfer && has_present {
		// 	ok = true
		// 	break
		// }
	}

	return
}

@(private)
score_physical_device :: proc(device: vk.PhysicalDevice) -> (score: int) {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(device, &properties)
	device_name := cstring(raw_data(properties.deviceName[:]))

	features: vk.PhysicalDeviceFeatures
	vk.GetPhysicalDeviceFeatures(device, &features)

	if !features.samplerAnisotropy {
		log.debugf("device %s does not support sampler anisotropy: %s", device_name)
		return 0
	}

	device_ext_count: u32
	if vk.EnumerateDeviceExtensionProperties(device, nil, &device_ext_count, nil) != .SUCCESS do return 0

	device_extensions := make([]vk.ExtensionProperties, device_ext_count, r.allocators.cpu)
	vk.EnumerateDeviceExtensionProperties(
		device,
		nil,
		&device_ext_count,
		raw_data(device_extensions),
	)

	required_loop: for required in REQUIRED_DEVICE_EXTENSIONS {
		for &extension in device_extensions {
			if cstring(raw_data(extension.extensionName[:])) == required do continue required_loop
		}

		log.debugf("device %s does not support extension: %s", device_name, required)
		return 0
	}

	if swapchain_support, ok := query_swapchain_support(device); ok {
		defer {
			delete(swapchain_support.present_modes)
			delete(swapchain_support.formats)
		}

		if len(swapchain_support.formats) == 0 || len(swapchain_support.present_modes) == 0 {
			log.debugf("device %s does not support swapchain", device_name)
			return 0
		}
	} else do return 0

	if queue_indices, ok := find_queue_families(device); !ok {
		log.debugf(
			"device %s does not have required queue families: %v",
			device_name,
			queue_indices,
		)
		return 0
	}

	switch properties.deviceType {
	case .DISCRETE_GPU:
		score += 300_000
	case .INTEGRATED_GPU:
		score += 200_000
	case .VIRTUAL_GPU:
		score += 100_000
	case .CPU, .OTHER:
	}

	score += int(properties.limits.maxImageDimension2D)

	log.debugf("Device %s - score: %i", device_name, score)

	return score
}

@(private)
get_max_usable_sample_count :: proc() -> vk.SampleCountFlag {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(r.physical_device, &properties)
	counts := properties.limits.framebufferColorSampleCounts

	if ._64 in counts && 64 <= MSAA_LIMIT {
		return ._64
	} else if ._32 in counts && 32 <= MSAA_LIMIT {
		return ._32
	} else if ._16 in counts && 16 <= MSAA_LIMIT {
		return ._16
	} else if ._8 in counts && 8 <= MSAA_LIMIT {
		return ._8
	} else if ._4 in counts && 4 <= MSAA_LIMIT {
		return ._4
	} else if ._2 in counts && 2 <= MSAA_LIMIT {
		return ._2
	}

	return ._1
}

@(private)
pick_physical_device :: proc() -> (ok: bool) {
	physical_device_count: u32
	vk_check(vk.EnumeratePhysicalDevices(r.instance, &physical_device_count, nil))
	if physical_device_count == 0 {
		log.fatalf("Failed to find a device that supports Vulkan")
		return false
	}

	devices := make([]vk.PhysicalDevice, physical_device_count, r.allocators.cpu)
	vk_check(vk.EnumeratePhysicalDevices(r.instance, &physical_device_count, raw_data(devices)))

	best_score := -1
	for device in devices {
		if score_physical_device(device) > best_score {
			r.physical_device = device
			r.msaa_samples = {get_max_usable_sample_count()}
		}
	}

	if r.physical_device == nil {
		log.fatalf("No suitable devices found")
		return false
	}

	return true
}

// TODO: [potential] add more queues
@(private)
create_logical_device :: proc() -> (ok: bool) {
	indices := find_queue_families(r.physical_device) or_return
	r.graphics_index = indices.graphics.? or_return
	r.present_index = indices.present.? or_return
	priority: f32 = 0.5

	device_queue_create_info: vk.DeviceQueueCreateInfo = {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueCount       = 1,
		queueFamilyIndex = r.graphics_index,
		pQueuePriorities = &priority,
	}

	device_features: vk.PhysicalDeviceFeatures = {
		samplerAnisotropy = true,
		sampleRateShading = true,
		multiDrawIndirect = true,
		shaderInt64       = true,
	}

	extended_dynamic_features: vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT = {
		sType                = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
		extendedDynamicState = true,
	}

	features_1_4: vk.PhysicalDeviceVulkan14Features = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
		pNext = &extended_dynamic_features,
	}

	features_1_3: vk.PhysicalDeviceVulkan13Features = {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &features_1_4,
		dynamicRendering = true,
		synchronization2 = true,
	}

	features_1_2: vk.PhysicalDeviceVulkan12Features = {
		sType                                        = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext                                        = &features_1_3,
		bufferDeviceAddress                          = true,
		descriptorIndexing                           = true,
		runtimeDescriptorArray                       = true,
		descriptorBindingPartiallyBound              = true,
		descriptorBindingVariableDescriptorCount     = true,
		shaderSampledImageArrayNonUniformIndexing    = true,
		descriptorBindingSampledImageUpdateAfterBind = true,
	}

	features_1_1: vk.PhysicalDeviceVulkan11Features = {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext                = &features_1_2,
		shaderDrawParameters = true,
	}

	device_create_info: vk.DeviceCreateInfo = {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features_1_1,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &device_queue_create_info,
		pEnabledFeatures        = &device_features,
		enabledExtensionCount   = u32(len(REQUIRED_DEVICE_EXTENSIONS)),
		ppEnabledExtensionNames = raw_data(REQUIRED_DEVICE_EXTENSIONS),
	}

	vk_check(vk.CreateDevice(r.physical_device, &device_create_info, nil, &r.device))
	vk.load_proc_addresses_device(r.device)
	vk.GetDeviceQueue(r.device, r.graphics_index, 0, &r.graphics_queue)

	return true
}

@(private)
destroy_logical_device :: proc() {
	vk.DestroyDevice(r.device, nil)
}

@(private)
create_vma :: proc() -> (ok: bool) {
	vma_vulkan_functions := vma.create_vulkan_functions()
	vma_vulkan_functions.get_physical_device_memory_properties2_khr =
		vk.GetPhysicalDeviceMemoryProperties2
	vma_vulkan_functions.get_buffer_memory_requirements2_khr = vk.GetBufferMemoryRequirements2
	vma_vulkan_functions.get_image_memory_requirements2_khr = vk.GetImageMemoryRequirements2
	vma_vulkan_functions.bind_buffer_memory2_khr = vk.BindBufferMemory2
	vma_vulkan_functions.bind_image_memory2_khr = vk.BindImageMemory2

	allocator_create_info: vma.Allocator_Create_Info = {
		flags              = {.Buffer_Device_Address},
		instance           = r.instance,
		vulkan_api_version = vk.API_VERSION_1_4,
		physical_device    = r.physical_device,
		device             = r.device,
		vulkan_functions   = &vma_vulkan_functions,
	}

	vk_check(vma.create_allocator(allocator_create_info, &r.allocators.gpu))

	return true
}

@(private)
destroy_vma :: proc() {
	vma.destroy_allocator(r.allocators.gpu)
}

@(private)
choose_swapchain_surface_format :: proc(
	supported_formats: []vk.SurfaceFormatKHR,
) -> vk.SurfaceFormatKHR {
	for format in supported_formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR do return format
	}
	return supported_formats[0]
}

@(private)
choose_swapchain_present_mode :: proc(present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for mode in present_modes {
		if mode == .MAILBOX do return mode
	}
	return .FIFO
}

@(private)
choose_swapchain_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) do return capabilities.currentExtent

	width, height: i32
	if !sdl.GetWindowSize(r.window, &width, &height) {
		log_sdl()
		return {}
	}

	return {
		clamp(u32(width), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
		clamp(u32(height), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
	}
}

@(private)
create_swapchain :: proc() -> (ok: bool) {
	support := query_swapchain_support(r.physical_device) or_return
	defer {
		delete(support.formats)
		delete(support.present_modes)
	}

	format := choose_swapchain_surface_format(support.formats)
	present_mode := choose_swapchain_present_mode(support.present_modes)
	extent := choose_swapchain_extent(support.capabilities)
	if extent.height == 0 || extent.height == 0 do return

	image_count := support.capabilities.minImageCount + 1
	image_count =
		support.capabilities.maxImageCount if support.capabilities.maxImageCount > 0 && support.capabilities.maxImageCount > image_count else image_count

	swapchain_create_info: vk.SwapchainCreateInfoKHR = {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = r.surface,
		presentMode      = present_mode,
		imageExtent      = extent,
		imageFormat      = format.format,
		imageColorSpace  = format.colorSpace,
		minImageCount    = image_count,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT}, // TODO: change to TRANSFER if using separate render target
		imageSharingMode = .EXCLUSIVE,
		preTransform     = support.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		clipped          = true,
	}

	indices: [2]u32 = {r.graphics_index, r.present_index}
	if r.graphics_index != r.present_index {
		swapchain_create_info.imageSharingMode = .CONCURRENT
		swapchain_create_info.queueFamilyIndexCount = 2
		swapchain_create_info.pQueueFamilyIndices = raw_data(indices[:])
	}

	vk_check(vk.CreateSwapchainKHR(r.device, &swapchain_create_info, nil, &r.swapchain.handle))
	defer if !ok do vk.DestroySwapchainKHR(r.device, r.swapchain.handle, nil)

	vk_check(vk.GetSwapchainImagesKHR(r.device, r.swapchain.handle, &image_count, nil))
	r.swapchain.images = make([]vk.Image, image_count, r.allocators.cpu)
	vk_check(
		vk.GetSwapchainImagesKHR(
			r.device,
			r.swapchain.handle,
			&image_count,
			raw_data(r.swapchain.images),
		),
	)

	r.swapchain.extent = extent
	r.swapchain.format = format.format

	return true
}

@(private)
destroy_swapchain :: proc() {
	delete(r.swapchain.images)
	vk.DestroySwapchainKHR(r.device, r.swapchain.handle, nil)
}

@(private)
create_swapchain_data :: proc() -> (ok: bool) {
	image_view_create_info: vk.ImageViewCreateInfo = {
		sType = .IMAGE_VIEW_CREATE_INFO,
		format = r.swapchain.format,
		viewType = .D2,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseArrayLayer = 0,
			baseMipLevel = 0,
			layerCount = 1,
			levelCount = 1,
		},
		components = {a = .IDENTITY, b = .IDENTITY, g = .IDENTITY, r = .IDENTITY},
	}

	r.swapchain.views = make([]vk.ImageView, len(r.swapchain.images), r.allocators.cpu)
	r.swapchain.semaphores = make([]vk.Semaphore, len(r.swapchain.images), r.allocators.cpu)
	for i in 0 ..< len(r.swapchain.images) {
		image_view_create_info.image = r.swapchain.images[i]
		vk_check(vk.CreateImageView(r.device, &image_view_create_info, nil, &r.swapchain.views[i]))
		vk_check(
			vk.CreateSemaphore(
				r.device,
				&vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO},
				nil,
				&r.swapchain.semaphores[i],
			),
		)
	}

	return true
}

@(private)
destroy_swapchain_data :: proc() {
	for view in r.swapchain.views {
		vk.DestroyImageView(r.device, view, nil)
	}
	for semaphore in r.swapchain.semaphores {
		vk.DestroySemaphore(r.device, semaphore, nil)
	}
	delete(r.swapchain.views)
	delete(r.swapchain.semaphores)
}

@(private)
recreate_swapchain :: proc() {
	width, height: i32
	sdl.GetWindowSize(r.window, &width, &height)
	if width == 0 || height == 0 {
		log.debug("window minimized, waiting")
	}

	for width == 0 || height == 0 {
		sdl.GetWindowSize(r.window, &width, &height)
		for sdl.WaitEvent(nil) {}
	}

	log.debugf("resizing swapchain to %dx%d", width, height)
	vk_check(vk.DeviceWaitIdle(r.device))

	destroy_depth_resources()
	destroy_color_resources()
	destroy_swapchain_data()
	destroy_swapchain()

	create_swapchain()
	create_swapchain_data()
	create_color_resources()
	create_depth_resources()
}

@(private)
create_shader_module :: proc(code: []byte) -> (shader: vk.ShaderModule) {
	as_u32 := slice.reinterpret([]u32, code)
	create_info: vk.ShaderModuleCreateInfo = {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(as_u32) * size_of(u32),
		pCode    = raw_data(as_u32),
	}

	vk_check(vk.CreateShaderModule(r.device, &create_info, nil, &shader))
	return
}

@(private)
create_descriptor_set_layout :: proc() -> (ok: bool) {
	texture_binding: vk.DescriptorSetLayoutBinding = {
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1024,
		stageFlags      = {.FRAGMENT},
	}

	bindings := []vk.DescriptorSetLayoutBinding{texture_binding}

	binding_flags := []vk.DescriptorBindingFlags{{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}}
	binding_flags_create_info: vk.DescriptorSetLayoutBindingFlagsCreateInfo = {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(binding_flags)),
		pBindingFlags = raw_data(binding_flags),
	}

	layout_info: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &binding_flags_create_info,
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
		flags        = {.UPDATE_AFTER_BIND_POOL},
	}

	vk_check(
		vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &r.global_descriptor_set_layout),
	)

	return true
}

@(private)
destroy_descriptor_set_layout :: proc() {
	vk.DestroyDescriptorSetLayout(r.device, r.global_descriptor_set_layout, nil)
}

@(private)
create_ui_pipeline :: proc() -> (handle: Handle, ok: bool) #optional_ok {
	pipeline: GpuPipeline
	shader_code := #load(DEFAULT_UI_SHADER)
	shader_module := create_shader_module(shader_code)
	defer vk.DestroyShaderModule(r.device, shader_module, nil)

	b: PipelineBuilder
	pb_init(&b)
	defer pb_destroy(&b)

	vert_stage_info: vk.PipelineShaderStageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = shader_module,
		stage  = {.VERTEX},
		pName  = "vertMain",
	}

	frag_stage_info: vk.PipelineShaderStageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = shader_module,
		stage  = {.FRAGMENT},
		pName  = "fragMain",
	}
	pb_add_shaders(&b, vert_stage_info, frag_stage_info)
	pb_set_descriptor_set_layout(&b, r.global_descriptor_set_layout)
	pb_set_input_topology(&b, .TRIANGLE_LIST)
	pb_set_cull_mode(&b, {}, .COUNTER_CLOCKWISE)
	pb_set_polygon_mode(&b, .FILL, 1)
	pb_disable_multisampling(&b)
	pb_set_color_format(&b, r.render_target.color_format)
	pb_enable_blending_alphablend(&b)
	pb_set_push_constants(&b, {.VERTEX}, size_of(UiPushConstant))

	return pb_build(&b), true
}

@(private)
create_graphics_pipeline :: proc() -> (handle: Handle, ok: bool) #optional_ok {
	pipeline: GpuPipeline
	shader_code := #load(DEFAULT_GRAPHICS_SHADER)
	shader_module := create_shader_module(shader_code)
	defer vk.DestroyShaderModule(r.device, shader_module, nil)

	b: PipelineBuilder
	pb_init(&b)
	defer pb_destroy(&b)

	vert_stage_info: vk.PipelineShaderStageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = shader_module,
		stage  = {.VERTEX},
		pName  = "vertMain",
	}

	frag_stage_info: vk.PipelineShaderStageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = shader_module,
		stage  = {.FRAGMENT},
		pName  = "fragMain",
	}
	pb_add_shaders(&b, vert_stage_info, frag_stage_info)
	pb_set_descriptor_set_layout(&b, r.global_descriptor_set_layout)
	pb_set_input_topology(&b, .TRIANGLE_LIST)
	pb_set_cull_mode(&b, {.BACK}, .COUNTER_CLOCKWISE)
	pb_set_polygon_mode(&b, .FILL, 1)
	pb_enable_multisampling(&b, r.msaa_samples, 1)
	pb_set_color_format(&b, r.render_target.color_format)
	pb_disable_blending(&b)
	pb_enable_depth_testing(&b)
	pb_set_depth_format(&b, r.render_target.depth_format)
	pb_set_push_constants(&b, {.VERTEX}, size_of(PushConstant))

	return pb_build(&b), true
}

@(private)
destroy_graphics_pipeline :: proc(pipeline: GpuPipeline) {
	vk.DestroyPipeline(r.device, pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(r.device, pipeline.layout, nil)
}

@(private)
create_command_pool :: proc() -> (ok: bool) {
	pool_info: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.graphics_index,
	}

	vk_check(vk.CreateCommandPool(r.device, &pool_info, nil, &r.command_pool))

	return true
}

@(private)
destroy_command_pool :: proc() {
	vk.DestroyCommandPool(r.device, r.command_pool, nil)
}

@(private)
find_supported_formats :: proc(
	candidates: []vk.Format,
	tiling: vk.ImageTiling,
	features: vk.FormatFeatureFlags,
) -> vk.Format {
	for format in candidates {
		props: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(r.physical_device, format, &props)

		if tiling == .LINEAR && props.linearTilingFeatures & features == features do return format
		if tiling == .OPTIMAL && props.optimalTilingFeatures & features == features do return format
	}

	unreachable()
}

@(private)
find_depth_format :: proc() -> vk.Format {
	return find_supported_formats(
		{.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT},
		.OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT},
	)
}

@(private)
has_stencil_component :: proc(format: vk.Format) -> bool {
	return format == .D32_SFLOAT_S8_UINT || format == .D24_UNORM_S8_UINT
}

@(private)
create_color_resources :: proc() -> (ok: bool) {
	r.render_target.color_format = r.swapchain.format
	create_image(
		&r.render_target.color,
		r.swapchain.extent.width,
		r.swapchain.extent.height,
		r.render_target.color_format,
		{.TRANSIENT_ATTACHMENT, .COLOR_ATTACHMENT},
		1,
		r.msaa_samples,
	)

	// r.ui_target.format = r.swapchain.format
	// create_image(
	// 	&r.ui_target.color,
	// 	r.swapchain.extent.width,
	// 	r.swapchain.extent.height,
	// 	r.ui_target.format,
	// 	{.TRANSIENT_ATTACHMENT, .COLOR_ATTACHMENT},
	// 	1,
	// 	r.msaa_samples,
	// )

	return true
}

@(private)
destroy_color_resources :: proc() {
	vk.DestroyImageView(r.device, r.render_target.color.view, nil)
	vma.destroy_image(
		r.allocators.gpu,
		r.render_target.color.image,
		r.render_target.color.allocation,
	)

	// vk.DestroyImageView(r.device, r.ui_target.color.view, nil)
	// vma.destroy_image(r.allocators.gpu, r.ui_target.color.image, r.ui_target.color.allocation)
}

@(private)
create_depth_resources :: proc() -> (ok: bool) {
	r.render_target.depth_format = find_depth_format()
	create_image(
		&r.render_target.depth,
		r.swapchain.extent.width,
		r.swapchain.extent.height,
		r.render_target.depth_format,
		{.DEPTH_STENCIL_ATTACHMENT},
		1,
		msaa_samples = r.msaa_samples,
	)

	return true
}

@(private)
destroy_depth_resources :: proc() {
	vk.DestroyImageView(r.device, r.render_target.depth.view, nil)
	vma.destroy_image(
		r.allocators.gpu,
		r.render_target.depth.image,
		r.render_target.depth.allocation,
	)
}

@(private)
create_image :: proc(
	image: ^AllocatedImage,
	width, height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	mip_levels: u32 = 1,
	msaa_samples: vk.SampleCountFlags = {._1},
) {
	image_info: vk.ImageCreateInfo = {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
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
		vma.create_image(
			r.allocators.gpu,
			image_info,
			alloc_info,
			&image.image,
			&image.allocation,
			nil,
		),
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
		viewType = .D2,
		format = format,
		subresourceRange = {
			aspectMask = aspect,
			layerCount = 1,
			baseArrayLayer = 0,
			levelCount = mip_levels,
			baseMipLevel = 0,
		},
	}
	vk_check(vk.CreateImageView(r.device, &view_info, nil, &image.view))
	image.mip_levels = mip_levels
}

@(private)
begin_single_time_commands :: proc() -> vk.CommandBuffer {
	cmd_buf: vk.CommandBuffer
	cmd_buf_info: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		commandBufferCount = 1,
	}
	vk_check(vk.AllocateCommandBuffers(r.device, &cmd_buf_info, &cmd_buf))

	begin_info: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd_buf, &begin_info))
	return cmd_buf
}

@(private)
end_single_time_commands :: proc(cmd_buf: ^vk.CommandBuffer) {
	fence: vk.Fence
	fence_info: vk.FenceCreateInfo = {
		sType = .FENCE_CREATE_INFO,
	}
	vk_check(vk.CreateFence(r.device, &fence_info, nil, &fence))
	defer vk.DestroyFence(r.device, fence, nil)

	vk_check(vk.EndCommandBuffer(cmd_buf^))

	submit: vk.SubmitInfo = {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = cmd_buf,
	}
	vk_check(vk.QueueSubmit(r.graphics_queue, 1, &submit, fence))
	vk_check(vk.WaitForFences(r.device, 1, &fence, true, max(u64)))
}

@(private)
generate_mipmaps :: proc(image: AllocatedImage, format: vk.Format, #any_int width, height: u32) {
	properties: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(r.physical_device, format, &properties)
	if properties.optimalTilingFeatures & {.SAMPLED_IMAGE_FILTER_LINEAR} !=
	   {.SAMPLED_IMAGE_FILTER_LINEAR} {
		panic("texture image format does not support linear blitting")
	}

	buf := begin_single_time_commands()

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

	end_single_time_commands(&buf)
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

@(private)
create_texture_from_data :: proc(
	data: rawptr,
	width, height, channels: i32,
	mipped := true,
	norm := false,
) -> (
	handle: Handle,
	ok: bool,
) {
	texture: GpuTexture
	size := width * height * channels

	format: vk.Format
	if channels == 1 do format = .R8_SRGB if !norm else .R8_UNORM
	else if channels == 2 do format = .R8G8_SRGB
	else if channels == 3 do format = .R8G8B8_SRGB
	else if channels == 4 do format = .R8G8B8A8_SRGB
	else do unreachable()

	create_image(
		&texture.image,
		u32(width),
		u32(height),
		format,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		mip_levels = u32(math.floor(math.log2(f32(max(width, height))))) + 1 if mipped else 1,
	)

	img_buf: vk.Buffer
	img_alloc: vma.Allocation
	img_buf_info: vk.BufferCreateInfo = {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(size),
		usage = {.TRANSFER_SRC},
	}
	img_alloc_info: vma.Allocation_Create_Info = {
		flags = {.Host_Access_Sequential_Write, .Mapped},
		usage = .Auto,
	}
	vk_check(
		vma.create_buffer(
			r.allocators.gpu,
			img_buf_info,
			img_alloc_info,
			&img_buf,
			&img_alloc,
			nil,
		),
	)
	defer vma.destroy_buffer(r.allocators.gpu, img_buf, img_alloc)

	img_buf_ptr: rawptr
	vk_check(vma.map_memory(r.allocators.gpu, img_alloc, &img_buf_ptr))
	mem.copy(img_buf_ptr, data, int(size))

	// TODO: replace with dedicated one-time buffer/pool
	cmd_buf := begin_single_time_commands()

	transition_image(
		cmd_buf,
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
	vk.CmdCopyBufferToImage(cmd_buf, img_buf, texture.image.image, .TRANSFER_DST_OPTIMAL, 1, &copy)

	end_single_time_commands(&cmd_buf)

	generate_mipmaps(texture.image, format, width, height)

	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(r.physical_device, &properties)

	sampler_info: vk.SamplerCreateInfo = {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = .LINEAR,
		minFilter               = .LINEAR,
		mipmapMode              = .LINEAR,
		mipLodBias              = 0,
		minLod                  = 0,
		maxLod                  = vk.LOD_CLAMP_NONE,
		addressModeU            = .REPEAT,
		addressModeV            = .REPEAT,
		addressModeW            = .REPEAT,
		anisotropyEnable        = true,
		maxAnisotropy           = properties.limits.maxSamplerAnisotropy,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
	}
	vk_check(vk.CreateSampler(r.device, &sampler_info, nil, &texture.image.sampler))

	texture.id = u32(hm.dynamic_len(r.textures))
	// TODO: validate there is enough space in descriptor set
	image_info: vk.DescriptorImageInfo = {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = texture.image.view,
		sampler     = texture.image.sampler,
	}

	write: vk.WriteDescriptorSet = {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = r.global_descriptor_set,
		dstBinding      = 0,
		dstArrayElement = texture.id,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &image_info,
	}

	vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)

	h, err := hm.dynamic_add(&r.textures, texture)
	if err != nil {
		log.errorf("failed to add texture to hashmap: %v", err)
		return
	}
	handle = h
	return handle, true
}

@(private)
create_texture_from_filepath :: proc(
	filepath: cstring,
	mipped := true,
	norm := false,
) -> (
	handle: Handle,
	ok: bool,
) #optional_ok {
	width, height, channels: i32
	data := stbi.load(filepath, &width, &height, &channels, 4)

	if data == nil {
		log.fatalf("failed to load %s", filepath)
		return
	}
	defer stbi.image_free(data)

	return create_texture_from_data(data, width, height, 4, mipped, norm)
}

get_texture_id :: proc(t: Handle) -> (id: u32, ok: bool) {
	tex := hm.dynamic_get(&r.textures, t) or_return
	return tex.id, true
}

@(private)
destroy_texture :: proc(texture: ^GpuTexture) {
	vk.DestroySampler(r.device, texture.image.sampler, nil)
	vk.DestroyImageView(r.device, texture.image.view, nil)
	vma.destroy_image(r.allocators.gpu, texture.image.image, texture.image.allocation)
}

@(private)
create_buffers :: proc() -> (ok: bool) {
	for i in 0 ..< FRAMES_IN_FLIGHT {
		create_buffer(
			&r.object_buffers[i],
			size_of(ObjectData) * MAX_MODELS,
			{.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER, .TRANSFER_DST},
		)
		create_buffer(
			&r.ui_buffers[i],
			size_of(UiPrimitive) * MAX_UI_ELEMENTS,
			{.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER, .TRANSFER_DST},
		)
		create_buffer(
			&r.global_data_buffers[i],
			size_of(GlobalData),
			{.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER, .TRANSFER_DST},
		)
		create_buffer(
			&r.indirect_buffers[i],
			size_of(vk.DrawIndirectCommand) * MAX_INDIRECT_DRAW,
			{.INDIRECT_BUFFER, .TRANSFER_DST},
		)
	}

	return true
}

@(private)
destroy_buffers :: proc() {
	for buf in r.object_buffers {
		vma.unmap_memory(r.allocators.gpu, buf.allocation)
		vma.destroy_buffer(r.allocators.gpu, buf.buffer, buf.allocation)
	}
	for buf in r.ui_buffers {
		vma.unmap_memory(r.allocators.gpu, buf.allocation)
		vma.destroy_buffer(r.allocators.gpu, buf.buffer, buf.allocation)
	}
	for buf in r.global_data_buffers {
		vma.unmap_memory(r.allocators.gpu, buf.allocation)
		vma.destroy_buffer(r.allocators.gpu, buf.buffer, buf.allocation)
	}
	for buf in r.indirect_buffers {
		vma.unmap_memory(r.allocators.gpu, buf.allocation)
		vma.destroy_buffer(r.allocators.gpu, buf.buffer, buf.allocation)
	}
}

@(private)
create_descriptor_pool :: proc() -> (ok: bool) {
	pool_sizes: []vk.DescriptorPoolSize = {
		{descriptorCount = FRAMES_IN_FLIGHT * 1024, type = .COMBINED_IMAGE_SAMPLER},
	}

	pool_info: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	vk_check(vk.CreateDescriptorPool(r.device, &pool_info, nil, &r.descriptor_pool))

	alloc_info: vk.DescriptorSetAllocateInfo = {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = r.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &r.global_descriptor_set_layout,
	}
	vk_check(vk.AllocateDescriptorSets(r.device, &alloc_info, &r.global_descriptor_set))

	return true
}

@(private)
destroy_descriptor_pool :: proc() {
	vk.DestroyDescriptorSetLayout(r.device, r.global_descriptor_set_layout, nil)
	vk.DestroyDescriptorPool(r.device, r.descriptor_pool, nil)
}

@(private)
create_command_buffers :: proc() -> (ok: bool) {
	alloc_info: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		commandBufferCount = 1,
		level              = .PRIMARY,
	}

	for &frame in r.frames {
		vk_check(vk.AllocateCommandBuffers(r.device, &alloc_info, &frame.buffer))
	}

	return true
}

@(private)
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

@(private)
transition_swapchain_image_layout :: proc(
	buf: vk.CommandBuffer,
	image_index: int,
	old_layout, new_layout: vk.ImageLayout,
	src_access_mask, dst_access_mask: vk.AccessFlags2,
	src_stage_mask, dst_stage_mask: vk.PipelineStageFlags2,
) {
	transition_image(
		buf,
		r.swapchain.images[image_index],
		old_layout,
		new_layout,
		src_access_mask,
		dst_access_mask,
		src_stage_mask,
		dst_stage_mask,
	)
}

@(private)
prepare_frame :: proc(image_index: int) -> vk.CommandBuffer {
	frame_index := current_frame()
	frame := r.frames[frame_index]
	buf := frame.buffer
	vk.BeginCommandBuffer(buf, &vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO})

	transition_swapchain_image_layout(
		buf,
		image_index,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
	)

	return buf
}

@(private)
end_frame :: proc(buf: vk.CommandBuffer, image_index: int) {
	transition_swapchain_image_layout(
		buf,
		image_index,
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_WRITE},
		{},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.BOTTOM_OF_PIPE},
	)

	vk_check(vk.EndCommandBuffer(buf))
}

@(private)
record_command_buffer_3d :: proc(buf: vk.CommandBuffer, image_index: int) {
	frame_index := current_frame()
	transition_image(
		buf,
		r.render_target.color.image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
	)

	depth_aspect: vk.ImageAspectFlags = {.DEPTH}
	if has_stencil_component(r.render_target.depth_format) {
		depth_aspect |= {.STENCIL}
	}
	transition_image(
		buf,
		r.render_target.depth.image,
		.UNDEFINED,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		depth_aspect,
	)

	clear_color: vk.ClearValue = {
		color = {float32 = {1, 1, 1, 1}},
	}
	clear_depth: vk.ClearValue = {
		depthStencil = {depth = 1, stencil = 0},
	}
	resolve_mode: vk.ResolveModeFlags = {.SAMPLE_ZERO} if ._1 in r.msaa_samples else {.AVERAGE}
	color_attachment_info: vk.RenderingAttachmentInfo = {
		sType              = .RENDERING_ATTACHMENT_INFO,
		clearValue         = clear_color,
		resolveMode        = resolve_mode,
		imageView          = r.render_target.color.view,
		imageLayout        = .COLOR_ATTACHMENT_OPTIMAL,
		resolveImageView   = r.swapchain.views[image_index],
		resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp             = .CLEAR,
		storeOp            = .STORE,
	}
	depth_attachment_info: vk.RenderingAttachmentInfo = {
		sType       = .RENDERING_ATTACHMENT_INFO,
		clearValue  = clear_depth,
		imageView   = r.render_target.depth.view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .DONT_CARE,
	}

	rendering_info: vk.RenderingInfo = {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = r.swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_info,
		pDepthAttachment = &depth_attachment_info,
	}

	viewport: vk.Viewport = {
		width    = f32(r.swapchain.extent.width),
		height   = f32(r.swapchain.extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(buf, 0, 1, &viewport)

	scissor: vk.Rect2D = {
		extent = r.swapchain.extent,
		offset = {0, 0},
	}
	vk.CmdSetScissor(buf, 0, 1, &scissor)

	vk.CmdBeginRendering(buf, &rendering_info)

	view := glm.matrix4_look_at_f32({0, 4, 4}, {0, 0, 0}, {0, 0, 1})
	proj := matrix4_perspective_z0_f32(
		glm.to_radians(f32(45)),
		f32(r.swapchain.extent.width) / f32(r.swapchain.extent.height),
		0.01,
		10,
	)
	global_data: GlobalData = {
		view_proj = proj * view,
	}
	mem.copy(r.global_data_buffers[frame_index].mapped, rawptr(&global_data), size_of(GlobalData))

	indirect_commands := slice.from_ptr(
		cast(^vk.DrawIndirectCommand)r.indirect_buffers[frame_index].mapped,
		MAX_INDIRECT_DRAW,
	)
	indirect_count := 0
	total_drawn := 0

	bound_pipeline_handle: Handle
	bound_pipeline: ^GpuPipeline

	current_mesh_handle: Handle
	current_mesh: ^GpuMesh
	for &model, i in r.draw_info.models {
		if model.material.pipeline != bound_pipeline_handle {
			if indirect_count > 0 {
				vk.CmdDrawIndirect(
					buf,
					r.indirect_buffers[frame_index].buffer,
					vk.DeviceSize(size_of(vk.DrawIndirectCommand) * total_drawn),
					u32(indirect_count),
					size_of(vk.DrawIndirectCommand),
				)
				total_drawn += indirect_count
				indirect_count = 0
			}

			bound_pipeline_handle = model.material.pipeline
			bound_pipeline = hm.dynamic_get(&r.graphics_pipelines, bound_pipeline_handle)
			vk.CmdBindPipeline(buf, .GRAPHICS, bound_pipeline.pipeline)
			vk.CmdBindDescriptorSets(
				buf,
				.GRAPHICS,
				bound_pipeline.layout,
				0,
				1,
				&r.global_descriptor_set,
				0,
				nil,
			)

			push_constants: PushConstant = {
				global_data_address   = r.global_data_buffers[frame_index].address,
				object_buffer_address = vk.DeviceAddress(
					u64(total_drawn * size_of(ObjectData)),
				) + r.object_buffers[frame_index].address,
			}
			vk.CmdPushConstants(
				buf,
				bound_pipeline.layout,
				{.VERTEX},
				0,
				size_of(push_constants),
				&push_constants,
			)
		}

		if current_mesh_handle != model.mesh {
			current_mesh_handle = model.mesh
			current_mesh = hm.dynamic_get(&r.meshes, current_mesh_handle)
		}

		indirect_commands[total_drawn + indirect_count] = {
			vertexCount   = current_mesh.index_count,
			instanceCount = 1,
			firstVertex   = 0,
			firstInstance = u32(i),
		}
		indirect_count += 1
	}

	if indirect_count > 0 {
		vk.CmdDrawIndirect(
			buf,
			r.indirect_buffers[frame_index].buffer,
			vk.DeviceSize(size_of(vk.DrawIndirectCommand) * total_drawn),
			u32(indirect_count),
			size_of(vk.DrawIndirectCommand),
		)
	}

	vk.CmdEndRendering(buf)

}

@(private)
record_command_buffer_ui :: proc(buf: vk.CommandBuffer, image_index: int) {
	frame_index := current_frame()

	color_attachment_info: vk.RenderingAttachmentInfo = {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = r.swapchain.views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .LOAD,
		storeOp     = .STORE,
	}

	rendering_info: vk.RenderingInfo = {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = r.swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_info,
	}

	viewport: vk.Viewport = {
		width    = f32(r.swapchain.extent.width),
		height   = f32(r.swapchain.extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(buf, 0, 1, &viewport)

	scissor: vk.Rect2D = {
		extent = r.swapchain.extent,
		offset = {0, 0},
	}
	vk.CmdSetScissor(buf, 0, 1, &scissor)

	vk.CmdBeginRendering(buf, &rendering_info)

	ui_pipeline, _ := hm.dynamic_get(&r.graphics_pipelines, r.ui_pipeline)

	vk.CmdBindPipeline(buf, .GRAPHICS, ui_pipeline.pipeline)
	vk.CmdBindDescriptorSets(
		buf,
		.GRAPHICS,
		ui_pipeline.layout,
		0,
		1,
		&r.global_descriptor_set,
		0,
		nil,
	)

	push_constants: UiPushConstant = {
		ui_buffer_address = r.ui_buffers[frame_index].address,
		screen_size       = {f32(r.swapchain.extent.width), f32(r.swapchain.extent.height)},
	}
	vk.CmdPushConstants(
		buf,
		ui_pipeline.layout,
		{.VERTEX},
		0,
		size_of(push_constants),
		&push_constants,
	)

	ui_count := u32(len(r.draw_info.ui_elements))
	if ui_count > 0 {
		vk.CmdDraw(buf, 6, ui_count, 0, 0)
	}

	vk.CmdEndRendering(buf)
}

@(private)
create_sync_objects :: proc() -> (ok: bool) {
	for &frame in r.frames {
		vk_check(
			vk.CreateSemaphore(
				r.device,
				&vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO},
				nil,
				&frame.semaphore,
			),
		)
		vk_check(
			vk.CreateFence(
				r.device,
				&vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
				nil,
				&frame.fence,
			),
		)
	}

	return true
}

@(private)
destroy_sync_objects :: proc() {
	for frame in r.frames {
		vk.DestroyFence(r.device, frame.fence, nil)
		vk.DestroySemaphore(r.device, frame.semaphore, nil)
	}
}

init_renderer :: proc(
	window_config: WindowConfig,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
	loc := #caller_location,
) -> (
	ok: bool,
) {
	log.debug("Initializing Vulkan renderer")
	r = new(Renderer, allocator, loc)
	defer if !ok do free(r, allocator)
	r.allocators.cpu = allocator
	r.allocators.temp = temp_allocator
	r.odin_ctx = context

	hm.dynamic_init(&r.meshes, r.allocators.cpu)
	defer if !ok do hm.dynamic_destroy(&r.meshes)

	hm.dynamic_init(&r.textures, r.allocators.cpu)
	defer if !ok do hm.dynamic_destroy(&r.textures)

	hm.dynamic_init(&r.graphics_pipelines, r.allocators.cpu)
	defer if !ok do hm.dynamic_destroy(&r.graphics_pipelines)

	init_window(window_config) or_return
	defer if !ok do destroy_window()
	log.debug("Window created")

	create_instance() or_return
	defer if !ok do destroy_instance()
	log.debug("Instance created")

	pick_physical_device() or_return
	log.debug("Picked physical device")

	create_logical_device() or_return
	defer if !ok do destroy_logical_device()
	log.debug("Created device")

	create_vma() or_return
	defer if !ok do destroy_vma()
	log.debug("Setup VMA")

	create_swapchain() or_return
	defer if !ok do destroy_swapchain()
	log.debug("Created swapchain")

	create_swapchain_data() or_return
	defer if !ok do destroy_swapchain_data()
	log.debug("Created swapchain image views")

	create_descriptor_set_layout() or_return
	defer if !ok do destroy_descriptor_set_layout()
	log.debug("Created descriptor set layout")

	create_command_pool() or_return
	defer if !ok do destroy_command_pool()
	log.debug("Command pool created")

	create_color_resources() or_return
	defer if !ok do destroy_color_resources()
	log.debug("Color resources created")

	create_depth_resources() or_return
	defer if !ok do destroy_depth_resources()
	log.debug("Depth resources created")

	create_buffers() or_return
	defer if !ok do destroy_buffers()
	log.debug("Uniform buffers created")

	create_descriptor_pool() or_return
	defer if !ok do destroy_descriptor_pool()
	log.debug("Descriptor pool created")

	pipeline, _ := create_graphics_pipeline()
	defer if !ok do destroy_graphics_pipeline(hm.get(&r.graphics_pipelines, pipeline)^)
	r.default_pipeline = pipeline
	log.debug("Graphics pipeline created")

	ui_pipeline, _ := create_ui_pipeline()
	defer if !ok do destroy_graphics_pipeline(hm.get(&r.graphics_pipelines, ui_pipeline)^)
	r.ui_pipeline = ui_pipeline
	log.debug("UI pipeline created")

	create_command_buffers() or_return
	log.debug("Command buffer created")

	create_sync_objects() or_return
	defer if !ok do destroy_sync_objects()
	log.debug("Created sync objects")

	r.start_time = time.now()

	log.info("Vulkan renderer initialized")
	return true
}

destroy_renderer :: proc() {
	vk.DeviceWaitIdle(r.device)
	destroy_sync_objects()
	text_it := hm.dynamic_iterator_make(&r.textures)
	for texture, h in hm.dynamic_iterate(&text_it) {
		destroy_texture(texture)
		hm.dynamic_remove(&r.textures, h)
	}
	destroy_descriptor_pool()
	destroy_buffers()
	mesh_it := hm.dynamic_iterator_make(&r.meshes)
	for mesh, h in hm.dynamic_iterate(&mesh_it) {
		destroy_gpu_mesh(mesh^)
		hm.dynamic_remove(&r.meshes, h)
	}
	destroy_depth_resources()
	destroy_color_resources()
	destroy_command_pool()
	pipeline_it := hm.dynamic_iterator_make(&r.graphics_pipelines)
	for pipeline, h in hm.dynamic_iterate(&pipeline_it) {
		destroy_graphics_pipeline(pipeline^)
		hm.dynamic_remove(&r.graphics_pipelines, h)
	}
	destroy_swapchain_data()
	destroy_swapchain()
	destroy_vma()
	destroy_logical_device()
	destroy_instance()
	destroy_window()
	hm.dynamic_destroy(&r.meshes)
	hm.dynamic_destroy(&r.textures)
	free(r, r.allocators.cpu)
}

@(require_results)
matrix4_perspective_z0_f32 :: proc "contextless" (
	fovy, aspect, near, far: f32,
) -> (
	m: glm.Matrix4f32,
) #no_bounds_check {
	tan_half_fovy := math.tan(0.5 * fovy)
	m[0, 0] = 1 / (aspect * tan_half_fovy)
	m[1, 1] = 1 / (tan_half_fovy)
	m[3, 2] = +1

	m[2, 2] = far / (far - near)
	m[2, 3] = -(far * near) / (far - near)

	m[2] = -m[2]
	m[1, 1] *= -1

	return
}

@(private)
update_uniform_buffer :: proc() {
	frame_index := current_frame()

	objects := slice.from_ptr(
		cast(^ObjectData)r.object_buffers[frame_index].mapped,
		len(r.draw_info.models),
	)

	current_texture_handle: Handle
	current_texture: ^GpuTexture

	for &model, i in r.draw_info.models {
		if current_texture_handle != model.material.texture {
			current_texture_handle = model.material.texture
			current_texture = hm.dynamic_get(&r.textures, current_texture_handle)
		}
		mesh := hm.dynamic_get(&r.meshes, model.mesh)
		objects[i].model = get_model_matrix(model)
		objects[i].texture_id = current_texture.id
		objects[i].vertex_address = mesh.buffer.address
		objects[i].index_address = mesh.buffer.address + vk.DeviceAddress(mesh.index_offset)
	}

	ui_elements := slice.from_ptr(
		cast(^UiData)r.ui_buffers[frame_index].mapped,
		len(r.draw_info.ui_elements),
	)
	for element, i in r.draw_info.ui_elements {
		ui_elements[i] = element
	}
}

draw_frame :: proc() {
	if r.resize_requested {
		recreate_swapchain()
		r.resize_requested = false
	}

	frame := r.frames[current_frame()]

	vk_check(vk.WaitForFences(r.device, 1, &frame.fence, true, max(u64)))

	image_index: u32
	res := vk.AcquireNextImageKHR(
		r.device,
		r.swapchain.handle,
		max(u64),
		frame.semaphore,
		{},
		&image_index,
	)
	#partial switch res {
	case .ERROR_OUT_OF_DATE_KHR:
		r.resize_requested = true
		return
	case .SUBOPTIMAL_KHR:
		r.resize_requested = true
	case:
		vk_check(res)
	}

	update_uniform_buffer()

	buf := prepare_frame(int(image_index))
	record_command_buffer_3d(buf, int(image_index))
	record_command_buffer_ui(buf, int(image_index))
	end_frame(buf, int(image_index))

	vk.ResetFences(r.device, 1, &frame.fence)

	wait_stage_dest_mask: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
	submit_info: vk.SubmitInfo = {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &frame.semaphore,
		pWaitDstStageMask    = &wait_stage_dest_mask,
		commandBufferCount   = 1,
		pCommandBuffers      = &frame.buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &r.swapchain.semaphores[image_index],
	}

	vk_check(vk.QueueSubmit(r.graphics_queue, 1, &submit_info, frame.fence))

	present_info: vk.PresentInfoKHR = {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &r.swapchain.semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = &r.swapchain.handle,
		pImageIndices      = &image_index,
	}

	res = vk.QueuePresentKHR(r.graphics_queue, &present_info)
	#partial switch res {
	case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
		r.resize_requested = true
	case:
		vk_check(res)
	}
	r.frame_index += 1
}

main :: proc() {
	log_level: log.Level = .Info
	log_opts: log.Options = {.Level, .Line, .Terminal_Color}
	log_ident := "Dial"

	when ODIN_DEBUG {
		log_level = .Debug
		log_opts |= {.Date, .Time}

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				log.errorf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					log.errorf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				log.errorf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					log.errorf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	context.logger = log.create_console_logger(log_level, log_opts, log_ident)

	if !init_renderer({window_title = "test window", app_id = "com.boondax.dial", width = WIDTH, height = HEIGHT, window_flags = {.VULKAN, .RESIZABLE}}, context.allocator) do return
	defer destroy_renderer()

	vertices, indices := load_model(MODEL_PATH)
	mesh := create_gpu_mesh(vertices, indices)
	texture := create_texture_from_filepath(TEXTURE_IMAGE)

	ui_font, _ := load_font(FONT_PATH, 64)
	defer delete(ui_font.chars)

	render_loop: for {
		e: sdl.Event
		event_loop: for sdl.PollEvent(&e) {
			#partial switch e.type {
			case .QUIT:
				break render_loop
			case .KEY_UP:
				#partial switch e.key.scancode {
				case .ESCAPE:
					break render_loop
				}
			case .WINDOW_RESIZED:
				request_resize()
			}
		}

		if begin_drawing() {
			draw_model(
				mesh,
				{texture = texture, pipeline = default_pipeline()},
				{},
				{0, 0, glm.to_radians(f32(45))},
				{1, 1, 1},
			)
			draw_model(
				mesh,
				{texture = texture, pipeline = default_pipeline()},
				{-2, 0, 0},
				{0, 0, glm.to_radians(f32(45)) - 2 * elapsed_seconds()},
				{0.5, 0.5, 0.5},
			)
			draw_model(
				mesh,
				{texture = texture, pipeline = default_pipeline()},
				{2, 0, 0},
				{0, 0, glm.to_radians(f32(45)) + 2 * elapsed_seconds()},
				{0.5, 0.5, 0.5},
			)
			draw_rect(
				rect = {30.0, 30.0, 470.0, 100.0},
				color = {1, 1, 1, 1},
				corner_radius = {20.0, 20.0, 20.0, 20.0},
				border_width = 2.0,
				border_color = {0, 0, 1, 1},
				shadow_offset = {10, 10},
				shadow_color = {0, 0, 0, 0.7},
				shadow_softness = 5,
			)
			draw_text(
				"Hello, Vulkan UI!",
				{50, 50},
				ui_font,
				{1, 0, 0, 1},
				border_width = 2,
				border_color = {0, 1, 0, 1},
				shadow_offset = {5, 5},
				shadow_color = {0, 0, 0, 1},
				softness = 0,
				shadow_softness = 50,
			)
		}
	}
}
