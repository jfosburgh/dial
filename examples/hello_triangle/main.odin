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

	config := gfx.create_render_config()
	gfx.render_config_set_resizeable(&config, true)
	gfx.render_config_set_appname(&config, "Hello Triangle")
	gfx.render_config_set_app_version(&config, 0, 1, 0)
	gfx.render_config_set_window_size(&config, WIDTH, HEIGHT)

	renderer: gfx.RenderContext
	assert(gfx.init_renderer(&renderer, config, context.allocator))

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
			case .KEY_UP:
				#partial switch e.key.scancode {
				case .ESCAPE:
					break loop
				case .LEFTBRACKET:
					next_quality: gfx.RenderQuality
					switch renderer.render_config.render_quality {
					case .Low:
						continue
					case .Medium:
						next_quality = .Low
					case .High:
						next_quality = .Medium
					case .Ultra:
						next_quality = .High
					case .Custom:
						next_quality = .Ultra
					}
					gfx.render_config_set_render_quality(&renderer.render_config, next_quality)
					renderer.resize_requested = true
				case .RIGHTBRACKET:
					next_quality: gfx.RenderQuality
					switch renderer.render_config.render_quality {
					case .Low:
						next_quality = .Medium
					case .Medium:
						next_quality = .High
					case .High:
						next_quality = .Ultra
					case .Ultra:
						next_quality = .Custom
					case .Custom:
						continue
					}
					gfx.render_config_set_render_quality(&renderer.render_config, next_quality)
					renderer.resize_requested = true
				}
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
