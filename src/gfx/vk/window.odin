package gfx

import sdl "vendor:sdl3"
import vk "vendor:vulkan"


WindowConfig :: struct {
	window_title, app_id: cstring,
	width, height:        i32,
	window_flags:         sdl.WindowFlags,
}

create_window :: proc(c: WindowConfig) -> ^sdl.Window {
	return sdl.CreateWindow(c.window_title, c.width, c.height, c.window_flags)
}

destroy_window :: proc(window: ^sdl.Window) {
	sdl.DestroyWindow(window)
}

create_window_surface :: proc(
	window: ^sdl.Window,
	instance: vk.Instance,
) -> (
	surface: vk.SurfaceKHR,
	ok: bool,
) {
	ok = sdl.Vulkan_CreateSurface(window, instance, nil, &surface)
	return
}
