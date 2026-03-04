package input

import "core:log"
import sdl "vendor:sdl3"


Context :: struct {
	window:          ^sdl.Window,
	keys:            Keys,
	mouse:           MouseState,
	resize_callback: #type proc(),
	quit_callback:   #type proc(),
}

KeyState :: enum {
	Released,
	JustReleased,
	Pressed,
	JustPressed,
}

MouseState :: struct {
	x_loc, y_loc, x_rel, y_rel: f32,
}

DOWN :: bit_set[KeyState]{.Pressed, .JustPressed}

Keys :: map[sdl.Scancode]KeyState

c: ^Context

init_input :: proc(
	window: ^sdl.Window,
	quit_callback: proc(),
	resize_callback: proc(),
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	if c != nil do return false

	c = new(Context, allocator, loc)
	c.window = window
	c.quit_callback = quit_callback
	c.resize_callback = resize_callback
	c.keys = make(map[sdl.Scancode]KeyState, allocator)

	log.info("Input initialized")

	sdl.SetWindowRelativeMouseMode(window, true) or_return

	return true
}

destroy_input :: proc() {
	delete(c.keys)
	free(c)
	c = nil
}

update_input :: proc() -> (quit: bool) {
	for code in c.keys {
		#partial switch c.keys[code] {
		case .JustReleased:
			c.keys[code] = .Released
		case .JustPressed:
			c.keys[code] = .Pressed
		}
	}
	c.mouse.x_rel = 0
	c.mouse.y_rel = 0

	e: sdl.Event
	event_loop: for sdl.PollEvent(&e) {
		#partial switch e.type {
		case .QUIT:
			c.quit_callback()
			log.debug("SDL requested quit")
			return true
		case .WINDOW_RESIZED:
			w, h: i32
			sdl.GetWindowSize(c.window, &w, &h)
			c.resize_callback()
		case .KEY_DOWN:
			c.keys[e.key.scancode] = .JustPressed
		case .KEY_UP:
			c.keys[e.key.scancode] = .JustReleased
		case .MOUSE_MOTION:
			c.mouse.x_loc = e.motion.x
			c.mouse.y_loc = e.motion.y
			c.mouse.x_rel += e.motion.xrel
			c.mouse.y_rel += e.motion.yrel
		}
	}

	return
}

get_axis_1d :: proc(left, right: sdl.Scancode) -> (axis: f32) {
	pressed := bit_set[KeyState]{.Pressed, .JustPressed}
	if c.keys[left] in pressed do axis -= 1
	if c.keys[right] in pressed do axis += 1
	return
}

get_axis_2d :: proc(
	forward, backward, left, right: sdl.Scancode,
) -> (
	out_forward, out_right: f32,
) {
	if c.keys[left] in DOWN do out_right -= 1
	if c.keys[right] in DOWN do out_right += 1
	if c.keys[backward] in DOWN do out_forward -= 1
	if c.keys[forward] in DOWN do out_forward += 1
	return
}

get_mouse_movement :: proc() -> (f32, f32) {
	return c.mouse.x_rel, c.mouse.y_rel
}

is_down :: proc(key: sdl.Scancode) -> bool {
	return c.keys[key] in DOWN
}

just_pressed :: proc(key: sdl.Scancode) -> bool {
	return c.keys[key] == .JustPressed
}

hide_mouse :: proc() {
	_ = sdl.HideCursor()
}
