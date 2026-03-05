package gfx

import "core:log"
import vk "vendor:vulkan"

VkVersion :: enum {
	_1_0,
	_1_1,
	_1_2,
	_1_3,
	_1_4,
}

VkVersions: [VkVersion]u32 = {
	._1_0 = vk.API_VERSION_1_0,
	._1_1 = vk.API_VERSION_1_1,
	._1_2 = vk.API_VERSION_1_2,
	._1_3 = vk.API_VERSION_1_3,
	._1_4 = vk.API_VERSION_1_4,
}

InstanceBuilder :: struct {
	app_info:     vk.ApplicationInfo,
	extensions:   [dynamic]cstring,
	debug_levels: vk.DebugUtilsMessageSeverityFlagsEXT,
}

ib_init :: proc(b: ^InstanceBuilder, allocator := context.allocator, loc := #caller_location) {
	b.extensions = make([dynamic]cstring, allocator, loc)
}

ib_destroy :: proc(b: InstanceBuilder) {
	delete(b.extensions)
}

ib_set_vulkan_api_version :: proc(b: ^InstanceBuilder, version: VkVersion) {
	b.app_info.apiVersion = VkVersions[version]
}

ib_set_application_version :: proc(b: ^InstanceBuilder, major, minor, patch: u32) {
	b.app_info.applicationVersion = vk.MAKE_VERSION(major, minor, patch)
}

ib_set_application_name :: proc(b: ^InstanceBuilder, name: cstring) {
	b.app_info.pApplicationName = name
}

ib_set_engine_version :: proc(b: ^InstanceBuilder, major, minor, patch: u32) {
	b.app_info.engineVersion = vk.MAKE_VERSION(major, minor, patch)
}

ib_set_engine_name :: proc(b: ^InstanceBuilder, name: cstring) {
	b.app_info.pEngineName = name
}

ib_add_extensions :: proc(b: ^InstanceBuilder, extensions: ..cstring) {
	for extension in extensions {
		append(&b.extensions, extension)
	}
}

ib_add_debug_severity_levels :: proc(
	b: ^InstanceBuilder,
	levels: vk.DebugUtilsMessageSeverityFlagsEXT,
) {
	b.debug_levels |= levels
}

ib_build_instance :: proc(
	b: ^InstanceBuilder,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	instance: vk.Instance,
	debug_messenger: vk.DebugUtilsMessengerEXT,
	ok: bool,
) {
	create_info: vk.InstanceCreateInfo = {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &b.app_info,
	}

	debug_create_info: vk.DebugUtilsMessengerCreateInfoEXT
	if b.debug_levels != {} {
		create_info.ppEnabledLayerNames = raw_data([]cstring{"VK_LAYER_KHRONOS_validation"})
		create_info.enabledLayerCount = 1
		append(&b.extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		debug_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = b.debug_levels,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = vk_messenger_callback,
		}
		create_info.pNext = &debug_create_info
	}

	supported_extension_count: u32
	vk_check(vk.EnumerateInstanceExtensionProperties(nil, &supported_extension_count, nil))
	supported_extensions := make([]vk.ExtensionProperties, supported_extension_count, allocator)
	defer delete(supported_extensions)
	vk_check(
		vk.EnumerateInstanceExtensionProperties(
			nil,
			&supported_extension_count,
			raw_data(supported_extensions),
		),
	)

	for required_extension in b.extensions {
		found := false
		for &supported_extension in supported_extensions {
			if cstring(raw_data(supported_extension.extensionName[:])) == required_extension {
				found = true
				break
			}
		}

		if !found {
			log.fatalf("Required extension not found: %s", required_extension)
			return
		}
	}

	create_info.enabledExtensionCount = u32(len(b.extensions))
	create_info.ppEnabledExtensionNames = raw_data(b.extensions[:])

	vk_check(vk.CreateInstance(&create_info, nil, &instance))
	log.debug("Vulkan instance created")
	defer if !ok do vk.DestroyInstance(instance, nil)

	vk.load_proc_addresses_instance(instance)

	if b.debug_levels != {} {
		vk_check(
			vk.CreateDebugUtilsMessengerEXT(instance, &debug_create_info, nil, &debug_messenger),
		)
		log.debug("Vulkan debug messenger created")
	}

	ok = true
	return
}

// from Odin Vulkan example
// https://github.com/odin-lang/examples/blob/master/vulkan/triangle_glfw/main.odin
@(private)
vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = r.odin_ctx

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}
