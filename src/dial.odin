package dial

import gpu "deps/no_gfx_api/gpu"
import "base:runtime"
import "core:log"
import "core:mem"
import "input"
import sdl "vendor:sdl3"


FRAMES_IN_FLIGHT :: 2

OdinContext :: struct {
	allocator:      runtime.Allocator,
	temp_allocator: runtime.Allocator,
	ctx:            runtime.Context,
}

WindowConfig :: struct {
	name:  cstring,
	size:  [2]i32,
	flags: sdl.WindowFlags,
}

WindowContext :: struct {
	handle:           ^sdl.Window,
	id:               sdl.WindowID,
	frame_sem:        gpu.Semaphore,
	arenas:           [FRAMES_IN_FLIGHT]gpu.Arena,
	size:             [2]i32,
	next_frame:       u64,
	resize_requested: bool,
	initialized:      bool,
}

Engine :: struct {
	odin_ctx:       OdinContext,
	window:         WindowContext,
	ts_freq:        u64,
	ts_now:         u64,
	delta:          f32,
	headless:       bool,
	quit_requested: bool,
	shared_arena:   gpu.Arena,
}

@(private)
e: ^Engine

init_engine :: proc(
	sdl_flags: sdl.InitFlags,
	window_config: WindowConfig = {},
	debug: bool,
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

	e = new(Engine, allocator, loc)
	e.odin_ctx = {allocator, temp_allocator, context}

	e.headless = window_config == {}
	if e.headless {
		log.debugf("running headless")
	}

	init_sdl("com.boondax.dial", sdl_flags) or_return
	defer if !ok do cleanup_sdl()
	log.debug("SDL initialized")

	input.init_input(request_quit, resize_window, e.odin_ctx.allocator) or_return
	defer if !ok do input.destroy_input()
	log.debug("Input initialized")

	gpu.init(debug) or_return
	defer if !ok do gpu.cleanup()
	log.debug("Vulkan context initialized")
	e.shared_arena = gpu.arena_init()

	if !e.headless {
		create_window(window_config) or_return
		log.debug("Window created")
	}
	defer if !ok && !e.headless do destroy_window()

	e.ts_now = sdl.GetPerformanceCounter()

	return true
}

destroy_engine :: proc() {
	if e == nil do return
	gpu.wait_idle()

	gpu.arena_destroy(&e.shared_arena)

	if !e.headless do destroy_window()
	gpu.cleanup()
	input.destroy_input()
	cleanup_sdl()

	free(e)
}

should_quit :: proc() -> bool {
	input.update_input()
	return e.quit_requested
}

delta :: proc() -> f32 {
	return e.delta
}

resize_window :: proc(window_id: sdl.WindowID) {
	if window_id != e.window.id {
		log.debugf("Received resize requested for non-existent window %+v", window_id)
	}
	e.window.resize_requested = true
}

create_shared_memory :: proc {
	create_shared_memory_ptr,
	create_shared_memory_slice,
}

create_shared_memory_ptr :: proc($T: typeid) -> gpu.ptr_t(T) {
	return gpu.arena_alloc(&e.shared_arena, T)
}

create_shared_memory_slice :: proc($T: typeid, n: int) -> gpu.slice_t(T) {
	return gpu.arena_alloc(&e.shared_arena, T, n)
}

create_shared_frame_memory :: proc {
	create_shared_frame_memory_ptr,
	create_shared_frame_memory_slice,
}

create_shared_frame_memory_ptr :: proc($T: typeid, arena: ^gpu.Arena) -> gpu.ptr_t(T) {
	return gpu.arena_alloc(arena, T)
}

create_shared_frame_memory_slice :: proc($T: typeid, n: int, arena: ^gpu.Arena) -> gpu.slice_t(T) {
	return gpu.arena_alloc(arena, T, n)
}

draw_indexed_instanced :: gpu.cmd_draw_indexed_instanced
draw_instanced :: gpu.cmd_draw_instanced
set_shaders :: gpu.cmd_set_shaders
create_shader :: gpu.shader_create
destroy_shader :: gpu.shader_destroy
set_raster_state :: gpu.cmd_set_raster_state
set_blend_state :: gpu.cmd_set_blend_state

@(private)
init_sdl :: proc(app_id: cstring, flags: sdl.InitFlags) -> (ok: bool) {
	log.debug("initializing sdl")
	defer if !ok do log_sdl()

	sdl.SetAppMetadataProperty(sdl.PROP_APP_METADATA_IDENTIFIER_STRING, app_id) or_return

	sdl.Init(flags) or_return
	defer if !ok do sdl.Quit()

	e.ts_freq = sdl.GetPerformanceFrequency()

	return true
}

request_quit :: proc() {
	e.quit_requested = true
}

@(private)
cleanup_sdl :: proc() {
	sdl.Quit()
}

@(private)
log_sdl :: proc() {
	log.errorf("SDL Error: %s", sdl.GetError())
}

@(private)
create_window :: proc(config: WindowConfig) -> (ok: bool) {
	e.window.handle = sdl.CreateWindow(config.name, config.size.x, config.size.y, config.flags)
	if e.window.handle == nil do return

	e.window.id = sdl.GetWindowID(e.window.handle)
	e.window.initialized = true

	sdl.GetWindowSize(e.window.handle, &e.window.size.x, &e.window.size.y) or_return

	gpu.swapchain_init_from_sdl(e.window.handle, FRAMES_IN_FLIGHT)
	e.window.frame_sem = gpu.semaphore_create(0)
	e.window.next_frame = 1

	for i in 0 ..< FRAMES_IN_FLIGHT do e.window.arenas[i] = gpu.arena_init()

	ok = true
	return
}

@(private)
destroy_window :: proc() {
	for i in 0 ..< FRAMES_IN_FLIGHT do gpu.arena_destroy(&e.window.arenas[i])
	gpu.semaphore_destroy(e.window.frame_sem)
	sdl.DestroyWindow(e.window.handle)
	e.window = {}
}

set_exit_key :: input.set_quit_key

main :: proc() {
	log_level: log.Level = .Info
	log_opts: log.Options = {.Level, .Line, .Terminal_Color}
	log_ident := "Dial"

	when ODIN_DEBUG {
		log_level = .Debug
		log_opts |= {.Date, .Time, .Short_File_Path}

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

	if !init_engine({.VIDEO, .EVENTS}, {name = "Dial Example", size = {600, 600}, flags = {.VULKAN, .HIGH_PIXEL_DENSITY, .RESIZABLE}}, ODIN_DEBUG) do return
	defer destroy_engine()

	input.set_quit_key(.ESCAPE)

	for !should_quit() {
		input.update_input()
		if swapchain, frame_arena, buf, ok := frame_prepare(); ok {
			gpu.cmd_begin_render_pass(
				buf,
				{color_attachments = {{texture = swapchain, clear_color = {1, 0, 0, 0}}}},
			)
			gpu.cmd_end_render_pass(buf)
		}
	}
}
