package main

import "core:log"
import "core:mem"

import "../../src/gfx"

import sdl "vendor:sdl3"


WIDTH :: 800
HEIGHT :: 600

main :: proc() {
	when ODIN_DEBUG {
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

	level: log.Level = .Info
	when ODIN_DEBUG {
		level = .Debug
	}
	context.logger = log.create_console_logger(level)

	renderer: gfx.RenderContext
	assert(
		gfx.init_renderer(
			&renderer,
			{
				init_extent = {WIDTH, HEIGHT},
				app_name = "Hello Triangle",
				app_version = {1, 0, 0},
				window_flags = {.RESIZABLE, .BORDERLESS},
			},
			context.allocator,
		),
	)

	loop: for {
		e: sdl.Event
		for sdl.PollEvent(&e) {
			#partial switch e.type {
			case .QUIT:
				log.info("Quit event received, exiting main loop")
				break loop
			case .WINDOW_RESIZED:
				log.debugf("Window resized to %vx%v", e.window.data1, e.window.data2)
				renderer.resize_requested = true
			}
		}

		if renderer.resize_requested {
			gfx.handle_resize(&renderer)
		}

		buf := gfx.prepare_frame(&renderer) or_continue
		defer gfx.submit_frame(&renderer)

		gfx.begin_rendering(&renderer, buf)
		defer gfx.end_rendering(&renderer, buf)
	}

	defer gfx.cleanup_renderer(&renderer)
}
