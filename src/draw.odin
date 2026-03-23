package dial

import "deps/no_gfx_api/gpu"
import sdl "vendor:sdl3"

@(private)
to_delta :: #force_inline proc(last, now, freq: u64) -> f32 {
	return f32(f64((now - last) * 1000) / f64(freq)) / 1000
}

@(deferred_out = frame_submit)
frame_prepare :: proc(
) -> (
	swapchain: gpu.Texture,
	arena: ^gpu.Arena,
	buf: gpu.Command_Buffer,
	ok: bool,
) {
	width, height: i32
	sdl.GetWindowSize(e.window.handle, &width, &height)
	e.window.resize_requested = width != e.window.size.x || height != e.window.size.y
	e.window.size = {width, height}

	if e.window.size.x == 0 ||
	   e.window.size.y == 0 ||
	   .MINIMIZED in sdl.GetWindowFlags(e.window.handle) {
		sdl.Delay(16)
		return
	}

	if e.window.resize_requested do gpu.swapchain_resize({u32(e.window.size.x), u32(e.window.size.y)})

	if e.window.next_frame > FRAMES_IN_FLIGHT do gpu.semaphore_wait(e.window.frame_sem, e.window.next_frame - FRAMES_IN_FLIGHT)

	swapchain = gpu.swapchain_acquire_next()
	arena = &e.window.arenas[e.window.next_frame % FRAMES_IN_FLIGHT]
	buf = gpu.commands_begin(.Main)
	ok = true

	ts_last := e.ts_now
	e.ts_now = sdl.GetPerformanceCounter()
	e.delta = to_delta(ts_last, e.ts_now, e.ts_freq)

	return
}

frame_submit :: proc(_: gpu.Texture, arena: ^gpu.Arena, buf: gpu.Command_Buffer, _: bool) {
	gpu.cmd_add_signal_semaphore(buf, e.window.frame_sem, e.window.next_frame)
	gpu.queue_submit(.Main, {buf})
	gpu.swapchain_present(.Main, e.window.frame_sem, e.window.next_frame)
	gpu.arena_free_all(arena)
	e.window.next_frame += 1
	free_all(e.odin_ctx.temp_allocator)
}

@(deferred_in = end_rendering)
begin_rendering :: proc(buf: gpu.Command_Buffer, description: gpu.Render_Pass_Desc) -> bool {
	gpu.cmd_begin_render_pass(buf, description)

	return true
}

end_rendering :: proc(buf: gpu.Command_Buffer, _: gpu.Render_Pass_Desc) {
	gpu.cmd_end_render_pass(buf)
}

RenderTargetBuilder :: struct {
	color_attachment: gpu.Render_Attachment,
	depth_attachment: gpu.Render_Attachment,
}

rtb_set_color_target :: proc(
	b: ^RenderTargetBuilder,
	texture: gpu.Texture,
	clear_color: [4]f32,
	view: gpu.Texture_View_Desc = {},
	load_op: gpu.Load_Op = {},
	store_op: gpu.Store_Op = {},
) {
	b.color_attachment.texture = texture
	b.color_attachment.clear_color = clear_color
	b.color_attachment.view = view
	b.color_attachment.load_op = load_op
	b.color_attachment.store_op = store_op
}

rtb_build_render_pass_desc :: proc(
	b: ^RenderTargetBuilder,
	allocator := e.odin_ctx.temp_allocator,
) -> (
	d: gpu.Render_Pass_Desc,
) {
	d.color_attachments = make([]gpu.Render_Attachment, 1, allocator)
	d.color_attachments[0] = b.color_attachment

	if b.depth_attachment != {} {
		d.depth_attachment = b.depth_attachment
	}

	return
}

rtb_clear :: proc(b: ^RenderTargetBuilder) {
	b^ = {}
}
