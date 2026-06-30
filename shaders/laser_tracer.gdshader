shader_type spatial;
render_mode blend_add, unshaded, cull_disabled;

uniform vec4 beam_color : source_color = vec4(1.0, 0.96, 0.88, 1.0);
uniform vec3 head_world;
uniform vec3 tail_world;
uniform float beam_radius = 0.012;
uniform float bloom_gain : hint_range(1.0, 24.0) = 14.0;
uniform float alpha_scale : hint_range(0.0, 1.0) = 1.0;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 seg = tail_world - head_world;
	float seg_len = length(seg);
	if (seg_len < 0.0001) {
		discard;
	}
	vec3 dir = seg / seg_len;
	vec3 rel = v_world_pos - head_world;
	float along = dot(rel, dir) / seg_len;
	if (along < -0.02 || along > 1.02) {
		discard;
	}
	vec3 closest = head_world + dir * clamp(along, 0.0, 1.0) * seg_len;
	float axis_dist = length(v_world_pos - closest);

	float radial = axis_dist / max(beam_radius, 0.0001);
	float radial_fade = exp(-1.15 * radial * radial);

	// Hot core along the whole beam; tiny falloff at the far end.
	float along_fade = mix(0.72, 1.0, 1.0 - smoothstep(0.88, 1.0, clamp(along, 0.0, 1.0)));

	float alpha = radial_fade * along_fade * beam_color.a * alpha_scale;
	vec3 hdr = beam_color.rgb * bloom_gain * radial_fade * along_fade;

	ALBEDO = hdr;
	EMISSION = hdr;
	ALPHA = alpha;
}
