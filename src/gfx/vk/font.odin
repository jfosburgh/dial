package gfx

import "core:log"
import "core:os"
import stbi "vendor:stb/image"
import ttf "vendor:stb/truetype"


Font :: struct {
	texture:                   Handle,
	chars:                     []ttf.packedchar,
	scale:                     f32,
	font_size:                 f32,
	first_codepoint:           i32,
	atlas_size:                [2]f32,
	pixel_dist_scale:          f32,
	edge:                      u8,
	ascent, descent, line_gap: f32,
}

load_font :: proc(filepath: string, font_size: f32) -> (font_out: Font, ok: bool) {
	font := new(ttf.fontinfo)
	defer free(font)
	font_data, _ := os.read_entire_file(FONT_PATH)
	if !ttf.InitFont(font, raw_data(font_data), 0) {
		log.fatalf("failed initializing font from %s", FONT_PATH)
	}

	atlas_width, atlas_height := i32(1024), i32(1024)
	bitmap := make([]u8, 1024 * 1024)
	defer delete(bitmap)

	first_codepoint: i32 = 32
	n_chars: i32 = 95
	packed_chars := make([]ttf.packedchar, n_chars)

	ctx: ttf.pack_context
	if ttf.PackBegin(&ctx, raw_data(bitmap), atlas_width, atlas_height, 0, 1, nil) == 0 {
		log.fatal("failed to initialize packing context")
	}
	ttf.PackSetOversampling(&ctx, 1, 1)

	padding: i32 = 5
	onedge: u8 = 180
	pixel_dist_scale: f32 = f32(onedge) / 5

	scale := ttf.ScaleForPixelHeight(font, font_size)
	x_offset, y_offset, row_height: i32

	ascent, descent, line_gap: i32
	ttf.GetFontVMetrics(font, &ascent, &descent, &line_gap)

	for i in 0 ..< len(bitmap) do bitmap[i] = 0
	for codepoint in first_codepoint ..< first_codepoint + n_chars {
		width, height, xoff, yoff: i32

		advance_width, left_side_bearing: i32
		ttf.GetCodepointHMetrics(font, rune(codepoint), &advance_width, &left_side_bearing)

		sdf_data := ttf.GetCodepointSDF(
			font,
			scale,
			codepoint,
			padding,
			onedge,
			pixel_dist_scale,
			&width,
			&height,
			&xoff,
			&yoff,
		)
		defer ttf.FreeSDF(sdf_data, nil)

		if x_offset + width >= atlas_width {
			x_offset = 0
			y_offset += row_height + 10
			row_height = 0
		}
		if y_offset + height >= atlas_height {
			log.fatalf("font out of space")
			break
		}

		packed_chars[codepoint - first_codepoint] = {
			x0       = u16(x_offset),
			y0       = u16(y_offset),
			x1       = u16(x_offset + width),
			y1       = u16(y_offset + height),
			xoff     = f32(xoff),
			yoff     = f32(yoff),
			xadvance = f32(advance_width) * scale,
		}

		for y in 0 ..< height {
			for x in 0 ..< width {
				src_idx := y * width + x
				dst_idx := (y_offset + y) * atlas_width + (x_offset + x)
				bitmap[dst_idx] = sdf_data[src_idx]
			}
		}

		x_offset += width + 5
		if height > row_height do row_height = height
	}
	ttf.PackEnd(&ctx)

	font_handle, _ := create_texture_from_data(
		raw_data(bitmap),
		atlas_width,
		atlas_height,
		1,
		false,
		true,
	)

	font_out = {
		texture          = font_handle,
		chars            = packed_chars,
		scale            = scale,
		font_size        = font_size,
		first_codepoint  = first_codepoint,
		atlas_size       = {f32(atlas_width), f32(atlas_height)},
		edge             = onedge,
		pixel_dist_scale = pixel_dist_scale,
		ascent           = f32(ascent) * scale,
		descent          = f32(descent) * scale,
		line_gap         = f32(line_gap) * scale,
	}

	return font_out, true
}
