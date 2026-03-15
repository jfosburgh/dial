package dial

import "core:log"
import gfx "gfx/vk"
import vk "vendor:vulkan"


@(deferred_in = end_drawing)
begin_drawing :: proc(win_ctx: ^WindowContext) -> (buf: vk.CommandBuffer, ok: bool) {
	if win_ctx.resize_requested {
		gfx.recreate_swapchain(
			e.vk_ctx.device,
			e.vk_ctx.physical_device_info.device,
			win_ctx.surface,
			win_ctx.window,
			e.vk_ctx.physical_device_info.swapchain_support,
			&win_ctx.swapchain,
			&win_ctx.render_target,
			e.vk_ctx.allocator,
			e.odin_ctx.allocator,
		)
		win_ctx.resize_requested = false
	}

	frame := &win_ctx.frames[win_ctx.frame_index % FRAMES_IN_FLIGHT]
	vk_check(vk.WaitForFences(e.vk_ctx.device, 1, &frame.fence, true, max(u64)))

	res := vk.AcquireNextImageKHR(
		e.vk_ctx.device,
		win_ctx.swapchain.handle,
		max(u64),
		frame.semaphore,
		{},
		&win_ctx.swapchain_image_index,
	)
	#partial switch res {
	case .ERROR_OUT_OF_DATE_KHR:
		win_ctx.resize_requested = true
		return
	case .SUBOPTIMAL_KHR:
		win_ctx.resize_requested = true
	case:
		vk_check(res)
	}

	prepare_frame(frame.buffer, win_ctx.swapchain.images[win_ctx.swapchain_image_index])
	return frame.buffer, true
}

end_drawing :: proc(win_ctx: ^WindowContext) {
	frame := &win_ctx.frames[win_ctx.frame_index % FRAMES_IN_FLIGHT]
	end_frame(frame.buffer, win_ctx.swapchain.images[win_ctx.swapchain_image_index])
	vk_check(vk.ResetFences(e.vk_ctx.device, 1, &frame.fence))
	wait_stage_dest_mask: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
	submit_info: vk.SubmitInfo = {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &frame.semaphore,
		pWaitDstStageMask    = &wait_stage_dest_mask,
		commandBufferCount   = 1,
		pCommandBuffers      = &frame.buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &win_ctx.swapchain.semaphores[win_ctx.swapchain_image_index],
	}
	vk_check(vk.QueueSubmit(e.vk_ctx.queue, 1, &submit_info, frame.fence))

	present_info: vk.PresentInfoKHR = {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &win_ctx.swapchain.semaphores[win_ctx.swapchain_image_index],
		swapchainCount     = 1,
		pSwapchains        = &win_ctx.swapchain.handle,
		pImageIndices      = &win_ctx.swapchain_image_index,
	}

	res := vk.QueuePresentKHR(e.vk_ctx.queue, &present_info)
	#partial switch res {
	case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
		win_ctx.resize_requested = true
	case:
		vk_check(res)
	}
	win_ctx.frame_index += 1
}

prepare_frame :: proc(buf: vk.CommandBuffer, image: vk.Image) {
	vk.BeginCommandBuffer(buf, &vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO})
	gfx.transition_image(
		buf,
		image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
	)
}

end_frame :: proc(buf: vk.CommandBuffer, image: vk.Image) {
	gfx.transition_image(
		buf,
		image,
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_WRITE},
		{},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.BOTTOM_OF_PIPE},
	)
	vk_check(vk.EndCommandBuffer(buf))
}

@(deferred_in = end_rendering)
begin_rendering :: proc(
	buf: vk.CommandBuffer,
	color_target: gfx.AllocatedImage,
	depth_target: Maybe(gfx.AllocatedImage),
	resolve: Maybe(vk.ImageView),
) -> bool {
	gfx.transition_image(
		buf,
		color_target.image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
	)

	depth, has_depth := depth_target.?
	if has_depth {
		depth_aspect: vk.ImageAspectFlags = {.DEPTH}
		if gfx.has_stencil_component(depth.format) {
			depth_aspect |= {.STENCIL}
		}
		gfx.transition_image(
			buf,
			depth.image,
			.UNDEFINED,
			.DEPTH_ATTACHMENT_OPTIMAL,
			{.DEPTH_STENCIL_ATTACHMENT_WRITE},
			{.DEPTH_STENCIL_ATTACHMENT_WRITE},
			{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			depth_aspect,
		)
	}

	// TODO: configurable clear
	clear_color: vk.ClearValue = {
		color = {float32 = {1, 1, 1, 1}},
	}
	clear_depth: vk.ClearValue = {
		depthStencil = {depth = 1, stencil = 0},
	}
	resolve_mode: vk.ResolveModeFlags =
		{.SAMPLE_ZERO} if ._1 in color_target.samples else {.AVERAGE}
	color_attachment_info: vk.RenderingAttachmentInfo = {
		sType       = .RENDERING_ATTACHMENT_INFO,
		clearValue  = clear_color,
		resolveMode = resolve_mode,
		imageView   = color_target.view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
	}
	if resolve_view, ok := resolve.?; ok {
		color_attachment_info.resolveImageView = resolve_view
		color_attachment_info.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
	}

	depth_attachment_info: vk.RenderingAttachmentInfo = {
		sType = .RENDERING_ATTACHMENT_INFO,
	}
	if has_depth {
		depth_attachment_info.clearValue = clear_depth
		depth_attachment_info.imageView = depth.view
		depth_attachment_info.imageLayout = .DEPTH_ATTACHMENT_OPTIMAL
		depth_attachment_info.loadOp = .CLEAR
		depth_attachment_info.storeOp = .DONT_CARE
	}

	// TODO: configurable renderArea/Viewport/Scissor
	rendering_info: vk.RenderingInfo = {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = {color_target.extent.x, color_target.extent.y}},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_info,
		pDepthAttachment = &depth_attachment_info,
	}

	viewport: vk.Viewport = {
		width    = f32(color_target.extent.x),
		height   = f32(color_target.extent.y),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(buf, 0, 1, &viewport)

	scissor: vk.Rect2D = {
		extent = {color_target.extent.x, color_target.extent.y},
		offset = {0, 0},
	}
	vk.CmdSetScissor(buf, 0, 1, &scissor)

	vk.CmdBeginRendering(buf, &rendering_info)
	return true
}

end_rendering :: proc(
	buf: vk.CommandBuffer,
	_: gfx.AllocatedImage,
	_: Maybe(gfx.AllocatedImage),
	_: Maybe(vk.ImageView),
) {
	vk.CmdEndRendering(buf)
}
