package gfx

import "base:runtime"
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

MODEL_PATH :: "assets/models/viking_room/viking_room.obj"
TEXTURE_IMAGE :: "assets/models/viking_room/viking_room.png"
DEFAULT_SHADER :: "./default_shaders/depth_quads.spv"

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
	buffer:                vk.CommandBuffer,
	semaphore:             vk.Semaphore,
	fence:                 vk.Fence,
	uniform_buffer:        AllocatedBuffer,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set:        vk.DescriptorSet,
}

Renderer :: struct {
	allocators:                    Allocators,
	ctx:                           runtime.Context,
	window:                        ^sdl.Window,
	instance:                      vk.Instance,
	debug_messenger:               vk.DebugUtilsMessengerEXT,
	physical_device:               vk.PhysicalDevice,
	device:                        vk.Device,
	surface:                       vk.SurfaceKHR,
	graphics_queue:                vk.Queue,
	present_queue:                 vk.Queue,
	graphics_index, present_index: u32,
	swapchain:                     Swapchain,
	descriptor_set_layout:         vk.DescriptorSetLayout,
	descriptor_pool:               vk.DescriptorPool,
	graphics_pipeline:             vk.Pipeline,
	graphics_pipeline_layout:      vk.PipelineLayout,
	command_pool:                  vk.CommandPool,
	frames:                        [FRAMES_IN_FLIGHT]FrameData,
	frame_index:                   uint,
	resize_requested:              bool,
	start_time:                    time.Time,
	vertex_buffer:                 AllocatedBuffer,
	texture_image:                 SampledImage,
	color_image:                   AllocatedImage,
	depth_image:                   AllocatedImage,
	depth_format:                  vk.Format,
	msaa_samples:                  vk.SampleCountFlags,
}

r: ^Renderer

AllocatedBuffer :: struct {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
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
	color: [3]f32,
	tex:   [2]f32,
}

get_vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {inputRate = .VERTEX, stride = size_of(Vertex), binding = 0}
}

get_vertex_attribute_descriptions :: proc(
) -> (
	attributes: [3]vk.VertexInputAttributeDescription,
) {
	return {
		{
			binding = 0,
			location = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Vertex, pos)),
		},
		{
			binding = 0,
			location = 1,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Vertex, color)),
		},
		{binding = 0, location = 2, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, tex))},
	}
}

UBO :: struct {
	model, view, proj: matrix[4, 4]f32,
}

// vertices: []Vertex
// indices: []u32

vertices: []Vertex = {
	{{-0.5, -0.5, 0.0}, {1.0, 0.0, 0.0}, {0.0, 0.0}},
	{{0.5, -0.5, 0.0}, {0.0, 1.0, 0.0}, {1.0, 0.0}},
	{{0.5, 0.5, 0.0}, {0.0, 0.0, 1.0}, {1.0, 1.0}},
	{{-0.5, 0.5, 0.0}, {1.0, 1.0, 1.0}, {0.0, 1.0}},
	{{-0.5, -0.5, -0.5}, {1.0, 0.0, 0.0}, {0.0, 0.0}},
	{{0.5, -0.5, -0.5}, {0.0, 1.0, 0.0}, {1.0, 0.0}},
	{{0.5, 0.5, -0.5}, {0.0, 0.0, 1.0}, {1.0, 1.0}},
	{{-0.5, 0.5, -0.5}, {1.0, 1.0, 1.0}, {0.0, 1.0}},
}

indices: []u32 = {0, 1, 2, 2, 3, 0, 4, 5, 6, 6, 7, 4}

load_model :: proc(filepath: string) {
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

	vertices = slice.clone(local_vertices[:], r.allocators.cpu)
	indices = slice.clone(local_indices[:], r.allocators.cpu)
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
	context = r.ctx

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
current_frame :: proc() -> FrameData {
	return r.frames[r.frame_index % FRAMES_IN_FLIGHT]
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
		if _, ok := indices.compute.?; !ok && .COMPUTE in family.queueFlags {
			indices.compute = u32(i)
		}
		if _, ok := indices.graphics.?; !ok && .GRAPHICS in family.queueFlags {
			indices.graphics = u32(i)
		}
		if _, ok := indices.transfer.?; !ok && .TRANSFER in family.queueFlags {
			indices.transfer = u32(i)
		}

		if _, ok := indices.present.?; !ok {
			present_supported: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), r.surface, &present_supported)

			if present_supported do indices.present = u32(i)
		}

		_, has_compute := indices.compute.?
		_, has_graphics := indices.graphics.?
		_, has_transfer := indices.transfer.?
		_, has_present := indices.present.?

		if has_compute && has_graphics && has_transfer && has_present {
			ok = true
			break
		}
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
		sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext               = &features_1_3,
		bufferDeviceAddress = true,
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
	vk.GetDeviceQueue(r.device, r.present_index, 0, &r.present_queue)

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
	ubo_layout_binding: vk.DescriptorSetLayoutBinding = {
		binding         = 0,
		descriptorType  = .UNIFORM_BUFFER,
		descriptorCount = 1,
		stageFlags      = {.VERTEX},
	}
	image_sampler_binding: vk.DescriptorSetLayoutBinding = {
		binding         = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	bindings := []vk.DescriptorSetLayoutBinding{ubo_layout_binding, image_sampler_binding}

	layout_info: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
	}

	vk_check(vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &r.descriptor_set_layout))

	return true
}

@(private)
destroy_descriptor_set_layout :: proc() {
	vk.DestroyDescriptorSetLayout(r.device, r.descriptor_set_layout, nil)
}

@(private)
create_graphics_pipeline :: proc() -> (ok: bool) {
	shader_code := #load(DEFAULT_SHADER)
	shader_module := create_shader_module(shader_code)
	defer vk.DestroyShaderModule(r.device, shader_module, nil)

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

	stages := [2]vk.PipelineShaderStageCreateInfo{vert_stage_info, frag_stage_info}

	dynamic_states: [2]vk.DynamicState = {.VIEWPORT, .SCISSOR}
	dynamic_state: vk.PipelineDynamicStateCreateInfo = {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states[:]),
	}

	binding_description := get_vertex_binding_description()
	attribute_description := get_vertex_attribute_descriptions()
	vertex_input_info: vk.PipelineVertexInputStateCreateInfo = {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding_description,
		vertexAttributeDescriptionCount = u32(len(attribute_description)),
		pVertexAttributeDescriptions    = &attribute_description[0],
	}

	input_assembly: vk.PipelineInputAssemblyStateCreateInfo = {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	viewport_state: vk.PipelineViewportStateCreateInfo = {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		scissorCount  = 1,
		viewportCount = 1,
	}

	rasterizer: vk.PipelineRasterizationStateCreateInfo = {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		cullMode                = {.BACK},
		frontFace               = .COUNTER_CLOCKWISE,
		depthBiasEnable         = false,
		depthBiasSlopeFactor    = 1,
		lineWidth               = 1,
	}

	multisampling: vk.PipelineMultisampleStateCreateInfo = {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = r.msaa_samples,
		sampleShadingEnable  = true,
		minSampleShading     = 1,
	}

	color_blend_attachment: vk.PipelineColorBlendAttachmentState = {
		blendEnable    = false,
		colorWriteMask = {.R, .G, .B, .A},
	}

	color_blend_state: vk.PipelineColorBlendStateCreateInfo = {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	depth_stencil: vk.PipelineDepthStencilStateCreateInfo = {
		sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable       = true,
		depthWriteEnable      = true,
		depthCompareOp        = .LESS_OR_EQUAL,
		depthBoundsTestEnable = false,
		stencilTestEnable     = false,
	}

	pipeline_layout_info: vk.PipelineLayoutCreateInfo = {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &r.descriptor_set_layout,
		pushConstantRangeCount = 0,
	}
	vk_check(
		vk.CreatePipelineLayout(r.device, &pipeline_layout_info, nil, &r.graphics_pipeline_layout),
	)
	defer if !ok do vk.DestroyPipelineLayout(r.device, r.graphics_pipeline_layout, nil)

	pipeline_rendering_create_info: vk.PipelineRenderingCreateInfo = {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &r.swapchain.format,
		depthAttachmentFormat   = r.depth_format,
	}

	pipeline_info: vk.GraphicsPipelineCreateInfo = {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &pipeline_rendering_create_info,
		stageCount          = 2,
		pStages             = raw_data(stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blend_state,
		pDynamicState       = &dynamic_state,
		layout              = r.graphics_pipeline_layout,
		pDepthStencilState  = &depth_stencil,
	}

	vk_check(
		vk.CreateGraphicsPipelines(r.device, {}, 1, &pipeline_info, nil, &r.graphics_pipeline),
	)

	return true
}

@(private)
destroy_graphics_pipeline :: proc() {
	vk.DestroyPipeline(r.device, r.graphics_pipeline, nil)
	vk.DestroyPipelineLayout(r.device, r.graphics_pipeline_layout, nil)
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
	color_format := r.swapchain.format
	create_image(
		&r.color_image,
		r.swapchain.extent.width,
		r.swapchain.extent.height,
		r.swapchain.format,
		{.TRANSIENT_ATTACHMENT, .COLOR_ATTACHMENT},
		1,
		r.msaa_samples,
	)

	return true
}

@(private)
destroy_color_resources :: proc() {
	vk.DestroyImageView(r.device, r.color_image.view, nil)
	vma.destroy_image(r.allocators.gpu, r.color_image.image, r.color_image.allocation)
}

@(private)
create_depth_resources :: proc() -> (ok: bool) {
	r.depth_format = find_depth_format()
	create_image(
		&r.depth_image,
		r.swapchain.extent.width,
		r.swapchain.extent.height,
		r.depth_format,
		{.DEPTH_STENCIL_ATTACHMENT},
		1,
		msaa_samples = r.msaa_samples,
	)

	return true
}

@(private)
destroy_depth_resources :: proc() {
	vk.DestroyImageView(r.device, r.depth_image.view, nil)
	vma.destroy_image(r.allocators.gpu, r.depth_image.image, r.depth_image.allocation)
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

@(private)
create_texture_image :: proc() -> (ok: bool) {
	width, height, channels: i32
	data := stbi.load(TEXTURE_IMAGE, &width, &height, &channels, 4)
	size := width * height * 4

	if data == nil {
		log.fatalf("failed to load %s", TEXTURE_IMAGE)
		return false
	}
	defer stbi.image_free(data)

	create_image(
		&r.texture_image,
		u32(width),
		u32(height),
		.R8G8B8A8_SRGB,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		mip_levels = u32(math.floor(math.log2(f32(max(width, height))))) + 1,
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
		r.texture_image.image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{},
		{.TRANSFER_WRITE_KHR},
		{},
		{.TRANSFER},
		mip_levels = r.texture_image.mip_levels,
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
		cmd_buf,
		img_buf,
		r.texture_image.image,
		.TRANSFER_DST_OPTIMAL,
		1,
		&copy,
	)

	end_single_time_commands(&cmd_buf)

	generate_mipmaps(r.texture_image, .R8G8B8A8_SRGB, width, height)

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
	vk_check(vk.CreateSampler(r.device, &sampler_info, nil, &r.texture_image.sampler))

	return true
}

@(private)
destroy_texture_image :: proc() {
	vk.DestroySampler(r.device, r.texture_image.sampler, nil)
	vk.DestroyImageView(r.device, r.texture_image.view, nil)
	vma.destroy_image(r.allocators.gpu, r.texture_image.image, r.texture_image.allocation)
}

@(private)
create_vertex_buffer :: proc() -> (ok: bool) {
	buffer_info: vk.BufferCreateInfo = {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(size_of(Vertex) * len(vertices) + size_of(u32) * len(indices)),
		usage = {.VERTEX_BUFFER, .INDEX_BUFFER},
	}
	vma_info: vma.Allocation_Create_Info = {
		flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
		usage = .Auto,
	}
	log.debug("creating vma vertex buffer")
	vk_check(
		vma.create_buffer(
			r.allocators.gpu,
			buffer_info,
			vma_info,
			&r.vertex_buffer.buffer,
			&r.vertex_buffer.allocation,
			nil,
		),
	)
	log.debug("vma vertex buffer created")

	data: rawptr
	vma.map_memory(r.allocators.gpu, r.vertex_buffer.allocation, &data)
	defer vma.unmap_memory(r.allocators.gpu, r.vertex_buffer.allocation)
	mem.copy(data, rawptr(&vertices[0]), size_of(Vertex) * len(vertices))
	data = rawptr(mem.ptr_offset(cast(^byte)data, size_of(Vertex) * len(vertices)))
	mem.copy(data, rawptr(&indices[0]), size_of(u32) * len(indices))

	return true
}

@(private)
destroy_vertex_buffer :: proc() {
	vma.destroy_buffer(r.allocators.gpu, r.vertex_buffer.buffer, r.vertex_buffer.allocation)
}

@(private)
create_uniform_buffers :: proc() -> (ok: bool) {
	buffer_info: vk.BufferCreateInfo = {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(size_of(UBO)),
		usage = {.UNIFORM_BUFFER},
	}
	vma_info: vma.Allocation_Create_Info = {
		flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
		usage = .Auto,
	}

	for &frame in r.frames {
		vk_check(
			vma.create_buffer(
				r.allocators.gpu,
				buffer_info,
				vma_info,
				&frame.uniform_buffer.buffer,
				&frame.uniform_buffer.allocation,
				nil,
			),
		)
	}

	return true
}

@(private)
destroy_uniform_buffers :: proc() {
	for frame in r.frames {
		vma.destroy_buffer(
			r.allocators.gpu,
			frame.uniform_buffer.buffer,
			frame.uniform_buffer.allocation,
		)
	}
}

@(private)
create_descriptor_pool :: proc() -> (ok: bool) {
	pool_sizes: []vk.DescriptorPoolSize = {
		{descriptorCount = FRAMES_IN_FLIGHT, type = .UNIFORM_BUFFER},
		{descriptorCount = FRAMES_IN_FLIGHT, type = .COMBINED_IMAGE_SAMPLER},
	}

	pool_info: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = FRAMES_IN_FLIGHT,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	vk_check(vk.CreateDescriptorPool(r.device, &pool_info, nil, &r.descriptor_pool))

	return true
}

@(private)
destroy_descriptor_pool :: proc() {
	vk.DestroyDescriptorPool(r.device, r.descriptor_pool, nil)
}

@(private)
create_descriptor_sets :: proc() -> (ok: bool) {
	layouts := make([]vk.DescriptorSetLayout, FRAMES_IN_FLIGHT, r.allocators.cpu)
	for i in 0 ..< FRAMES_IN_FLIGHT do layouts[i] = r.descriptor_set_layout
	defer delete(layouts)
	alloc_info: vk.DescriptorSetAllocateInfo = {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = r.descriptor_pool,
		descriptorSetCount = FRAMES_IN_FLIGHT,
		pSetLayouts        = raw_data(layouts),
	}

	descriptor_sets := make([]vk.DescriptorSet, FRAMES_IN_FLIGHT, r.allocators.cpu)
	vk_check(vk.AllocateDescriptorSets(r.device, &alloc_info, raw_data(descriptor_sets)))
	defer delete(descriptor_sets)

	for &frame, i in r.frames {
		buffer_info: vk.DescriptorBufferInfo = {
			buffer = frame.uniform_buffer.buffer,
			offset = 0,
			range  = size_of(UBO),
		}
		image_info: vk.DescriptorImageInfo = {
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			imageView   = r.texture_image.view,
			sampler     = r.texture_image.sampler,
		}

		frame.descriptor_set_layout = layouts[i]
		frame.descriptor_set = descriptor_sets[i]

		descriptor_writes: []vk.WriteDescriptorSet = {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = frame.descriptor_set,
				dstBinding = 0,
				dstArrayElement = 0,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &buffer_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = frame.descriptor_set,
				dstBinding = 1,
				dstArrayElement = 0,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &image_info,
			},
		}

		vk.UpdateDescriptorSets(
			r.device,
			u32(len(descriptor_writes)),
			raw_data(descriptor_writes),
			0,
			nil,
		)
	}

	return true
}

@(private)
destroy_descriptor_sets :: proc() {
	// for frame in r.frames {
	// 	vk.DestroyDescriptorSetLayout(r.device, frame.descriptor_set_layout, nil)
	// }
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
record_command_buffer :: proc(image_index: int) {
	frame := current_frame()
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

	transition_image(
		buf,
		r.color_image.image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
	)

	depth_aspect: vk.ImageAspectFlags = {.DEPTH}
	if has_stencil_component(r.depth_format) {
		depth_aspect |= {.STENCIL}
	}
	transition_image(
		buf,
		r.depth_image.image,
		.UNDEFINED,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		depth_aspect,
	)

	clear_color: vk.ClearValue = {
		color = {float32 = {0, 0, 0, 1}},
	}
	clear_depth: vk.ClearValue = {
		depthStencil = {depth = 1, stencil = 0},
	}
	resolve_mode: vk.ResolveModeFlags = {.SAMPLE_ZERO} if ._1 in r.msaa_samples else {.AVERAGE}
	color_attachment_info: vk.RenderingAttachmentInfo = {
		sType              = .RENDERING_ATTACHMENT_INFO,
		clearValue         = clear_color,
		resolveMode        = resolve_mode,
		imageView          = r.color_image.view,
		imageLayout        = .COLOR_ATTACHMENT_OPTIMAL,
		resolveImageView   = r.swapchain.views[image_index],
		resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp             = .CLEAR,
		storeOp            = .STORE,
	}
	depth_attachment_info: vk.RenderingAttachmentInfo = {
		sType       = .RENDERING_ATTACHMENT_INFO,
		clearValue  = clear_depth,
		imageView   = r.depth_image.view,
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

	vk.CmdBeginRendering(buf, &rendering_info)
	vk.CmdBindPipeline(buf, .GRAPHICS, r.graphics_pipeline)
	vk.CmdBindVertexBuffers(
		buf,
		0,
		1,
		&r.vertex_buffer.buffer,
		raw_data([]vk.DeviceSize{vk.DeviceSize(0)}),
	)
	vk.CmdBindIndexBuffer(
		buf,
		r.vertex_buffer.buffer,
		vk.DeviceSize(size_of(Vertex) * len(vertices)),
		.UINT32,
	)

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

	vk.CmdBindDescriptorSets(
		buf,
		.GRAPHICS,
		r.graphics_pipeline_layout,
		0,
		1,
		&frame.descriptor_set,
		0,
		nil,
	)
	vk.CmdDrawIndexed(buf, u32(len(indices)), 1, 0, 0, 0)
	vk.CmdEndRendering(buf)

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
	r.ctx = context

	load_model(MODEL_PATH)
	log.debugf("vertices: %d, indices: %d", len(vertices), len(indices))

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

	create_graphics_pipeline() or_return
	defer if !ok do destroy_graphics_pipeline()
	log.debug("Graphics pipeline created")

	create_texture_image() or_return
	defer if !ok do destroy_texture_image()
	log.debug("Texture image created")

	create_vertex_buffer() or_return
	defer if !ok do destroy_vertex_buffer()
	log.debug("Vertex buffer created")

	create_uniform_buffers() or_return
	defer if !ok do destroy_uniform_buffers()
	log.debug("Uniform buffers created")

	create_descriptor_pool() or_return
	defer if !ok do destroy_descriptor_pool()
	log.debug("Descriptor pool created")

	create_descriptor_sets() or_return
	defer if !ok do destroy_descriptor_sets()
	log.debug("Descriptor sets created")

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
	destroy_descriptor_sets()
	destroy_descriptor_pool()
	destroy_uniform_buffers()
	destroy_vertex_buffer()
	destroy_texture_image()
	destroy_depth_resources()
	destroy_color_resources()
	destroy_command_pool()
	destroy_graphics_pipeline()
	destroy_descriptor_set_layout()
	destroy_swapchain_data()
	destroy_swapchain()
	destroy_vma()
	destroy_logical_device()
	destroy_instance()
	destroy_window()
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
	ubo := UBO{}
	elapsed := time.duration_seconds(time.since(r.start_time))

	ubo.model = glm.matrix4_rotate_f32(glm.to_radians(f32(90)) * f32(elapsed), {0, 0, 1})
	ubo.view = glm.matrix4_look_at_f32({2, 2, 2}, {0, 0, 0}, {0, 0, 1})
	ubo.proj = matrix4_perspective_z0_f32(
		glm.to_radians(f32(45)),
		f32(r.swapchain.extent.width) / f32(r.swapchain.extent.height),
		0.01,
		10,
	)

	data: rawptr
	vma.map_memory(r.allocators.gpu, current_frame().uniform_buffer.allocation, &data)
	defer vma.unmap_memory(r.allocators.gpu, current_frame().uniform_buffer.allocation)

	mem.copy(data, rawptr(&ubo), size_of(UBO))
}

draw_frame :: proc() {
	if r.resize_requested {
		recreate_swapchain()
		r.resize_requested = false
	}

	frame := current_frame()

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

	record_command_buffer(int(image_index))
	vk.ResetFences(r.device, 1, &frame.fence)

	update_uniform_buffer()

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

	res = vk.QueuePresentKHR(r.present_queue, &present_info)
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

		draw_frame()
	}
}
