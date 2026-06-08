shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

// Flowing lava — samples world XZ so floor, pillars, and sinking bodies tile consistently.
uniform float time_scale_factor = 0.04;
uniform float uv_scale = 1.0;
uniform float world_scale = 0.8;
uniform float emission_strength = 0.85;
uniform sampler2D noise_texture : repeat_enable, filter_linear;

varying vec3 v_world_pos;

float local_time() {
	return TIME * time_scale_factor;
}

mat2 make_m2(float theta) {
	float c = cos(theta);
	float s = sin(theta);
	return mat2(vec2(c, -s), vec2(s, c));
}

float noise(vec2 x) {
	return texture(noise_texture, x * 0.01).x;
}

vec2 gradn(vec2 p) {
	float ep = 0.09;
	float gradx = noise(vec2(p.x + ep, p.y)) - noise(vec2(p.x - ep, p.y));
	float grady = noise(vec2(p.x, p.y + ep)) - noise(vec2(p.x, p.y - ep));
	return vec2(gradx, grady);
}

float flow(vec2 p) {
	float z = 2.0;
	float rz = 0.0;
	vec2 bp = p;
	for (float i = 1.0; i < 7.0; i += 1.0) {
		p += local_time() * 0.6;
		bp += local_time() * 1.9;
		vec2 gr = gradn(i * p * 0.34 + local_time());
		gr *= make_m2(local_time() * 6.0 - (0.05 * p.x + 0.03 * p.y) * 40.0);
		p += gr * 0.5;
		rz += (sin(noise(p) * 7.0) * 0.5 + 0.5) / z;
		p = mix(bp, p, 0.77);
		z *= 1.4;
		p *= 2.0;
		bp *= 1.9;
	}
	return rz;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_world_pos.xz * world_scale;
	p *= uv_scale;
	float rz = flow(p);
	vec3 col = vec3(0.2, 0.07, 0.01) / max(rz, 0.08);
	col = pow(col, vec3(1.4));
	ALBEDO = col;
	EMISSION = col * emission_strength;
}
