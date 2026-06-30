shader_type spatial;
render_mode blend_add, unshaded, cull_disabled;

uniform vec4 trail_color : source_color = vec4(1.0, 0.92, 0.62, 1.0);
uniform vec3 head_world;
uniform vec3 tail_world;
uniform float trail_radius = 0.02;
uniform float head_strength : hint_range(0.0, 32.0) = 12.0;
uniform float length_falloff : hint_range(0.5, 4.0) = 2.0;
uniform float bloom_gain : hint_range(1.0, 16.0) = 10.0;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 seg = tail_world - head_world;
	float seg_len = length(seg);
	if (seg_len < 0.0005) {
		discard;
	}
	vec3 dir = seg / seg_len;
	vec3 rel = v_world_pos - head_world;
	float along = clamp(dot(rel, dir) / seg_len, 0.0, 1.0);
	vec3 closest = head_world + dir * (along * seg_len);
	float axis_dist = length(v_world_pos - closest);

	// Bright at the bullet, soft fade toward the tail.
	float along_fade = pow(1.0 - along, length_falloff);
	along_fade *= smoothstep(1.0, 0.06, along);

	// Soft cross-section — Gaussian falloff from the streak centerline.
	float r = axis_dist / max(trail_radius, 0.0001);
	float radial_fade = exp(-0.85 * r * r);

	float alpha = along_fade * radial_fade * trail_color.a;
	vec3 core = trail_color.rgb * head_strength * along_fade * radial_fade;
	vec3 hdr = core * bloom_gain;

	ALBEDO = hdr;
	EMISSION = hdr;
	ALPHA = alpha;
}
