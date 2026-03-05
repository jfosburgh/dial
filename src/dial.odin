package dial

import gfx "./gfx/vk"
import "base:runtime"
import "core:log"
import "core:mem"
import vma "shared:vma"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"


FRAMES_IN_FLIGHT :: 2
GLOBAL_TEXTURE_LIMIT :: 65536

OdinContext :: struct {
	allocator:      runtime.Allocator,
	temp_allocator: runtime.Allocator,
	ctx:            runtime.Context,
}

VkContext :: struct {
	instance:             vk.Instance,
	physical_device_info: gfx.PhysicalDeviceInfo,
	device:               vk.Device,
	debug_messenger:      vk.DebugUtilsMessengerEXT,
	allocator:            vma.Allocator,
	queue_index:          u32,
	queue:                vk.Queue,
}

ImmediateContext :: struct {
	pool:  vk.CommandPool,
	buf:   vk.CommandBuffer,
	fence: vk.Fence,
}

WindowContext :: struct {
	window:           ^sdl.Window,
	surface:          vk.SurfaceKHR,
	swapchain:        gfx.Swapchain,
	render_target:    gfx.RenderTarget,
	pool:             vk.CommandPool,
	frames:           [FRAMES_IN_FLIGHT]gfx.FrameData,
	initialized:      bool,
	frame_index:      uint,
	resize_requested: bool,
}

DescriptorContext :: struct {
	pool:   vk.DescriptorPool,
	set:    vk.DescriptorSet,
	layout: vk.DescriptorSetLayout,
}

Engine :: struct {
	odin_ctx:                  OdinContext,
	vk_ctx:                    VkContext,
	imm_ctx:                   ImmediateContext,
	primary_window:            WindowContext,
	global_texture_descriptor: DescriptorContext,
}

e: ^Engine

init_engine :: proc(
	render_config: RendererConfig,
	sdl_flags: sdl.InitFlags,
	window_config: gfx.WindowConfig = {},
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
	loc := #caller_location,
) -> (
	ok: bool,
) {
	if e != nil {
		log.errorf("Engine already initialized")
		return
	}

	if !render_config.headless && window_config == {} {
		log.errorf("Either provide a window context or set to headless mode")
		return
	}

	e = new(Engine, allocator, loc)
	e.odin_ctx = {allocator, temp_allocator, context}

	init_sdl(render_config.app_name, sdl_flags) or_return
	defer if !ok do cleanup_sdl()

	init_renderer(render_config, allocator) or_return
	defer if !ok do cleanup_renderer()

	create_window(window_config, &e.primary_window) or_return
	defer if !ok do destroy_window(&e.primary_window)

	create_global_texture_descriptors()
	defer if !ok do destroy_global_texture_descriptors()

	return true
}

destroy_engine :: proc() {
	if e == nil do return

	destroy_global_texture_descriptors()
	if e.primary_window.initialized do destroy_window(&e.primary_window)
	cleanup_renderer()
	cleanup_sdl()

	free(e)
}

RendererConfig :: struct {
	vk_version:  gfx.VkVersion,
	app_name:    cstring,
	app_version: SemVer,
	msaa_limit:  int,
	headless:    bool,
	debug:       bool,
}

SemVer :: struct {
	major, minor, patch: u32,
}

init_renderer :: proc(
	render_config: RendererConfig,
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	// Create Vulkan Instance
	{
		b: gfx.InstanceBuilder
		gfx.ib_init(&b)
		defer gfx.ib_destroy(b)

		gfx.ib_set_vulkan_api_version(&b, render_config.vk_version)
		gfx.ib_set_application_version(
			&b,
			render_config.app_version.major,
			render_config.app_version.minor,
			render_config.app_version.patch,
		)
		gfx.ib_set_application_name(&b, render_config.app_name)
		gfx.ib_set_engine_version(&b, 0, 1, 0)
		gfx.ib_set_engine_name(&b, "com.boondax.dial")

		if !render_config.headless {
			sdl_extension_count: u32
			sdl_extensions := sdl.Vulkan_GetInstanceExtensions(&sdl_extension_count)
			gfx.ib_add_extensions(&b, ..sdl_extensions[0:sdl_extension_count])
		}

		if render_config.debug {
			gfx.ib_add_extensions(&b, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

			severity: vk.DebugUtilsMessageSeverityFlagsEXT
			if context.logger.lowest_level <= .Error {
				severity |= {.ERROR}
			}
			if context.logger.lowest_level <= .Warning {
				severity |= {.WARNING}
			}
			gfx.ib_add_debug_severity_levels(&b, severity)
		}

		e.vk_ctx.instance, e.vk_ctx.debug_messenger = gfx.ib_build_instance(&b) or_return
	}
	defer if !ok {
		if render_config.debug do vk.DestroyDebugUtilsMessengerEXT(e.vk_ctx.instance, e.vk_ctx.debug_messenger, nil)
		vk.DestroyInstance(e.vk_ctx.instance, nil)
	}

	// Create Physical Device
	{
		b: gfx.PhysicalDeviceBuilder
		gfx.pdb_init(&b)
		defer gfx.pdb_destroy(b)

		temp_window: ^sdl.Window
		temp_surface: vk.SurfaceKHR
		defer if !render_config.headless do vk.DestroySurfaceKHR(e.vk_ctx.instance, temp_surface, nil)
		defer if !render_config.headless do sdl.DestroyWindow(temp_window)
		if !render_config.headless {
			temp_window = sdl.CreateWindow("", 10, 10, {.VULKAN})
			sdl.Vulkan_CreateSurface(temp_window, e.vk_ctx.instance, nil, &temp_surface)
			gfx.pdb_add_required_extensions(&b, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
			gfx.pdb_set_surface(&b, temp_surface)
		}

		gfx.pdb_enable_anisotropy(&b, true)
		gfx.pdb_set_msaa_limit(&b, render_config.msaa_limit)
		e.vk_ctx.physical_device_info = gfx.pdb_pick_physical_device(
			&b,
			e.vk_ctx.instance,
			allocator,
		) or_return
	}
	defer if !ok do gfx.destroy_physical_device_info(e.vk_ctx.physical_device_info)

	// TODO: better queues
	graphics_index := e.vk_ctx.physical_device_info.queue_families[.Graphics].? or_return
	present_index := e.vk_ctx.physical_device_info.queue_families[.Graphics].? or_return
	if graphics_index != present_index {
		log.error("graphics and present not the same index, get good")
		return
	}
	e.vk_ctx.queue_index = graphics_index

	// Create Logical Device
	{
		b: gfx.LogicalDeviceBuilder
		gfx.ldb_init(&b, allocator)
		defer gfx.ldb_destroy(b)

		gfx.ldb_add_device_queue(&b, graphics_index, 1, {0.5}) or_return
		gfx.ldb_set_msaa_enabled(&b, true)
		gfx.ldb_set_multi_draw_indirect_enabled(&b, true)
		gfx.ldb_set_shader_ints_enabled(&b, false, true)
		gfx.ldb_set_extended_dynamic_state_enabled(&b, true)
		gfx.ldb_set_dynamic_rendering_enabled(&b, true)
		gfx.ldb_set_bindless_enabled(&b, true)
		if !render_config.headless {
			gfx.ldb_add_extensions(&b, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
		}

		gfx.ldb_build_logical_device(
			&b,
			e.vk_ctx.physical_device_info.device,
			&e.vk_ctx.device,
			allocator,
		)
		vk.GetDeviceQueue(e.vk_ctx.device, graphics_index, 0, &e.vk_ctx.queue)
	}
	defer if !ok do vk.DestroyDevice(e.vk_ctx.device, nil)

	// Setup VMA
	{
		gfx.create_vma(
			e.vk_ctx.instance,
			e.vk_ctx.physical_device_info.device,
			e.vk_ctx.device,
			._1_4,
			{.Buffer_Device_Address},
			&e.vk_ctx.allocator,
		) or_return
	}
	defer if !ok do gfx.destroy_vma(e.vk_ctx.allocator)

	// Setup Immediate Context
	{
		pool_info: vk.CommandPoolCreateInfo = {
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = graphics_index,
		}

		vk_check(vk.CreateCommandPool(e.vk_ctx.device, &pool_info, nil, &e.imm_ctx.pool))

		fence_info: vk.FenceCreateInfo = {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		vk_check(vk.CreateFence(e.vk_ctx.device, &fence_info, nil, &e.imm_ctx.fence))

		cmd_buf_info: vk.CommandBufferAllocateInfo = {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = e.imm_ctx.pool,
			commandBufferCount = 1,
		}
		vk_check(vk.AllocateCommandBuffers(e.vk_ctx.device, &cmd_buf_info, &e.imm_ctx.buf))
	}

	return true
}

@(private)
cleanup_renderer :: proc() {
	vk.DestroyCommandPool(e.vk_ctx.device, e.imm_ctx.pool, nil)
	vk.DestroyFence(e.vk_ctx.device, e.imm_ctx.fence, nil)

	gfx.destroy_vma(e.vk_ctx.allocator)
	vk.DestroyDevice(e.vk_ctx.device, nil)
	if e.vk_ctx.debug_messenger != {} {
		vk.DestroyDebugUtilsMessengerEXT(e.vk_ctx.instance, e.vk_ctx.debug_messenger, nil)
	}
	gfx.destroy_physical_device_info(e.vk_ctx.physical_device_info)
	vk.DestroyInstance(e.vk_ctx.instance, nil)
}

@(private)
init_sdl :: proc(app_id: cstring, flags: sdl.InitFlags) -> (ok: bool) {
	defer if !ok do log_sdl()

	sdl.SetAppMetadataProperty(sdl.PROP_APP_METADATA_IDENTIFIER_STRING, app_id) or_return

	sdl.Init(flags) or_return
	defer if !ok do sdl.Quit()

	sdl.Vulkan_LoadLibrary(nil) or_return
	defer if !ok do sdl.Vulkan_UnloadLibrary()

	vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))

	return true
}

@(private)
cleanup_sdl :: proc() {
	sdl.Vulkan_UnloadLibrary()
	sdl.Quit()
}

@(private)
log_sdl :: proc() {
	log.errorf("SDL Error: %s", sdl.GetError())
}

@(private)
vk_check :: proc(res: vk.Result, loc := #caller_location) {
	#partial switch res {
	case .SUCCESS:
	case:
		log.fatalf("Vulkan Error: %v", res, loc)
	}
}

create_window :: proc(config: gfx.WindowConfig, win_ctx: ^WindowContext) -> (ok: bool) {
	win_ctx.window = gfx.create_window(config)
	defer if !ok do gfx.destroy_window(win_ctx.window)

	win_ctx.surface = gfx.create_window_surface(win_ctx.window, e.vk_ctx.instance) or_return
	defer if !ok do vk.DestroySurfaceKHR(e.vk_ctx.instance, win_ctx.surface, nil)

	gfx.create_swapchain(
		e.vk_ctx.device,
		win_ctx.window,
		win_ctx.surface,
		e.vk_ctx.physical_device_info.swapchain_support,
		&win_ctx.swapchain,
		e.odin_ctx.allocator,
	) or_return
	defer if !ok do gfx.destroy_swapchain(e.vk_ctx.device, win_ctx.swapchain)

	gfx.create_swapchain_data(e.vk_ctx.device, &win_ctx.swapchain, e.odin_ctx.allocator) or_return
	defer if !ok do gfx.destroy_swapchain_data(e.vk_ctx.device, win_ctx.swapchain)

	win_ctx.render_target.msaa_samples = {e.vk_ctx.physical_device_info.msaa_samples}
	gfx.create_render_target(
		e.vk_ctx.device,
		e.vk_ctx.physical_device_info.device,
		&win_ctx.render_target,
		win_ctx.swapchain,
		e.vk_ctx.allocator,
	) or_return
	defer if !ok do gfx.destroy_render_target(e.vk_ctx.device, win_ctx.render_target, e.vk_ctx.allocator)

	pool_info: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = e.vk_ctx.queue_index,
	}

	vk_check(vk.CreateCommandPool(e.vk_ctx.device, &pool_info, nil, &win_ctx.pool))
	defer if !ok do vk.DestroyCommandPool(e.vk_ctx.device, win_ctx.pool, nil)

	alloc_info: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = win_ctx.pool,
		commandBufferCount = 1,
		level              = .PRIMARY,
	}

	for &frame in win_ctx.frames {
		vk_check(vk.AllocateCommandBuffers(e.vk_ctx.device, &alloc_info, &frame.buffer))
		vk_check(
			vk.CreateSemaphore(
				e.vk_ctx.device,
				&vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO},
				nil,
				&frame.semaphore,
			),
		)
		vk_check(
			vk.CreateFence(
				e.vk_ctx.device,
				&vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
				nil,
				&frame.fence,
			),
		)
	}
	defer if !ok {
		for frame in win_ctx.frames {
			vk.DestroyFence(e.vk_ctx.device, frame.fence, nil)
			vk.DestroySemaphore(e.vk_ctx.device, frame.semaphore, nil)
		}
	}

	win_ctx.initialized = true
	ok = true
	return
}

destroy_window :: proc(win_ctx: ^WindowContext) {
	for frame in win_ctx.frames {
		vk.DestroyFence(e.vk_ctx.device, frame.fence, nil)
		vk.DestroySemaphore(e.vk_ctx.device, frame.semaphore, nil)
	}
	vk.DestroyCommandPool(e.vk_ctx.device, win_ctx.pool, nil)
	gfx.destroy_render_target(e.vk_ctx.device, win_ctx.render_target, e.vk_ctx.allocator)
	gfx.destroy_swapchain_data(e.vk_ctx.device, win_ctx.swapchain)
	gfx.destroy_swapchain(e.vk_ctx.device, win_ctx.swapchain)
	vk.DestroySurfaceKHR(e.vk_ctx.instance, win_ctx.surface, nil)
	gfx.destroy_window(win_ctx.window)
	win_ctx.initialized = false
}

create_global_texture_descriptors :: proc() {
	b: gfx.DescriptorBuilder
	gfx.db_init(&b, e.odin_ctx.allocator)
	defer gfx.db_destroy(b)

	gfx.db_add_binding(
		&b,
		.COMBINED_IMAGE_SAMPLER,
		GLOBAL_TEXTURE_LIMIT,
		{.FRAGMENT},
		{.UPDATE_AFTER_BIND, .PARTIALLY_BOUND},
	)
	gfx.db_enable_update_after_bind(&b)

	gfx.db_build_descriptor(
		&b,
		e.vk_ctx.device,
		FRAMES_IN_FLIGHT,
		&e.global_texture_descriptor.pool,
		&e.global_texture_descriptor.set,
		&e.global_texture_descriptor.layout,
		e.odin_ctx.allocator,
	)
}

destroy_global_texture_descriptors :: proc() {
	vk.DestroyDescriptorSetLayout(e.vk_ctx.device, e.global_texture_descriptor.layout, nil)
	vk.DestroyDescriptorPool(e.vk_ctx.device, e.global_texture_descriptor.pool, nil)
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

	create_mesh([]f32{1, 2, 3}, {1, 2, 3})
}
