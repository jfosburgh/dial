package dial

import gfx "gfx/vk"
import vk "vendor:vulkan"


begin_drawing :: proc(win_ctx: ^WindowContext) {
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
	}

	frame := win_ctx.frames[win_ctx.frame_index % FRAMES_IN_FLIGHT]
	vk_check(vk.WaitForFences(e.vk_ctx.device, 1, &frame.fence, true, max(u64)))

	image_index: u32
	res := vk.AcquireNextImageKHR(
		e.vk_ctx.device,
		win_ctx.swapchain.handle,
		max(u64),
		frame.semaphore,
		{},
		&image_index,
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

	if prepare_frame(frame.buffer, win_ctx.swapchain.images[image_index]) {
		// do things
	}

	vk.ResetFences(e.vk_ctx.device, 1, &frame.fence)
	wait_stage_dest_mask: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
	submit_info: vk.SubmitInfo = {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &frame.semaphore,
		pWaitDstStageMask    = &wait_stage_dest_mask,
		commandBufferCount   = 1,
		pCommandBuffers      = &frame.buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &win_ctx.swapchain.semaphores[image_index],
	}
	vk_check(vk.QueueSubmit(e.vk_ctx.queue, 1, &submit_info, frame.fence))

	present_info: vk.PresentInfoKHR = {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &win_ctx.swapchain.semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = &win_ctx.swapchain.handle,
		pImageIndices      = &image_index,
	}

	res = vk.QueuePresentKHR(e.vk_ctx.queue, &present_info)
	#partial switch res {
	case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
		win_ctx.resize_requested = true
	case:
		vk_check(res)
	}
	win_ctx.frame_index += 1
}

@(deferred_in = end_frame)
prepare_frame :: proc(buf: vk.CommandBuffer, image: vk.Image) -> bool {
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

	return true
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
