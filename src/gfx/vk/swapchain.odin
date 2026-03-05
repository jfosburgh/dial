package gfx

import "core:log"
import vma "shared:vma"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

Swapchain :: struct {
	handle:     vk.SwapchainKHR,
	format:     vk.Format,
	extent:     vk.Extent2D,
	images:     []vk.Image,
	views:      []vk.ImageView,
	semaphores: []vk.Semaphore,
}

SwapchainSupport :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

create_swapchain :: proc(
	device: vk.Device,
	window: ^sdl.Window,
	surface: vk.SurfaceKHR,
	swapchain_support: SwapchainSupport,
	swapchain: ^Swapchain,
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	format := choose_swapchain_surface_format(swapchain_support.formats)
	present_mode := choose_swapchain_present_mode(swapchain_support.present_modes)
	extent := choose_swapchain_extent(window, swapchain_support.capabilities)
	if extent.width == 0 || extent.height == 0 do return

	image_count := swapchain_support.capabilities.minImageCount + 1
	max_imgs := swapchain_support.capabilities.maxImageCount
	if max_imgs > 0 && image_count > max_imgs {
		image_count = max_imgs
	}

	swapchain_create_info: vk.SwapchainCreateInfoKHR = {
		sType                 = .SWAPCHAIN_CREATE_INFO_KHR,
		surface               = surface,
		presentMode           = present_mode,
		imageExtent           = extent,
		imageFormat           = format.format,
		imageColorSpace       = format.colorSpace,
		minImageCount         = image_count,
		imageArrayLayers      = 1,
		imageUsage            = {.COLOR_ATTACHMENT}, // TODO: change to TRANSFER if using separate render target
		imageSharingMode      = .EXCLUSIVE,
		queueFamilyIndexCount = 1,
		// pQueueFamilyIndices = &r.graphics_index,
		preTransform          = swapchain_support.capabilities.currentTransform,
		compositeAlpha        = {.OPAQUE},
		clipped               = true,
	}

	indices: [2]u32 = {r.graphics_index, r.present_index}
	if r.graphics_index != r.present_index {
		swapchain_create_info.imageSharingMode = .CONCURRENT
		swapchain_create_info.queueFamilyIndexCount = 2
		swapchain_create_info.pQueueFamilyIndices = raw_data(indices[:])
	}

	vk_check(vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain.handle))
	defer if !ok do vk.DestroySwapchainKHR(device, swapchain.handle, nil)

	vk_check(vk.GetSwapchainImagesKHR(device, swapchain.handle, &image_count, nil))
	swapchain.images = make([]vk.Image, image_count, allocator)
	vk_check(
		vk.GetSwapchainImagesKHR(
			device,
			swapchain.handle,
			&image_count,
			raw_data(swapchain.images),
		),
	)

	swapchain.extent = extent
	swapchain.format = format.format

	return true
}

@(private)
choose_swapchain_surface_format :: proc(
	supported_formats: []vk.SurfaceFormatKHR,
) -> vk.SurfaceFormatKHR {
	for format in supported_formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR do return format
	}
	return supported_formats[0]
}

@(private)
choose_swapchain_present_mode :: proc(present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for mode in present_modes {
		if mode == .MAILBOX do return mode
	}
	return .FIFO
}

@(private)
choose_swapchain_extent :: proc(
	window: ^sdl.Window,
	capabilities: vk.SurfaceCapabilitiesKHR,
) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) do return capabilities.currentExtent

	width, height: i32
	if !sdl.GetWindowSize(window, &width, &height) {
		log_sdl()
		return {}
	}

	return {
		clamp(u32(width), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
		clamp(u32(height), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
	}
}

destroy_swapchain :: proc(device: vk.Device, swapchain: Swapchain) {
	delete(swapchain.images)
	vk.DestroySwapchainKHR(device, swapchain.handle, nil)
}

create_swapchain_data :: proc(
	device: vk.Device,
	swapchain: ^Swapchain,
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	image_view_create_info: vk.ImageViewCreateInfo = {
		sType = .IMAGE_VIEW_CREATE_INFO,
		format = swapchain.format,
		viewType = .D2,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseArrayLayer = 0,
			baseMipLevel = 0,
			layerCount = 1,
			levelCount = 1,
		},
		components = {a = .IDENTITY, b = .IDENTITY, g = .IDENTITY, r = .IDENTITY},
	}

	swapchain.views = make([]vk.ImageView, len(swapchain.images), allocator)
	swapchain.semaphores = make([]vk.Semaphore, len(swapchain.images), allocator)
	for i in 0 ..< len(swapchain.images) {
		image_view_create_info.image = swapchain.images[i]
		vk_check(vk.CreateImageView(device, &image_view_create_info, nil, &swapchain.views[i]))
		vk_check(
			vk.CreateSemaphore(
				device,
				&vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO},
				nil,
				&swapchain.semaphores[i],
			),
		)
	}

	return true
}

destroy_swapchain_data :: proc(device: vk.Device, swapchain: Swapchain) {
	for view in swapchain.views {
		vk.DestroyImageView(device, view, nil)
	}
	for semaphore in swapchain.semaphores {
		vk.DestroySemaphore(device, semaphore, nil)
	}
	delete(swapchain.views)
	delete(swapchain.semaphores)
}

recreate_swapchain :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	window: ^sdl.Window,
	swapchain_support: SwapchainSupport,
	swapchain: ^Swapchain,
	render_target: ^RenderTarget,
	gpu_allocator: vma.Allocator,
	allocator := context.allocator,
) {
	width, height: i32
	sdl.GetWindowSize(window, &width, &height)
	if width == 0 || height == 0 {
		log.debug("window minimized, waiting")
	}

	for width == 0 || height == 0 {
		sdl.GetWindowSize(r.window, &width, &height)
		for sdl.WaitEvent(nil) {}
	}

	log.debugf("resizing swapchain to %dx%d", width, height)
	vk_check(vk.DeviceWaitIdle(device))

	destroy_depth_resources(device, render_target^, gpu_allocator)
	destroy_color_resources(device, render_target^, gpu_allocator)
	destroy_swapchain_data(device, swapchain^)
	destroy_swapchain(device, swapchain^)

	create_swapchain(device, window, surface, swapchain_support, swapchain, allocator)
	create_swapchain_data(device, swapchain, allocator)
	create_color_resources(device, render_target, swapchain^, gpu_allocator)
	create_depth_resources(device, physical_device, render_target, swapchain^, gpu_allocator)
}

create_render_target :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	render_target: ^RenderTarget,
	swapchain: Swapchain,
	allocator: vma.Allocator,
) -> (
	ok: bool,
) {
	create_color_resources(device, render_target, swapchain, allocator) or_return
	defer if !ok do destroy_color_resources(device, render_target^, allocator)

	create_depth_resources(device, physical_device, render_target, swapchain, allocator) or_return
	defer if !ok do destroy_color_resources(device, render_target^, allocator)

	return true
}

destroy_render_target :: proc(
	device: vk.Device,
	render_target: RenderTarget,
	allocator: vma.Allocator,
) {
	destroy_depth_resources(device, render_target, allocator)
	destroy_color_resources(device, render_target, allocator)
}

create_color_resources :: proc(
	device: vk.Device,
	render_target: ^RenderTarget,
	swapchain: Swapchain,
	allocator: vma.Allocator,
) -> (
	ok: bool,
) {
	render_target.color_format = swapchain.format
	create_image(
		device,
		&render_target.color,
		swapchain.extent.width,
		swapchain.extent.height,
		0,
		render_target.color_format,
		{.TRANSIENT_ATTACHMENT, .COLOR_ATTACHMENT},
		allocator,
		1,
		render_target.msaa_samples,
	)

	return true
}

destroy_color_resources :: proc(
	device: vk.Device,
	render_target: RenderTarget,
	allocator: vma.Allocator,
) {
	vk.DestroyImageView(device, render_target.color.view, nil)
	vma.destroy_image(allocator, render_target.color.image, render_target.color.allocation)
}

create_depth_resources :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	render_target: ^RenderTarget,
	swapchain: Swapchain,
	allocator: vma.Allocator,
) -> (
	ok: bool,
) {
	r.render_target.depth_format = find_depth_format(physical_device)
	create_image(
		device,
		&render_target.depth,
		swapchain.extent.width,
		swapchain.extent.height,
		0,
		render_target.depth_format,
		{.DEPTH_STENCIL_ATTACHMENT},
		allocator,
		1,
		render_target.msaa_samples,
	)

	return true
}

destroy_depth_resources :: proc(
	device: vk.Device,
	render_target: RenderTarget,
	allocator: vma.Allocator,
) {
	vk.DestroyImageView(device, render_target.depth.view, nil)
	vma.destroy_image(allocator, render_target.depth.image, render_target.depth.allocation)
}

@(private)
find_depth_format :: proc(physical_device: vk.PhysicalDevice) -> vk.Format {
	return find_supported_formats(
		physical_device,
		{.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT},
		.OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT},
	)
}

@(private)
find_supported_formats :: proc(
	physical_device: vk.PhysicalDevice,
	candidates: []vk.Format,
	tiling: vk.ImageTiling,
	features: vk.FormatFeatureFlags,
) -> vk.Format {
	for format in candidates {
		props: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(physical_device, format, &props)

		if tiling == .LINEAR && props.linearTilingFeatures & features == features do return format
		if tiling == .OPTIMAL && props.optimalTilingFeatures & features == features do return format
	}

	unreachable()
}

@(private)
get_swapchain_support :: proc(
	device: vk.PhysicalDevice,
	device_name: string,
	surface: vk.SurfaceKHR,
	swapchain_support: ^SwapchainSupport,
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
		   device,
		   surface,
		   &swapchain_support.capabilities,
	   ) !=
	   .SUCCESS {
		log.errorf("failed to retrieve swapchain capabilities for device %s", device_name)
		return
	}

	{
		count: u32
		if vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, nil) != .SUCCESS {
			log.errorf("failed to retrieve surface formats for device %s", device_name)
			return
		}

		swapchain_support.formats = make([]vk.SurfaceFormatKHR, count, allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			device,
			surface,
			&count,
			raw_data(swapchain_support.formats),
		)
	}

	{
		count: u32
		if vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, nil) != .SUCCESS {
			log.errorf("failed to retrieve surface present modes for device %s", device_name)
			return
		}

		swapchain_support.present_modes = make([]vk.PresentModeKHR, count, allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			surface,
			&count,
			raw_data(swapchain_support.present_modes),
		)
	}

	return true
}
