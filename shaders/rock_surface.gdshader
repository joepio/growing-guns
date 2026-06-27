shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_back;

uniform vec3 base_color : source_color = vec3(0.52, 0.50, 0.47);
uniform vec3 moss_color : source_color = vec3(0.38, 0.58, 0.32);
uniform float roughness : hint_range(0.0, 1.0) = 0.96;
uniform float noise_scale = 0.085;
uniform float detail_scale = 2.0;
uniform float color_variation = 0.28;
uniform float pit_depth = 0.48;
uniform float crack_depth = 0.52;
uniform float moss_amount = 0.38;
uniform float deform_amount = 0.055;
uniform float material_seed = 0.0;
uniform sampler2D noise_texture : repeat_enable, filter_linear_mipmap;

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying float v_face_mask;
varying float v_inst_seed;
varying float v_crack_mul;
varying float v_tint_mul;

float sample_noise(vec2 uv) {
	return texture(noise_texture, uv).r;
}

vec3 dominant_face_axis(vec3 lp) {
	vec3 ap = abs(lp);
	if (ap.x >= ap.y && ap.x >= ap.z) {
		return vec3(sign(lp.x), 0.0, 0.0);
	}
	if (ap.y >= ap.x && ap.y >= ap.z) {
		return vec3(0.0, sign(lp.y), 0.0);
	}
	return vec3(0.0, 0.0, sign(lp.z));
}

float face_noise(vec3 p, vec3 face_axis, float scale) {
	vec2 seed2 = vec2(material_seed * 0.137, material_seed * 0.419);
	if (abs(face_axis.x) > 0.5) {
		return sample_noise(p.yz * scale + seed2);
	}
	if (abs(face_axis.y) > 0.5) {
		return sample_noise(p.xz * scale + seed2 * 1.7);
	}
	return sample_noise(p.xy * scale + seed2 * 2.3);
}

void vertex() {
	vec3 lp = VERTEX;
	vec3 ap = abs(lp);
	vec3 face_axis = dominant_face_axis(lp);
	float maxap = max(ap.x, max(ap.y, ap.z));
	float cornerness = min(ap.x, min(ap.y, ap.z)) / max(maxap, 0.0001);

	float on_flat = smoothstep(0.36, 0.48, maxap);
	float not_bevel = 1.0 - smoothstep(0.42, 0.78, cornerness);
	v_face_mask = on_flat * not_bevel;

	float inst_seed = INSTANCE_CUSTOM.r * 997.0 + material_seed;
	float deform_mul = INSTANCE_CUSTOM.a > 0.01 ? INSTANCE_CUSTOM.a : 0.65;
	v_inst_seed = inst_seed;
	v_crack_mul = INSTANCE_CUSTOM.g > 0.01 ? INSTANCE_CUSTOM.g : 1.0;
	v_tint_mul = INSTANCE_CUSTOM.b > 0.01 ? INSTANCE_CUSTOM.b : 1.0;

	vec3 bump_p = lp * 2.4 + vec3(inst_seed * 0.013, inst_seed * 0.027, inst_seed * 0.041);
	float bump = face_noise(bump_p, face_axis, noise_scale * 3.6);
	float chip = face_noise(bump_p * 2.3 + vec3(0.17), face_axis, noise_scale * 8.5);
	float disp = (bump * 0.62 + chip * 0.38 - 0.5) * deform_amount * deform_mul * v_face_mask;
	VERTEX += face_axis * disp;

	v_local_pos = VERTEX;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 lp = v_local_pos;
	vec3 ap = abs(lp);
	vec3 face_local = dominant_face_axis(lp);

	float inst_seed = v_inst_seed;
	float crack_mul = v_crack_mul;
	float tint_mul = v_tint_mul;

	float cornerness = min(ap.x, min(ap.y, ap.z)) / max(max(ap.x, ap.y), ap.z);
	float bevel = smoothstep(0.58, 0.86, cornerness);

	vec3 sample_p = v_world_pos + vec3(inst_seed * 0.31, inst_seed * 0.53, inst_seed * 0.71);
	float rock = face_noise(sample_p, face_local, noise_scale);
	float detail = face_noise(sample_p, face_local, noise_scale * detail_scale);
	float combined = rock * 0.58 + detail * 0.42;

	float pit = 1.0 - smoothstep(0.14, 0.38, combined);
	float pit2 = 1.0 - smoothstep(0.22, 0.48, detail);
	pit = max(pit, pit2 * 0.72);

	float ridge = 1.0 - abs(rock * 2.0 - 1.0);
	ridge = smoothstep(0.78, 0.97, ridge) * crack_mul;
	float vein = 1.0 - abs(detail * 2.0 - 1.0);
	vein = smoothstep(0.70, 0.94, vein) * crack_mul * 0.75;
	float crack_line = max(ridge, vein);

	vec3 stone_face = base_color * tint_mul * (0.76 + combined * color_variation);
	stone_face = mix(stone_face * 0.62, stone_face, 1.0 - pit * pit_depth);
	stone_face = mix(stone_face * 0.38, stone_face, 1.0 - crack_line * crack_depth);

	float edge_dist = min(min(0.5 - abs(lp.x), 0.5 - abs(lp.y)), 0.5 - abs(lp.z));
	float moss_mask = step(0.5, face_local.y) * smoothstep(0.10, 0.18, edge_dist);
	moss_mask *= 1.0 - smoothstep(0.30, 0.56, combined);
	moss_mask *= 1.0 - crack_line * 0.85;
	stone_face = mix(stone_face, moss_color, moss_mask * moss_amount);

	vec3 stone_bevel = base_color * tint_mul * 0.92;
	vec3 col = mix(stone_face, stone_bevel, bevel);

	ALBEDO = col;
	ROUGHNESS = clamp(
		roughness + (1.0 - bevel) * (pit * 0.18 + crack_line * 0.12 + (1.0 - combined) * 0.08),
		0.0, 1.0);
	METALLIC = 0.0;
}
