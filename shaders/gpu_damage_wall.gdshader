shader_type spatial;

// Reads a GPU-resident damage accumulation texture (written by additive splats in
// a SubViewport — never read back to the CPU) and turns it into jagged, cracked
// surface damage: vertices torn inward into rough craters, a perturbed normal so
// the pit reads under lighting, crack veins, and scorch.

uniform sampler2D damage_tex : filter_linear, repeat_disable;
uniform vec3 base_color : source_color = vec3(0.55, 0.51, 0.46);
uniform vec3 scorch_color : source_color = vec3(0.09, 0.07, 0.06);
uniform float crater_depth = 0.8;
uniform float dmg_size = 1024.0;

varying vec2 v_uv;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.0;
		a *= 0.5;
	}
	return v;
}

// Ridged noise -> crack veins (1 on a vein, 0 elsewhere). Two octaves of veins:
// bold primary fractures plus finer branches.
float crack_veins(vec2 p) {
	float r1 = abs(fbm(p) * 2.0 - 1.0);
	float major = 1.0 - smoothstep(0.0, 0.07, r1);
	float r2 = abs(fbm(p * 2.4 + 5.0) * 2.0 - 1.0);
	float minor = (1.0 - smoothstep(0.0, 0.045, r2)) * 0.65;
	return clamp(max(major, minor), 0.0, 1.0);
}

// Raw damage torn up by noise so the crater isn't a clean circle.
float jagged_damage(vec2 uv) {
	float c = texture(damage_tex, uv).r;
	float j = fbm(uv * 46.0);
	return clamp(c * (0.4 + 1.25 * j) - 0.05, 0.0, 1.5);
}

void vertex() {
	v_uv = UV;
	float d = textureLod(damage_tex, UV, 0.0).r;
	float j = fbm(UV * 34.0);
	float dd = smoothstep(0.04, 1.0, d * (0.45 + 1.1 * j));
	VERTEX -= NORMAL * dd * crater_depth;
}

void fragment() {
	float texel = 1.0 / dmg_size;
	float c = jagged_damage(v_uv);
	float dl = jagged_damage(v_uv - vec2(texel, 0.0));
	float dr = jagged_damage(v_uv + vec2(texel, 0.0));
	float dd = jagged_damage(v_uv - vec2(0.0, texel));
	float du = jagged_damage(v_uv + vec2(0.0, texel));

	// Jagged tangent-space normal from the torn damage heightfield.
	float scale = crater_depth * 34.0;
	vec3 n = normalize(vec3((dl - dr) * scale, (dd - du) * scale, 1.0));
	NORMAL = normalize(TANGENT * n.x + BINORMAL * n.y + NORMAL * n.z);

	float raw = texture(damage_tex, v_uv).r;
	vec2 grad = vec2(dr - dl, du - dd);  // points toward the hole centre

	// Dark inner hole, lighter spalled/chipped rim around it.
	float hole = smoothstep(0.5, 0.85, c);
	float spall = smoothstep(0.05, 0.45, c) * (1.0 - hole);
	vec3 col = base_color;
	col = mix(col, base_color * 1.15, spall * 0.6);    // chipped rim = lighter stone
	col = mix(col, vec3(0.02), hole);                  // near-black hole

	// Cracks RADIATING from the hole: thin spokes around the gradient angle, in an
	// annulus from the rim outward (the brush's faint halo gives them room to fan).
	float band = smoothstep(0.01, 0.08, raw) * (1.0 - smoothstep(0.4, 0.7, raw));
	band *= smoothstep(0.0004, 0.0028, length(grad));
	float ang = atan(grad.y, grad.x) + (fbm(v_uv * 15.0) - 0.5) * 0.9;
	float phase = fbm(v_uv * 3.0) * 12.0;
	float spoke = abs(fract(ang / 6.28318 * 9.0 + phase) - 0.5) * 2.0;
	float radial = (1.0 - smoothstep(0.0, 0.12, spoke)) * band;
	col = mix(col, vec3(0.05), radial * 0.9);

	ALBEDO = col;
	ROUGHNESS = mix(0.9, 0.7, spall + hole);
	METALLIC = 0.0;
}
