package gfx

import "core:log"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"


PhysicalDeviceBuilder :: struct {
	required_extensions:     [dynamic]cstring,
	required_queue_families: bit_set[QueueFamilies],
	anisotropy:              bool,
	surface:                 vk.SurfaceKHR,
	msaa_limit:              int,
}

pdb_init :: proc(b: ^PhysicalDeviceBuilder, allocator := context.allocator) {
	b.required_extensions = make([dynamic]cstring, allocator)
	b.msaa_limit = 8
}

pdb_destroy :: proc(b: PhysicalDeviceBuilder) {
	delete(b.required_extensions)
}

pdb_add_required_extensions :: proc(b: ^PhysicalDeviceBuilder, extensions: ..cstring) {
	for extension in extensions {
		append(&b.required_extensions, extension)
	}
}

pdb_enable_anisotropy :: proc(b: ^PhysicalDeviceBuilder, enabled: bool) {
	b.anisotropy = enabled
}

pdb_set_surface :: proc(b: ^PhysicalDeviceBuilder, surface: vk.SurfaceKHR) {
	b.surface = surface
}

pdb_remove_surface :: proc(b: ^PhysicalDeviceBuilder) {
	b.surface = {}
}

pdb_set_msaa_limit :: proc(b: ^PhysicalDeviceBuilder, limit: int) {
	b.msaa_limit = min(64, limit)
}

pdb_pick_physical_device :: proc(
	b: ^PhysicalDeviceBuilder,
	instance: vk.Instance,
	allocator := context.allocator,
) -> (
	PhysicalDeviceInfo,
	bool,
) {
	physical_device_count: u32
	vk_check(vk.EnumeratePhysicalDevices(instance, &physical_device_count, nil))
	if physical_device_count == 0 {
		log.fatalf("Failed to find a device that supports Vulkan")
		return {}, false
	}

	devices := make([]vk.PhysicalDevice, physical_device_count, allocator)
	defer delete(devices)
	vk_check(vk.EnumeratePhysicalDevices(instance, &physical_device_count, raw_data(devices)))

	info: PhysicalDeviceInfo
	best_score := -1
	for device, i in devices {
		next_info := get_physical_device_info(
			device,
			b.surface,
			b.msaa_limit,
			allocator,
		) or_continue
		score_physical_device(b, &next_info, allocator)

		if next_info.score > best_score {
			destroy_physical_device_info(info)
			info = next_info
		} else {
			destroy_physical_device_info(next_info)
		}
	}

	if info.device == nil {
		log.error("no suitable devices found")
		return {}, false
	}

	return info, true
}

QueueFamilies :: enum {
	Compute,
	Graphics,
	Present,
	Transfer,
}

QueueFamilyIndices :: [QueueFamilies]Maybe(u32)

PhysicalDeviceInfo :: struct {
	name:                    string,
	device:                  vk.PhysicalDevice,
	score:                   int,
	properties:              vk.PhysicalDeviceProperties,
	features:                vk.PhysicalDeviceFeatures,
	queue_families:          QueueFamilyIndices,
	queue_family_properties: []vk.QueueFamilyProperties,
	extensions:              []vk.ExtensionProperties,
	swapchain_support:       SwapchainSupport,
	msaa_samples:            vk.SampleCountFlag,
}

destroy_physical_device_info :: proc(info: PhysicalDeviceInfo) {
	delete(info.name)
	delete(info.queue_family_properties)
	delete(info.extensions)
	delete(info.swapchain_support.formats)
	delete(info.swapchain_support.present_modes)
}

score_physical_device :: proc(
	b: ^PhysicalDeviceBuilder,
	device_info: ^PhysicalDeviceInfo,
	allocator := context.allocator,
) {
	if b.anisotropy && !device_info.features.samplerAnisotropy {
		log.debugf("device %s does not support sampler anisotropy: %s", device_info.name)
		return
	}

	required_loop: for required in b.required_extensions {
		for &extension in device_info.extensions {
			if cstring(raw_data(extension.extensionName[:])) == required do continue required_loop
		}

		log.debugf("device %s does not support extension: %s", device_info.name, required)
		return
	}

	if b.surface != {} {
		if len(device_info.swapchain_support.formats) == 0 ||
		   len(device_info.swapchain_support.present_modes) == 0 {
			log.debugf("device %s does not support swapchain", device_info.name)
			return
		}
	}

	has_queue_family :: proc(requested: QueueFamilies, found: Maybe(u32)) -> (was_found: bool) {
		defer if !was_found {
			log.debugf("device does not have required family: %v", requested)
		}
		_, was_found = found.?
		return
	}

	for family in b.required_queue_families {
		if !has_queue_family(family, device_info.queue_families[family]) do return
	}

	switch device_info.properties.deviceType {
	case .DISCRETE_GPU:
		device_info.score += 300_000
	case .INTEGRATED_GPU:
		device_info.score += 200_000
	case .VIRTUAL_GPU:
		device_info.score += 100_000
	case .CPU, .OTHER:
	}

	device_info.score += int(device_info.properties.limits.maxImageDimension2D)
	log.debugf("Device %s - score: %i", device_info.name, device_info.score)

	return
}

@(private)
get_max_usable_sample_count :: proc(info: PhysicalDeviceInfo, limit: int) -> vk.SampleCountFlag {
	counts := info.properties.limits.framebufferColorSampleCounts

	if ._64 in counts && 64 <= limit {
		return ._64
	} else if ._32 in counts && 32 <= limit {
		return ._32
	} else if ._16 in counts && 16 <= limit {
		return ._16
	} else if ._8 in counts && 8 <= limit {
		return ._8
	} else if ._4 in counts && 4 <= limit {
		return ._4
	} else if ._2 in counts && 2 <= limit {
		return ._2
	}

	return ._1
}

get_physical_device_info :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR = {},
	msaa_limit: int,
	allocator := context.allocator,
) -> (
	info: PhysicalDeviceInfo,
	ok: bool,
) {
	info.device = device

	vk.GetPhysicalDeviceProperties(device, &info.properties)
	info.name = strings.clone_from_cstring(cstring(raw_data(info.properties.deviceName[:])))

	features: vk.PhysicalDeviceFeatures
	vk.GetPhysicalDeviceFeatures(device, &info.features)

	device_ext_count: u32
	if vk.EnumerateDeviceExtensionProperties(device, nil, &device_ext_count, nil) != .SUCCESS {
		log.errorf("Failed to get physical device extensions")
		return info, false
	}

	info.extensions = make([]vk.ExtensionProperties, device_ext_count, allocator)
	vk.EnumerateDeviceExtensionProperties(
		device,
		nil,
		&device_ext_count,
		raw_data(info.extensions),
	)

	queue_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_count, nil)

	info.queue_family_properties = make([]vk.QueueFamilyProperties, queue_count, allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_count,
		raw_data(info.queue_family_properties),
	)

	loop: for family, i in info.queue_family_properties {
		if .COMPUTE in family.queueFlags &&
		   .GRAPHICS in family.queueFlags &&
		   .TRANSFER in family.queueFlags {
			present_supported: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), r.surface, &present_supported)
			if present_supported {
				index := u32(i)
				info.queue_families = {
					.Compute  = index,
					.Graphics = index,
					.Present  = index,
					.Transfer = index,
				}
				break loop
			}
		}

		// if _, ok := indices.compute.?; !ok && .COMPUTE in family.queueFlags {
		// 	indices.compute = u32(i)
		// }
		// if _, ok := indices.graphics.?; !ok && .GRAPHICS in family.queueFlags {
		// 	indices.graphics = u32(i)
		// }
		// if _, ok := indices.transfer.?; !ok && .TRANSFER in family.queueFlags {
		// 	indices.transfer = u32(i)
		// }
		//
		// if _, ok := indices.present.?; !ok {
		// 	present_supported: b32
		// 	vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), r.surface, &present_supported)
		//
		// 	if present_supported do indices.present = u32(i)
		// }
		//
		// _, has_compute := indices.compute.?
		// _, has_graphics := indices.graphics.?
		// _, has_transfer := indices.transfer.?
		// _, has_present := indices.present.?
		//
		// if has_compute && has_graphics && has_transfer && has_present {
		// 	ok = true
		// 	break
		// }
	}

	if surface != {} {
		if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			   device,
			   surface,
			   &info.swapchain_support.capabilities,
		   ) !=
		   .SUCCESS {
			log.errorf("failed to retrieve swapchain capabilities for device %s", info.name)
			return info, false
		}

		{
			count: u32
			if vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, nil) != .SUCCESS {
				log.errorf("failed to retrieve surface formats for device %s", info.name)
				return info, false
			}

			info.swapchain_support.formats = make([]vk.SurfaceFormatKHR, count, r.allocators.cpu)
			vk.GetPhysicalDeviceSurfaceFormatsKHR(
				device,
				surface,
				&count,
				raw_data(info.swapchain_support.formats),
			)
		}

		{
			count: u32
			if vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, nil) !=
			   .SUCCESS {
				log.errorf("failed to retrieve surface present modes for device %s", info.name)
				return info, false
			}

			info.swapchain_support.present_modes = make(
				[]vk.PresentModeKHR,
				count,
				r.allocators.cpu,
			)
			vk.GetPhysicalDeviceSurfacePresentModesKHR(
				device,
				surface,
				&count,
				raw_data(info.swapchain_support.present_modes),
			)
		}
	}

	info.msaa_samples = get_max_usable_sample_count(info, msaa_limit)
	ok = true

	return
}

LogicalDeviceBuilder :: struct {
	device_features:        vk.PhysicalDeviceFeatures,
	features_1_1:           vk.PhysicalDeviceVulkan11Features,
	features_1_2:           vk.PhysicalDeviceVulkan12Features,
	features_1_3:           vk.PhysicalDeviceVulkan13Features,
	features_1_4:           vk.PhysicalDeviceVulkan14Features,
	extensions:             [dynamic]cstring,
	device_queues:          [dynamic]QueueInfo,
	extended_dynamic_state: bool,
}

QueueInfo :: struct {
	index:      u32,
	count:      u32,
	priorities: []f32,
}

ldb_init :: proc(b: ^LogicalDeviceBuilder, allocator := context.allocator) {
	b.features_1_1.sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
	b.features_1_2.sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
	b.features_1_3.sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
	b.features_1_4.sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES

	b.features_1_1.pNext = &b.features_1_2
	b.features_1_2.pNext = &b.features_1_3
	b.features_1_3.pNext = &b.features_1_4

	b.extensions = make([dynamic]cstring, allocator)
	b.device_queues = make([dynamic]QueueInfo, allocator)
}

ldb_destroy :: proc(b: LogicalDeviceBuilder) {
	delete(b.extensions)
	for queue in b.device_queues do delete(queue.priorities)
	delete(b.device_queues)
}

ldb_set_extended_dynamic_state_enabled :: proc(b: ^LogicalDeviceBuilder, enabled: bool) {
	b.extended_dynamic_state = enabled
}

ldb_set_msaa_enabled :: proc(b: ^LogicalDeviceBuilder, enabled: bool) {
	b.device_features.samplerAnisotropy = b32(enabled)
	b.device_features.sampleRateShading = b32(enabled)
}

ldb_set_multi_draw_indirect_enabled :: proc(b: ^LogicalDeviceBuilder, enabled: bool) {
	b.device_features.multiDrawIndirect = b32(enabled)
	b.features_1_1.shaderDrawParameters = b32(enabled)
}

ldb_set_shader_ints_enabled :: proc(b: ^LogicalDeviceBuilder, int_16: bool, int_64: bool) {
	b.device_features.shaderInt16 = b32(int_16)
	b.device_features.shaderInt64 = b32(int_64)
}

ldb_set_dynamic_rendering_enabled :: proc(b: ^LogicalDeviceBuilder, enabled: bool) {
	b.features_1_3.dynamicRendering = b32(enabled)
	b.features_1_3.synchronization2 = b32(enabled)
}

ldb_set_bindless_enabled :: proc(b: ^LogicalDeviceBuilder, enabled: bool) {
	b.features_1_2.bufferDeviceAddress = b32(enabled)
	b.features_1_2.descriptorIndexing = b32(enabled)
	b.features_1_2.runtimeDescriptorArray = b32(enabled)
	b.features_1_2.descriptorBindingPartiallyBound = b32(enabled)
	b.features_1_2.shaderSampledImageArrayNonUniformIndexing = b32(enabled)
	b.features_1_2.descriptorBindingSampledImageUpdateAfterBind = b32(enabled)
}

ldb_add_extensions :: proc(b: ^LogicalDeviceBuilder, extensions: ..cstring) {
	for extension in extensions {
		append(&b.extensions, extension)
	}
}

ldb_clear_extensions :: proc(b: ^LogicalDeviceBuilder) {
	clear(&b.extensions)
}

ldb_add_device_queue :: proc(
	b: ^LogicalDeviceBuilder,
	queue_index: u32,
	count: u32,
	priorities: []f32,
) -> bool {
	if len(priorities) != int(count) {
		log.errorf(
			"# queue priorities (%d) does not match queue count (%d)",
			len(priorities),
			count,
		)
		return false
	}

	append(
		&b.device_queues,
		QueueInfo{index = queue_index, count = count, priorities = slice.clone(priorities)},
	)
	return true
}

ldb_build_logical_device :: proc(
	b: ^LogicalDeviceBuilder,
	physical_device: vk.PhysicalDevice,
	device: ^vk.Device,
	allocator := context.allocator,
) {
	extended_dynamic_features: vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT
	if b.extended_dynamic_state {
		extended_dynamic_features.sType = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT
		extended_dynamic_features.extendedDynamicState = true
		b.features_1_4.pNext = &extended_dynamic_features
	}

	queue_info := make([]vk.DeviceQueueCreateInfo, len(b.device_queues))
	defer delete(queue_info)
	for queue, i in b.device_queues {
		queue_info[i].sType = .DEVICE_QUEUE_CREATE_INFO
		queue_info[i].queueCount = queue.count
		queue_info[i].pQueuePriorities = raw_data(queue.priorities)
		queue_info[i].queueFamilyIndex = queue.index
	}

	device_create_info: vk.DeviceCreateInfo = {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &b.features_1_1,
		pEnabledFeatures        = &b.device_features,
		enabledExtensionCount   = u32(len(b.extensions)),
		ppEnabledExtensionNames = raw_data(b.extensions[:]),
		queueCreateInfoCount    = u32(len(queue_info)),
		pQueueCreateInfos       = raw_data(queue_info),
	}

	vk_check(vk.CreateDevice(physical_device, &device_create_info, nil, device))
	vk.load_proc_addresses_device(device^)

	return
}
