package tinyobj

import "core:log"
import os "core:os/os2"
import "core:slice"
import "core:strconv"
import "core:strings"
Vertex :: [4]f32
TexCoord :: [3]f32
Normal :: [3]f32

FaceVertex :: [3]u64
Triangle :: [3]FaceVertex

TinyObj :: struct {
	vertices:   []Vertex,
	tex_coords: []TexCoord,
	normals:    []Normal,
	tris:       []Triangle,
}

load_from_filepath :: proc(filepath: string, allocator := context.allocator) -> TinyObj {
	data, err := os.read_entire_file_from_path(filepath, allocator)
	if err != nil {
		log.debug(err)
		return {}
	}
	defer delete(data, allocator)

	vertices := make([dynamic]Vertex, allocator)
	defer delete(vertices)
	tex_coords := make([dynamic]TexCoord, allocator)
	defer delete(tex_coords)
	normals := make([dynamic]Normal, allocator)
	defer delete(normals)

	triangles := make([dynamic]Triangle, allocator)
	defer delete(triangles)

	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		parts, _ := strings.split(line, " ", allocator)
		defer delete(parts)
		if parts[0] == "v" {
			vertex: Vertex = {0, 0, 0, 1}
			for i in 0 ..< len(parts) - 1 {
				vertex[i], _ = strconv.parse_f32(
					strings.trim_right(strings.trim_left(parts[i + 1], "["), "]"),
				)
			}
			append(&vertices, vertex)
		} else if parts[0] == "vt" {
			coord: TexCoord
			for i in 0 ..< len(parts) - 1 {
				coord[i], _ = strconv.parse_f32(
					strings.trim_right(strings.trim_left(parts[i + 1], "["), "]"),
				)
			}
			append(&tex_coords, coord)
		} else if parts[0] == "vn" {
			normal: Normal
			for i in 0 ..< 3 {
				normal[i], _ = strconv.parse_f32(parts[i + 1])
			}
			append(&normals, normal)
		} else if parts[0] == "f" {
			tri: Triangle
			for i in 0 ..< 3 {
				index_parts, _ := strings.split(parts[i + 1], "/", allocator)
				defer delete(index_parts)
				for index, j in index_parts {
					tri[i][j], _ = strconv.parse_u64(index)
				}
			}
			append(&triangles, tri)
		}
	}

	return {
		vertices = slice.clone(vertices[:]),
		tex_coords = slice.clone(tex_coords[:]),
		normals = slice.clone(normals[:]),
		tris = slice.clone(triangles[:]),
	}
}

destroy_obj :: proc(obj: TinyObj) {
	delete(obj.vertices)
	delete(obj.tex_coords)
	delete(obj.normals)
	delete(obj.tris)
}
