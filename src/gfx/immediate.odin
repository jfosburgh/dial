package gfx

import vk "vendor:vulkan"

@(private)
begin_immediate_submit :: proc(r: ^RenderContext) -> vk.CommandBuffer {
	vk_check(vk.ResetFences(r.device.device, 1, &r.immediate.fence))
	vk_check(vk.ResetCommandBuffer(r.immediate.cmd_buffer, {}))

	cmd := r.immediate.cmd_buffer
	cmd_begin_info: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))

	return cmd
}

@(private)
end_immediate_submit :: proc(r: ^RenderContext) {
	cmd := r.immediate.cmd_buffer
	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info: vk.CommandBufferSubmitInfo = {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	submit: vk.SubmitInfo2 = {
		sType                  = .SUBMIT_INFO_2,
		pCommandBufferInfos    = &cmd_info,
		commandBufferInfoCount = 1,
	}
	vk_check(vk.QueueSubmit2(r.graphics_queue.queue, 1, &submit, r.immediate.fence))
	vk_check(vk.WaitForFences(r.device.device, 1, &r.immediate.fence, true, max(u64)))
}

@(deferred_in = end_immediate_submit)
immediate_submit :: proc(r: ^RenderContext) -> (cmd: vk.CommandBuffer, ready: bool) {
	return begin_immediate_submit(r), true
}
