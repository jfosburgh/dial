package gfx

import "core:log"
import vk "vendor:vulkan"


UiPrimitive :: enum u32 {
	Rect,
	Text,
}

UiData :: struct {
	rect:          [4]f32,
	uv:            [4]f32,
	color:         [4]f32,
	border_color:  [4]f32,
	edge:          f32,
	border_edge:   f32,
	texture_id:    u32,
	primitive:     u32,
	corner_radius: [4]f32,
	softness:      f32,
	_pad:          [3]u32,
}

UiPushConstant :: struct {
	ui_buffer_address: vk.DeviceAddress,
	screen_size:       [2]f32,
}

draw_text :: proc(
	text: string,
	pos: [2]f32,
	font: Font,
	color: [4]f32,
	blur_radius: u8 = 0,
	border_width: u8 = 0,
	border_color: [4]f32 = {0, 0, 0, 0},
	shadow_offset: [2]u8 = {0, 0},
	shadow_color: [4]f32 = {0, 0, 0, 0.5},
	softness: u8 = 0,
	shadow_softness: u8 = 0,
) {
	texture_id, ok := get_texture_id(font.texture)
	if !ok do return

	current_x := pos.x
	current_y := pos.y + f32(font.ascent)

	for char in text {
		if char == '\n' {
			current_x = pos.x
			current_y += font.font_size
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
			current_x + packed_char.xoff,
			current_y + packed_char.yoff,
			f32(packed_char.x1 - packed_char.x0),
			f32(packed_char.y1 - packed_char.y0),
		}

		uv := [4]f32 {
			f32(packed_char.x0) / font.atlas_size.x,
			f32(packed_char.y0) / font.atlas_size.y,
			f32(packed_char.x1) / font.atlas_size.x,
			f32(packed_char.y1) / font.atlas_size.y,
		}

		if shadow_offset != {0, 0} {
			offset: [2]f32 = {f32(shadow_offset.x), f32(shadow_offset.y)}
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
					softness = f32(shadow_softness) / font.pixel_dist_scale,
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
				softness = f32(softness) / font.pixel_dist_scale,
			},
		)

		current_x += packed_char.xadvance
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
	// if shadow_offset != {0, 0} {
	if true {
		shadow_rect := rect
		shadow_rect.xy += shadow_offset

		append(
			&r.draw_info.ui_elements,
			UiData {
				rect = shadow_rect,
				uv = {0, 0, 0, 0},
				color = shadow_color,
				border_color = {0, 0, 0, 0},
				texture_id = 0,
				primitive = u32(UiPrimitive.Rect),
				edge = 0,
				border_edge = 0,
				corner_radius = corner_radius,
				softness = shadow_softness,
			},
		)
	}

	append(
		&r.draw_info.ui_elements,
		UiData {
			rect = rect,
			uv = {0, 0, 0, 0},
			color = color,
			border_color = border_color,
			texture_id = 0,
			primitive = u32(UiPrimitive.Rect),
			edge = border_width,
			border_edge = 0,
			corner_radius = corner_radius,
		},
	)
}
