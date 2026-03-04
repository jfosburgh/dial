package camera

import "core:log"
import "core:math"
import glm "core:math/linalg"


Projection :: enum {
	Orthographic,
	Perspective,
}

Camera :: struct {
	pos:              [3]f32,
	forward:          [3]f32,
	right:            [3]f32,
	up:               [3]f32,
	world_up:         [3]f32,
	pitch, yaw:       f32,
	move_sensitivity: f32,
	look_sensitivity: f32,
	zoom:             f32,
	projection:       Projection,
}

get_view :: proc(c: Camera) -> matrix[4, 4]f32 {
	log.debugf(
		"pos: %+v\nforward: %+v\nlook at: %+v\nup: %+v\n",
		c.pos,
		c.forward,
		c.pos + c.forward,
		c.up,
	)
	return glm.matrix4_look_at_f32(c.pos, c.pos + c.forward, c.up)
}

get_projection :: proc(c: Camera, aspect: f32) -> matrix[4, 4]f32 {
	switch c.projection {
	case .Perspective:
		return matrix4_perspective_z0_f32(glm.to_radians(f32(45) * c.zoom), aspect, 0.1, 1000)
	case .Orthographic:
		unimplemented()
	}
	return {}
}

translate :: proc(c: ^Camera, forward, right, up, dt: f32) {
	speed := c.move_sensitivity * dt
	c.pos += forward * c.forward * speed
	c.pos += right * c.right * speed
	c.pos += up * c.up * speed
}

look :: proc(c: ^Camera, x_rel, y_rel, dt: f32) {
	c.yaw += c.look_sensitivity * x_rel * dt
	c.pitch = clamp(c.pitch - c.look_sensitivity * y_rel * dt, -89, 89)

	update_camera_vectors(c)
}

update_camera_vectors :: proc(c: ^Camera) {
	front: [3]f32
	front.x = math.cos(glm.to_radians(c.yaw)) * math.cos(glm.to_radians(c.pitch))
	front.y = math.sin(glm.to_radians(c.pitch))
	front.z = math.sin(glm.to_radians(c.yaw)) * math.cos(glm.to_radians(c.pitch))

	c.forward = glm.normalize(front)
	c.right = glm.normalize(glm.cross(c.forward, c.world_up))
	c.up = glm.normalize(glm.cross(c.right, c.forward))
}

set_world_up :: proc(c: ^Camera, up: [3]f32) {
	c.world_up = up
}

@(require_results)
matrix4_perspective_z0_f32 :: proc "contextless" (
	fovy, aspect, near, far: f32,
) -> (
	m: glm.Matrix4f32,
) #no_bounds_check {
	tan_half_fovy := math.tan(0.5 * fovy)
	m[0, 0] = 1 / (aspect * tan_half_fovy)
	m[1, 1] = 1 / (tan_half_fovy)
	m[3, 2] = +1

	m[2, 2] = far / (far - near)
	m[2, 3] = -(far * near) / (far - near)

	m[2] = -m[2]
	m[1, 1] *= -1

	return
}
