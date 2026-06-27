shader_type spatial;
render_mode unshaded, cull_disabled;

// Smooth molten lava — world XZ sampling so floor, leaks, and sinking bodies match.
uniform float time_scale = 0.035;
uniform float world_scale = 0.048;
uniform float flow_speed = 0.42;
uniform float crust_sharpness = 2.4;
uniform float vein_sharpness = 3.2;
uniform float emission_strength = 1.35;
uniform vec3 col_cool : source_color = vec3(0.14, 0.05, 0.01);
uniform vec3 col_hot : source_color = vec3(0.92, 0.30, 0.05);
uniform vec3 col_bright : source_color = vec3(1.0, 0.68, 0.22);
uniform sampler2D noise_texture : repeat_enable, filter_linear_mipmap;

varying vec3 v_world_pos;

float sample_n(vec2 uv) {
	return texture(noise_texture, uv * 0.01).r;
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.52;
	for (int i = 0; i < 4; i++) {
		v += amp * sample_n(p);
		p *= 2.04;
		amp *= 0.5;
	}
	return v;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 w = v_world_pos.xz * world_scale;
	float t = TIME * time_scale;
	vec2 drift = vec2(t * flow_speed, t * flow_speed * 0.58);

	float base = fbm(w + drift);
	float detail = fbm(w * 1.85 - drift * 1.25 + vec2(4.2, 1.1));
	float veins = 1.0 - abs(base * 2.0 - 1.0);
	veins = pow(veins, vein_sharpness);

	float crust = 1.0 - abs(detail * 2.0 - 1.0);
	crust = pow(crust, crust_sharpness);

	float heat = clamp(base * 0.58 + detail * 0.42, 0.0, 1.0);
	heat = smoothstep(0.18, 0.82, heat + veins * 0.38 - crust * 0.22);

	vec3 col = mix(col_cool, col_hot, heat);
	col = mix(col, col_bright, pow(heat, 2.6) * veins);

	ALBEDO = col;
	EMISSION = col * emission_strength;
}
