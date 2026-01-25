package gfx

import "base:runtime"
import "core:log"
import "core:reflect"

import vkb "shared:vkb"
import "shared:vma"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"


VK_VERSION :: vk.API_VERSION_1_4

REQUIRED_EXTENSIONS: []string = {vk.KHR_SWAPCHAIN_EXTENSION_NAME}

FRAMES_IN_FLIGHT :: 2

SwapchainData :: struct {
	swapchain:         ^vkb.Swapchain,
	images:            []vk.Image,
	image_views:       []vk.ImageView,
	render_semaphores: []vk.Semaphore,
	current_index:     u32,
}

FrameData :: struct {
	cmd_pool:          vk.CommandPool,
	cmd_buffer:        vk.CommandBuffer,
	present_semaphore: vk.Semaphore,
	in_flight_fence:   vk.Fence,
	descriptor_pool:   vk.DescriptorPool,
	ui_target:         RenderTarget2D,
}

Allocators :: struct {
	cpu: runtime.Allocator,
	gpu: vma.Allocator,
}

WindowContext :: struct {
	handle:        ^sdl.Window,
	surface:       vk.SurfaceKHR,
	capabilities:  vk.SurfaceCapabilitiesKHR,
	x:             i32,
	y:             i32,
	width:         i32,
	height:        i32,
	swapchain:     SwapchainData,
	frames:        [FRAMES_IN_FLIGHT]FrameData,
	current_frame: int,
}

QueueData :: struct {
	queue: vk.Queue,
	index: u32,
}

ImmediateData :: struct {
	cmd_pool:   vk.CommandPool,
	cmd_buffer: vk.CommandBuffer,
	fence:      vk.Fence,
}

RenderTarget2D :: AllocatedImage

RenderTarget3D :: struct {
	color: AllocatedImage,
	depth: AllocatedImage,
}

RenderContext :: struct {
	instance:               ^vkb.Instance,
	device:                 ^vkb.Device,
	allocators:             Allocators,
	graphics_queue:         QueueData,
	compute_queue:          QueueData,
	transfer_queue:         QueueData,
	window:                 WindowContext,
	immediate:              ImmediateData,
	global_descriptor_pool: vk.DescriptorPool,
	current_frame:          int,
	resize_requested:       bool,
	render_config:          RenderConfig,
	render_extent:          [2]u32,
}

DisplayMode :: enum {
	Windowed,
	Fullscreen,
	BorderlessWindowed,
}

RenderQuality :: enum {
	Low,
	Medium,
	High,
	Ultra,
	Custom,
}

RenderConfig :: struct {
	app_name:              cstring,
	app_version:           [3]u32,
	init_extent:           [2]i32,
	window_flags:          sdl.WindowFlags,
	display_mode:          DisplayMode,
	render_quality:        RenderQuality,
	custom_render_scale:   f32,
	min_render_resolution: [2]u32,
	max_render_resolution: [2]u32,
}

create_render_config :: proc() -> (c: RenderConfig) {
	c.app_name = "Change Me!"
	c.app_version = {0, 1, 0}
	c.init_extent = {640, 480}
	c.window_flags = {.BORDERLESS, .VULKAN}
	c.display_mode = .BorderlessWindowed
	c.render_quality = .High
	c.custom_render_scale = 1
	c.min_render_resolution = {640, 360}
	c.max_render_resolution = {3840, 2160}

	return
}

render_config_set_appname :: proc(c: ^RenderConfig, name: cstring) {
	c.app_name = name
}

render_config_set_app_version :: proc(c: ^RenderConfig, major, minor, patch: u32) {
	c.app_version = {major, minor, patch}
}

render_config_set_window_size :: proc(c: ^RenderConfig, #any_int width, height: i32) {
	c.init_extent = {width, height}
}

render_config_set_display_mode :: proc(c: ^RenderConfig, mode: DisplayMode) {
	switch c.display_mode {
	case .Windowed:
	case .BorderlessWindowed:
		c.window_flags &~= {.BORDERLESS}
	case .Fullscreen:
		c.window_flags &~= {.FULLSCREEN}
	}

	c.display_mode = mode
	switch c.display_mode {
	case .Windowed:
	case .BorderlessWindowed:
		c.window_flags |= {.BORDERLESS}
	case .Fullscreen:
		c.window_flags |= {.FULLSCREEN}
	}
}

render_config_set_resizeable :: proc(c: ^RenderConfig, resizeable: bool) {
	if resizeable {
		c.window_flags |= {.RESIZABLE}
	} else {
		c.window_flags &~= {.RESIZABLE}
	}
}

render_config_set_render_quality :: proc(c: ^RenderConfig, quality: RenderQuality) {
	c.render_quality = quality
}

render_config_set_custom_render_scale :: proc(c: ^RenderConfig, scale: f32) {
	c.custom_render_scale = scale
}

init_renderer :: proc(
	r: ^RenderContext,
	config: RenderConfig,
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	log.debug("Initializing Renderer")
	r.allocators.cpu = allocator

	render_extent: [2]i32
	r.render_config = config
	update_render_dimensions(r)

	init_sdl(r, config) or_return
	defer if !ok do cleanup_sdl(r)

	init_vulkan(r, config) or_return
	defer if !ok do cleanup_vulkan(r)

	create_swapchain(r, u32(config.init_extent.x), u32(config.init_extent.y))
	defer if !ok do destroy_swapchain(r)

	create_swapchain_data(r) or_return
	defer if !ok do destroy_swapchain_data(r)

	create_frame_data(r)
	defer if !ok do destroy_frame_data(r)

	create_immediate_data(r) or_return
	defer if !ok do destroy_immediate_data(r)

	log.info("Renderer initialized")

	return true
}

cleanup_renderer :: proc(r: ^RenderContext) {
	vk.DeviceWaitIdle(r.device.device)
	destroy_immediate_data(r)
	destroy_frame_data(r)
	destroy_swapchain_data(r)
	destroy_swapchain(r)
	cleanup_vulkan(r)
	cleanup_sdl(r)
}

@(private)
vk_check :: proc(result: vk.Result, loc := #caller_location) {
	p := context.assertion_failure_proc
	if result != .SUCCESS {
		when ODIN_DEBUG {
			p("vk_check failed", reflect.enum_string(result), loc)
		} else {
			p("vk_check failed", "NOT SUCCESS", loc)
		}
	}
}

@(private)
get_current_frame :: proc(r: ^RenderContext) -> (frame: ^FrameData) {
	return &r.window.frames[r.current_frame % FRAMES_IN_FLIGHT]
}

get_window_size :: proc(r: ^RenderContext) -> (width, height: i32) {
	sdl.GetWindowSize(r.window.handle, &width, &height)
	return
}

@(private)
get_scale_from_quality :: proc(quality: RenderQuality, custom_scale: f32) -> f32 {
	switch quality {
	case .Low:
		return 0.5
	case .Medium:
		return 0.75
	case .High:
		return 1.0
	case .Ultra:
		return 1.5
	case .Custom:
		return custom_scale
	}
	return 1.0
}

@(private)
update_render_dimensions :: proc(r: ^RenderContext) {
	render_scale := get_scale_from_quality(
		r.render_config.render_quality,
		r.render_config.custom_render_scale,
	)

	desired_width := u32(f32(r.window.width) * render_scale)
	desired_height := u32(f32(r.window.height) * render_scale)

	r.render_extent.x = clamp(
		desired_width,
		r.render_config.min_render_resolution.x,
		r.render_config.max_render_resolution.x,
	)
	r.render_extent.y = clamp(
		desired_height,
		r.render_config.min_render_resolution.y,
		r.render_config.max_render_resolution.y,
	)

	log.debugf(
		"Render resolution: %vx%v (scale: %.2f)",
		r.render_extent.x,
		r.render_extent.y,
		render_scale,
	)
}

handle_resize :: proc(r: ^RenderContext) {
	r.window.width, r.window.height = get_window_size(r)
	log.debugf("Handling resize to %vx%v", r.window.width, r.window.height)

	vk.DeviceWaitIdle(r.device.device)

	update_render_dimensions(r)

	resize_swapchain(r, u32(r.window.width), u32(r.window.height))
	resize_render_targets(r)

	r.resize_requested = false
}

prepare_frame :: proc(r: ^RenderContext) -> (cmd_buf: vk.CommandBuffer, ok: bool) {
	frame := get_current_frame(r)
	vk.WaitForFences(r.device.device, 1, &frame.in_flight_fence, true, max(u64))
	vk_check(vk.ResetFences(r.device.device, 1, &frame.in_flight_fence))

	res := vk.AcquireNextImageKHR(
		r.device.device,
		r.window.swapchain.swapchain.swapchain,
		max(u64),
		frame.present_semaphore,
		{},
		&r.window.swapchain.current_index,
	)
	#partial switch res {
	case .ERROR_OUT_OF_DATE_KHR:
		log.warn("Swapchain out of date during image acquisition")
		r.resize_requested = true
		return
	case .SUBOPTIMAL_KHR:
		log.warn("Swapchain suboptimal during image acquisition")
		r.resize_requested = true
	case .SUCCESS:
	case:
		vk_check(res)
	}

	vk_check(vk.ResetCommandPool(r.device.device, frame.cmd_pool, {}))
	vk_check(
		vk.BeginCommandBuffer(
			frame.cmd_buffer,
			&(vk.CommandBufferBeginInfo {
					sType = .COMMAND_BUFFER_BEGIN_INFO,
					flags = {.ONE_TIME_SUBMIT},
				}),
		),
	)

	return frame.cmd_buffer, true
}

submit_frame :: proc(r: ^RenderContext) {
	frame := get_current_frame(r)
	vk_check(vk.EndCommandBuffer(frame.cmd_buffer))

	submit_info: vk.SubmitInfo = {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &frame.present_semaphore,
		pWaitDstStageMask    = raw_data([]vk.PipelineStageFlags{{.COLOR_ATTACHMENT_OUTPUT}}),
		commandBufferCount   = 1,
		pCommandBuffers      = &frame.cmd_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &r.window.swapchain.render_semaphores[r.window.swapchain.current_index],
	}
	vk_check(vk.QueueSubmit(r.graphics_queue.queue, 1, &submit_info, frame.in_flight_fence))

	present_info: vk.PresentInfoKHR = {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &r.window.swapchain.render_semaphores[r.window.swapchain.current_index],
		swapchainCount     = 1,
		pSwapchains        = &r.window.swapchain.swapchain.swapchain,
		pImageIndices      = &r.window.swapchain.current_index,
	}
	res := vk.QueuePresentKHR(r.graphics_queue.queue, &present_info)

	#partial switch res {
	case .ERROR_OUT_OF_DATE_KHR, .SUBOPTIMAL_KHR:
		log.warn("Swapchain out of date during presentation")
		r.resize_requested = true
	case .SUCCESS:
	case:
		vk_check(res)
	}

	r.current_frame += 1
}

begin_rendering :: proc(r: ^RenderContext, buf: vk.CommandBuffer) {
	transition_image(
		buf,
		r.window.swapchain.images[r.window.swapchain.current_index],
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
	)

	clear_value: vk.ClearValue = {
		color = vk.ClearColorValue{float32 = [4]f32{f32(r.current_frame) / 1000.0, 0.0, 0.0, 0.0}},
	}

	render_area: vk.Rect2D = {
		offset = vk.Offset2D{0, 0},
		extent = vk.Extent2D{u32(r.window.width), u32(r.window.height)},
	}

	color_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = r.window.swapchain.image_views[r.window.swapchain.current_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = clear_value,
	}

	rendering_info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = render_area,
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment,
	}

	vk.CmdBeginRendering(buf, &rendering_info)
}

end_rendering :: proc(r: ^RenderContext, buf: vk.CommandBuffer) {
	vk.CmdEndRendering(buf)

	transition_image(
		buf,
		r.window.swapchain.images[r.window.swapchain.current_index],
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
	)
}

@(private)
init_sdl :: proc(r: ^RenderContext, config: RenderConfig) -> (ok: bool) {
	log.debug("Initializing SDL")
	sdl.SetHint(sdl.HINT_APP_ID, "com.boondax.dial") or_return
	sdl.Init({.VIDEO, .EVENTS}) or_return
	defer if !ok do sdl.Quit()

	r.window.handle = sdl.CreateWindow(
		config.app_name,
		config.init_extent.x,
		config.init_extent.y,
		{.VULKAN} | config.window_flags,
	)
	if r.window.handle == nil {
		log.errorf("Error creating SDL window: %#v", sdl.GetError())
		return
	}
	defer if !ok do sdl.DestroyWindow(r.window.handle)
	vk.load_proc_addresses(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))

	sdl.GetWindowSize(r.window.handle, &r.window.width, &r.window.height) or_return
	sdl.GetWindowPosition(r.window.handle, &r.window.x, &r.window.y) or_return

	log.debug(" - SDL initialized successfully")
	return true
}

@(private)
cleanup_sdl :: proc(r: ^RenderContext) {
	sdl.DestroyWindow(r.window.handle)
	sdl.Quit()
	log.debug("SDL cleaned up successfully")
}

@(private)
init_vulkan :: proc(r: ^RenderContext, config: RenderConfig) -> (ok: bool) {
	log.debug("Initializing Vulkan")
	sdl.Vulkan_LoadLibrary(nil) or_return
	defer if !ok do sdl.Vulkan_UnloadLibrary()

	window_ext_count: u32
	window_extensions := sdl.Vulkan_GetInstanceExtensions(&window_ext_count)

	instance_builder := vkb.instance_builder_make_with_proc_addr(
		cast(vk.ProcGetInstanceProcAddr)sdl.Vulkan_GetVkGetInstanceProcAddr(),
		r.allocators.cpu,
	)
	defer vkb.destroy_instance_builder(instance_builder)

	vkb.instance_builder_require_api_version(instance_builder, VK_VERSION)

	vkb.instance_builder_set_app_name(instance_builder, string(config.app_name))
	vkb.instance_builder_set_app_version(
		instance_builder,
		vk.MAKE_VERSION(config.app_version.x, config.app_version.y, config.app_version.z),
	)

	vkb.instance_builder_set_engine_name(instance_builder, "Dial")
	vkb.instance_builder_set_engine_version(instance_builder, vk.MAKE_VERSION(0, 1, 0))

	for ext in window_extensions[:window_ext_count] {
		vkb.instance_builder_enable_extension(instance_builder, string(ext))
		log.debugf(" - Enabling window extension: %s", ext)
	}

	when ODIN_DEBUG {
		vkb.instance_builder_enable_validation_layers(instance_builder)
		vkb.instance_builder_use_default_debug_messenger(instance_builder)
	}

	vkb_instance, vkb_instance_err := vkb.instance_builder_build(
		instance_builder,
		r.allocators.cpu,
	)
	if vkb_instance_err != nil {
		log.errorf("Failed to build instance: %#v", vkb_instance_err)
		return
	}
	defer if !ok do vkb.destroy_instance(vkb_instance)
	r.instance = vkb_instance
	vk.load_proc_addresses_instance(r.instance.instance)
	log.debug(" - Vulkan instance created successfully")

	if !sdl.Vulkan_CreateSurface(r.window.handle, r.instance.instance, nil, &r.window.surface) {
		log.errorf("Failed to create Vulkan surface: %#v", sdl.GetError())
		return
	}
	defer if !ok do vk.DestroySurfaceKHR(r.instance.instance, r.window.surface, nil)
	log.debug(" - Vulkan surface created successfully")

	selector := vkb.create_physical_device_selector(vkb_instance, r.allocators.cpu)
	defer vkb.destroy_physical_device_selector(selector)

	for ext in REQUIRED_EXTENSIONS {
		vkb.physical_device_selector_add_required_extension(selector, ext)
		log.debugf(" - Enabling required extension: %s", ext)
	}

	vkb.physical_device_selector_set_surface(selector, r.window.surface)
	vkb.physical_device_selector_set_minimum_version(selector, VK_VERSION)

	vkb.physical_device_selector_set_required_features(
		selector,
		vk.PhysicalDeviceFeatures{samplerAnisotropy = true},
	)

	vkb.physical_device_selector_set_required_features_11(
		selector,
		vk.PhysicalDeviceVulkan11Features{sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES},
	)

	vkb.physical_device_selector_set_required_features_12(
		selector,
		vk.PhysicalDeviceVulkan12Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
			descriptorIndexing = true,
			bufferDeviceAddress = true,
		},
	)

	vkb.physical_device_selector_set_required_features_13(
		selector,
		vk.PhysicalDeviceVulkan13Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
			synchronization2 = true,
			dynamicRendering = true,
		},
	)

	vkb.physical_device_selector_set_required_features_14(
		selector,
		vk.PhysicalDeviceVulkan14Features{sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES},
	)

	vkb_physical_device, vkb_physical_device_err := vkb.physical_device_selector_select(
		selector,
		r.allocators.cpu,
	)
	if vkb_physical_device_err != nil {
		log.errorf("Failed to select physical device: %#v", vkb_physical_device_err)
		return
	}
	defer if !ok do vkb.destroy_physical_device(vkb_physical_device)
	log.debug(" - Physical device selected successfully")

	vk_check(
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			vkb_physical_device.physical_device,
			r.window.surface,
			&r.window.capabilities,
		),
	)

	device_builder := vkb.create_device_builder(vkb_physical_device, r.allocators.cpu)
	defer vkb.destroy_device_builder(device_builder)

	vkb_device, vkb_device_err := vkb.device_builder_build(device_builder, r.allocators.cpu)
	if vkb_device_err != nil {
		log.errorf("Failed to get logical device: %#v", vkb_device_err)
		return
	}
	defer if !ok do vkb.destroy_device(vkb_device)
	r.device = vkb_device
	vk.load_proc_addresses_device(r.device.device)
	log.debug(" - Logical device created successfully")

	get_device_queue(&r.graphics_queue, vkb_device, .Graphics) or_return
	get_device_queue(&r.compute_queue, vkb_device, .Compute) or_return
	get_device_queue(&r.transfer_queue, vkb_device, .Transfer) or_return

	vulkan_functions := vma.create_vulkan_functions()
	vulkan_functions.get_buffer_memory_requirements2_khr = vk.GetBufferMemoryRequirements2
	vulkan_functions.get_image_memory_requirements2_khr = vk.GetImageMemoryRequirements2
	vulkan_functions.bind_buffer_memory2_khr = vk.BindBufferMemory2
	vulkan_functions.bind_image_memory2_khr = vk.BindImageMemory2

	alloc_info := vma.Allocator_Create_Info {
		vulkan_api_version = VK_VERSION,
		physical_device    = r.device.physical_device.physical_device,
		device             = r.device.device,
		instance           = r.instance.instance,
		vulkan_functions   = &vulkan_functions,
		flags              = {.Buffer_Device_Address},
	}

	vk_check(vma.create_allocator(alloc_info, &r.allocators.gpu))

	log.debug(" - Vulkan initialized successfully")
	return true
}

@(private)
get_device_queue :: proc(
	device_queue: ^QueueData,
	device: ^vkb.Device,
	queue_family: vkb.Queue_Type,
) -> (
	ok: bool,
) {
	family, family_ok := reflect.enum_name_from_value(queue_family)
	queue, queue_err := vkb.device_get_queue(device, queue_family)
	if queue_err != nil {
		log.errorf("Failed to get %s queue: %#v", family, queue_err)
		return
	}
	queue_index, queue_index_err := vkb.device_get_queue_index(device, queue_family)
	if queue_index_err != nil {
		log.errorf("Failed to get %s queue index: %#v", family, queue_index_err)
		return
	}

	device_queue.queue = queue
	device_queue.index = queue_index
	return true
}

@(private)
cleanup_vulkan :: proc(r: ^RenderContext) {
	vma.destroy_allocator(r.allocators.gpu)
	vkb.destroy_device(r.device)
	vkb.destroy_physical_device(r.device.physical_device)
	vk.DestroySurfaceKHR(r.instance.instance, r.window.surface, nil)
	vkb.destroy_instance(r.instance)
	sdl.Vulkan_UnloadLibrary()
	log.debug("Vulkan cleaned up successfully")
}

@(private)
create_swapchain :: proc(r: ^RenderContext, width, height: u32) -> (ok: bool) {
	log.debug("Creating Swapchain")
	builder := vkb.create_swapchain_builder(r.device, r.allocators.cpu)
	defer vkb.destroy_swapchain_builder(builder)

	vkb.swapchain_builder_set_old_swapchain_vkb(builder, r.window.swapchain.swapchain)
	vkb.swapchain_builder_use_default_format_selection(builder)
	vkb.swapchain_builder_set_desired_present_mode(builder, .FIFO)
	vkb.swapchain_builder_set_desired_extent(
		builder,
		max(r.window.capabilities.minImageExtent.width, width),
		max(r.window.capabilities.minImageExtent.height, height),
	)
	vkb.swapchain_builder_set_desired_min_image_count(builder, FRAMES_IN_FLIGHT)
	vkb.swapchain_builder_set_pre_transform_flags(builder, {.IDENTITY})

	swapchain, err := vkb.swapchain_builder_build(builder, r.allocators.cpu)
	if err != nil {
		log.errorf("Failed to build swapchain: %#v", err)
		return
	}

	if r.window.swapchain.swapchain != nil {
		vkb.destroy_swapchain(r.window.swapchain.swapchain)
	}

	r.window.swapchain.swapchain = swapchain
	return true
}

@(private)
destroy_swapchain :: proc(r: ^RenderContext) {
	vkb.destroy_swapchain(r.window.swapchain.swapchain)
	log.debug("Swapchain destroyed")
}

@(private)
create_swapchain_data :: proc(r: ^RenderContext) -> (ok: bool) {
	err: vkb.Error
	r.window.swapchain.images, err = vkb.swapchain_get_images(
		r.window.swapchain.swapchain,
		allocator = r.allocators.cpu,
	)
	if err != nil {
		log.errorf("Could not create swapchain images: %#v", err)
		return
	}

	r.window.swapchain.image_views, err = vkb.swapchain_get_image_views(
		r.window.swapchain.swapchain,
		allocator = r.allocators.cpu,
	)
	if err != nil {
		log.errorf("Could not create swapchain image views: %#v", err)
		return
	}

	r.window.swapchain.render_semaphores = make(
		[]vk.Semaphore,
		len(r.window.swapchain.images),
		r.allocators.cpu,
	)
	semaphore_info: vk.SemaphoreCreateInfo = {
		sType = .SEMAPHORE_CREATE_INFO,
		flags = {},
	}

	for &sem in r.window.swapchain.render_semaphores {
		vk_check(vk.CreateSemaphore(r.device.device, &semaphore_info, nil, &sem))
	}

	return true
}

@(private)
destroy_swapchain_data :: proc(r: ^RenderContext) {
	log.debug("Destroying Swapchain Data")
	for sem in r.window.swapchain.render_semaphores {
		vk.DestroySemaphore(r.device.device, sem, nil)
	}
	delete(r.window.swapchain.render_semaphores)
	vkb.swapchain_destroy_image_views(r.window.swapchain.swapchain, r.window.swapchain.image_views)
	delete(r.window.swapchain.images)
	delete(r.window.swapchain.image_views)
}

@(private)
create_frame_data :: proc(r: ^RenderContext) {
	log.debug("Creating FrameData")

	cmd_pool_info: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.graphics_queue.index,
	}

	cmd_buffer_info: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	sem_info: vk.SemaphoreCreateInfo = {
		sType = .SEMAPHORE_CREATE_INFO,
		flags = {},
	}

	fence_info: vk.FenceCreateInfo = {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	pool_sizes := []vk.DescriptorPoolSize {
		{type = .UNIFORM_BUFFER, descriptorCount = 10},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 10},
	}

	desc_pool_info: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 10,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	for &frame_data in r.window.frames {
		vk_check(vk.CreateCommandPool(r.device.device, &cmd_pool_info, nil, &frame_data.cmd_pool))

		cmd_buffer_info.commandPool = frame_data.cmd_pool
		vk_check(
			vk.AllocateCommandBuffers(r.device.device, &cmd_buffer_info, &frame_data.cmd_buffer),
		)

		vk_check(
			vk.CreateSemaphore(r.device.device, &sem_info, nil, &frame_data.present_semaphore),
		)

		vk_check(vk.CreateFence(r.device.device, &fence_info, nil, &frame_data.in_flight_fence))

		vk_check(
			vk.CreateDescriptorPool(
				r.device.device,
				&desc_pool_info,
				nil,
				&frame_data.descriptor_pool,
			),
		)

		frame_data.ui_target = create_image(
			r,
			vk.Extent3D{width = r.render_extent.x, height = r.render_extent.y, depth = 1},
			.R8G8B8A8_SRGB,
			{.COLOR_ATTACHMENT, .SAMPLED},
		)
	}
}

@(private)
destroy_frame_data :: proc(r: ^RenderContext) {
	log.debug("Destroying FrameData")
	for frame_data in r.window.frames {
		vk.DestroyDescriptorPool(r.device.device, frame_data.descriptor_pool, nil)
		vk.DestroyFence(r.device.device, frame_data.in_flight_fence, nil)
		vk.DestroySemaphore(r.device.device, frame_data.present_semaphore, nil)
		vk.DestroyCommandPool(r.device.device, frame_data.cmd_pool, nil)
		destroy_image(r, frame_data.ui_target)
	}
}

@(private)
resize_render_targets :: proc(r: ^RenderContext) {
	log.debug("Destroying FrameData")
	for &frame_data in r.window.frames {
		destroy_image(r, frame_data.ui_target)
		frame_data.ui_target = create_image(
			r,
			vk.Extent3D{width = r.render_extent.x, height = r.render_extent.y, depth = 1},
			.R8G8B8A8_SRGB,
			{.COLOR_ATTACHMENT, .SAMPLED},
		)
	}
}

@(private)
resize_swapchain :: proc(r: ^RenderContext, width, height: u32) -> (ok: bool) {
	vk.DeviceWaitIdle(r.device.device)

	destroy_swapchain_data(r)
	create_swapchain(r, width, height) or_return
	create_swapchain_data(r) or_return

	return true
}

@(private)
create_immediate_data :: proc(r: ^RenderContext) -> (ok: bool) {
	log.debug("Creating ImmediateData")

	cmd_pool_info: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.TRANSIENT, .RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.graphics_queue.index,
	}

	vk_check(vk.CreateCommandPool(r.device.device, &cmd_pool_info, nil, &r.immediate.cmd_pool))

	cmd_buffer_info: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.immediate.cmd_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	vk_check(vk.AllocateCommandBuffers(r.device.device, &cmd_buffer_info, &r.immediate.cmd_buffer))

	fence_info: vk.FenceCreateInfo = {
		sType = .FENCE_CREATE_INFO,
		flags = {},
	}

	vk_check(vk.CreateFence(r.device.device, &fence_info, nil, &r.immediate.fence))

	log.debug(" - ImmediateData created successfully")
	return true
}

@(private)
destroy_immediate_data :: proc(r: ^RenderContext) {
	vk.DestroyFence(r.device.device, r.immediate.fence, nil)
	vk.DestroyCommandPool(r.device.device, r.immediate.cmd_pool, nil)
	log.debug("ImmediateData destroyed")
}
