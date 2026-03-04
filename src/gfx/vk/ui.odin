package gfx

import "core:log"
import clay "shared:clay-odin"
import vk "vendor:vulkan"


UiPrimitive :: enum u32 {
	Rect,
	Text,
}

UiData :: struct {
	rect:         [4]f32,
	uv:           [4]f32,
	color:        [4]f32,
	border_color: [4]f32,
	edge:         f32,
	border_edge:  f32,
	texture_id:   u32,
	primitive:    u32,
	softness:     f32,
	_pad:         [3]u32,
}

UiRect :: struct {
	bounding_box:  [4]f32,
	color:         [4]f32,
	corner_radius: [4]f32,
}

UiBorder :: struct {
	width: f32,
	color: [4]f32,
}

UiText :: struct {
	bounding_box: [4]f32,
	color:        [4]f32,
	uv:           [4]f32,
	texture_id:   u32,
}

UiPushConstant :: struct {
	ui_buffer_address: vk.DeviceAddress,
	screen_size:       [2]f32,
}

init_ui :: proc() {
	error_handler :: proc "c" (errorData: clay.ErrorData) {
		// Do something with the error data.
	}

	min_memory_size := clay.MinMemorySize()
	memory := make([^]u8, min_memory_size)
	arena: clay.Arena = clay.CreateArenaWithCapacityAndMemory(uint(min_memory_size), memory)
	clay.Initialize(arena, {1080, 720}, {handler = error_handler})

	// Example measure text function
	measure_text :: proc "c" (
		text: clay.StringSlice,
		config: ^clay.TextElementConfig,
		userData: rawptr,
	) -> clay.Dimensions {
		// clay.TextElementConfig contains members such as fontId, fontSize, letterSpacing, etc..
		// Note: clay.String->chars is not guaranteed to be null terminated
		return {width = f32(text.length * i32(config.fontSize)), height = f32(config.fontSize)}
	}

	// Tell clay how to measure text
	clay.SetMeasureTextFunction(measure_text, nil)
}

ui_begin :: proc() {
	clay.BeginLayout()
	clay.SetLayoutDimensions({f32(r.swapchain.extent.width), f32(r.swapchain.extent.height)})
}

ui_end :: proc() {
	commands := clay.EndLayout()
	i: i32
	for i < commands.length {
		command := clay.RenderCommandArray_Get(&commands, i)
		#partial switch command.commandType {
		case .Rectangle:
			draw_rect(
				rect = transmute([4]f32)command.boundingBox,
				color = transmute([4]f32)command.renderData.rectangle.backgroundColor,
				corner_radius = transmute([4]f32)command.renderData.rectangle.cornerRadius,
			)
		case .Border:
			draw_rect(
				rect = transmute([4]f32)command.boundingBox,
				color = {0, 0, 0, 0},
				corner_radius = transmute([4]f32)command.renderData.border.cornerRadius,
				border_width = f32(command.renderData.border.width.bottom),
				border_color = transmute([4]f32)command.renderData.border.color,
			)
		}

		i += 1
	}
}

basic_ui_window :: proc() {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(400)},
			padding = {left = 10, right = 10, top = 10, bottom = 10},
			childGap = 16,
		},
		backgroundColor = {0, 250, 0, 255},
		cornerRadius = {8, 8, 8, 8},
		border = {width = {left = 2, right = 2, top = 2, bottom = 2}, color = {200, 0, 255, 255}},
	},
	) {
	}
}

draw_text :: proc(
	text: string,
	pos: [2]f32,
	font: Font,
	font_size: f32,
	color: [4]f32,
	blur_radius: u8 = 0,
	border_width: u8 = 0,
	border_color: [4]f32 = {0, 0, 0, 0},
	shadow_offset: [2]u8 = {0, 0},
	shadow_color: [4]f32 = {0, 0, 0, 0.5},
	softness: f32 = 0,
	shadow_softness: f32 = 0,
) {
	texture_id, ok := get_texture_id(font.texture)
	if !ok do return

	scale := font_size / font.font_size

	current_x := pos.x
	current_y := pos.y + f32(font.ascent) * scale

	for char in text {
		if char == '\n' {
			current_x = pos.x
			current_y += font.font_size * scale
			continue
		}

		codepoint := i32(char)
		if codepoint < font.first_codepoint ||
		   codepoint >= font.first_codepoint + i32(len(font.chars)) {
			log.warnf("Character '%c' not in font atlas", char)
			continue
		}

		packed_char := font.chars[codepoint - font.first_codepoint]
		rect := [4]f32 {
			current_x + packed_char.xoff * scale,
			current_y + packed_char.yoff * scale,
			f32(packed_char.x1 - packed_char.x0) * scale,
			f32(packed_char.y1 - packed_char.y0) * scale,
		}

		uv := [4]f32 {
			f32(packed_char.x0) / font.atlas_size.x,
			f32(packed_char.y0) / font.atlas_size.y,
			f32(packed_char.x1) / font.atlas_size.x,
			f32(packed_char.y1) / font.atlas_size.y,
		}

		if shadow_offset != {0, 0} {
			offset: [2]f32 = {f32(shadow_offset.x), f32(shadow_offset.y)} * scale
			shadow_rect := rect
			shadow_rect.xy += offset

			append(
				&r.draw_info.ui_elements,
				UiData {
					rect = shadow_rect,
					uv = uv,
					color = shadow_color,
					border_color = {0, 0, 0, 0},
					texture_id = texture_id,
					primitive = u32(UiPrimitive.Text),
					edge = f32(font.edge) / f32(255),
					border_edge = (f32(font.edge) - f32(border_width) * font.pixel_dist_scale) /
					f32(255),
					softness = shadow_softness / font.pixel_dist_scale,
				},
			)
		}

		append(
			&r.draw_info.ui_elements,
			UiData {
				rect = rect,
				uv = uv,
				color = color,
				border_color = border_color,
				texture_id = texture_id,
				primitive = u32(UiPrimitive.Text),
				edge = f32(font.edge) / f32(255),
				border_edge = (f32(font.edge) - f32(border_width) * font.pixel_dist_scale) /
				f32(255),
				softness = softness / font.pixel_dist_scale,
			},
		)

		current_x += packed_char.xadvance * scale
	}
}

draw_rect :: proc(
	rect: [4]f32,
	color: [4]f32,
	corner_radius: [4]f32 = {0, 0, 0, 0},
	border_width: f32 = 0,
	border_color: [4]f32 = {0, 0, 0, 0},
	blur_radius: f32 = 0,
	shadow_offset: [2]f32 = {0, 0},
	shadow_color: [4]f32 = {0, 0, 0, 0.5},
	shadow_softness: f32 = 0,
) {
	if shadow_offset != {0, 0} || shadow_softness > 0 {
		shadow_rect := rect
		shadow_rect.xy += shadow_offset

		append(
			&r.draw_info.ui_elements,
			UiData {
				rect = shadow_rect,
				color = shadow_color,
				border_color = {0, 0, 0, 0},
				texture_id = 0,
				primitive = u32(UiPrimitive.Rect),
				edge = 0,
				border_edge = 0,
				uv = corner_radius,
				softness = shadow_softness,
			},
		)
	}

	append(
		&r.draw_info.ui_elements,
		UiData {
			rect = rect,
			color = color,
			border_color = border_color,
			texture_id = 0,
			primitive = u32(UiPrimitive.Rect),
			edge = border_width,
			border_edge = 0,
			uv = corner_radius,
		},
	)
}
