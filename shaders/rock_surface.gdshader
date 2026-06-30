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

// --- GPU-accelerated damage (default OFF; a perfect no-op when damage_enabled=0).
// A per-body damage texture (written by additive splats in a SubViewport, never
// read back) is sampled by world-space planar projection along the body's thinnest
// axis, producing craters + radial cracks + scorch on top of the rock look.
uniform float damage_enabled = 0.0;
uniform sampler2D damage_tex : filter_linear, repeat_disable;
uniform mat4 dmg_world_to_local;      // body global_transform inverse
uniform vec3 dmg_box_size = vec3(1.0);
uniform float dmg_crater_depth = 0.45;
uniform float dmg_tex_size = 512.0;

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying float v_face_mask;
varying float v_inst_seed;
varying float v_crack_mul;
varying float v_tint_mul;
varying vec3 v_dmg_t01;

float sample_noise(vec2 uv) {
	return texture(noise_texture, uv).r;
}

// Body-local 0..1 coords from a world position.
vec3 dmg_t01(vec3 w) {
	vec3 l = (dmg_world_to_local * vec4(w, 1.0)).xyz;
	return l / max(dmg_box_size, vec3(0.001)) + vec3(0.5);
}

// 6 SIGNED atlas regions: 0=+X 1=-X 2=+Y 3=-Y 4=+Z 5=-Z (so front/back, left/right,
// top/bottom are independent — a hit on one face never deforms the opposite one).
// Packed in a 3x2 grid.
vec2 dmg_region_local_uv(vec3 t01, int region) {
	if (region < 2) { return t01.zy; }   // ±X faces → (z, y)
	if (region < 4) { return t01.xz; }   // ±Y faces → (x, z)
	return t01.xy;                        // ±Z faces → (x, y)
}

vec2 dmg_atlas_uv(vec2 ruv, int region) {
	float col = float(region % 3);
	float row = float(region / 3);
	return vec2((col + clamp(ruv.x, 0.0, 1.0)) / 3.0, (row + clamp(ruv.y, 0.0, 1.0)) / 2.0);
}

float dmg_samp(vec3 t01, int region) {
	return textureLod(damage_tex, dmg_atlas_uv(dmg_region_local_uv(t01, region), region), 0.0).r;
}

float dmg_samp_ruv(vec2 ruv, int region) {
	return textureLod(damage_tex, dmg_atlas_uv(ruv, region), 0.0).r;
}

// A fragment's dominant face → its signed region (0..5).
int dmg_face_region(vec3 face_local) {
	vec3 a = abs(face_local);
	if (a.x >= a.y && a.x >= a.z) { return face_local.x > 0.0 ? 0 : 1; }
	if (a.y >= a.x && a.y >= a.z) { return face_local.y > 0.0 ? 2 : 3; }
	return face_local.z > 0.0 ? 4 : 5;
}

float dmg_hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float dmg_vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(dmg_hash(i), dmg_hash(i + vec2(1.0, 0.0)), f.x),
		mix(dmg_hash(i + vec2(0.0, 1.0)), dmg_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float dmg_fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) { v += a * dmg_vnoise(p); p = p * 2.03 + 11.0; a *= 0.5; }
	return v;
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

	// GPU damage: deform the mesh JAGGEDLY in the struck area — every vertex near
	// the damage is shoved inward + chaotically, but the result is clamped back
	// into the original chunk volume so nothing pokes outside the block.
	v_dmg_t01 = vec3(0.0);
	if (damage_enabled > 0.5) {
		v_dmg_t01 = dmg_t01(v_world_pos);
		// Which faces this vertex sits on — from the CHUNK-local position (~±0.5),
		// NOT the body UV. (Using body UV meant only chunks at a body's outer edge
		// deformed; mid-body chunks never did.) The damage value itself is still
		// sampled in body UV so it lands where the hit was. A face-centre vertex
		// feels one face; an edge two; a corner three — and never the opposite side.
		float fe = 0.32;
		float d = 0.0;
		vec3 fn = vec3(0.0);  // sum of unit normals of the faces this vertex sits on
		if (VERTEX.x > fe) { d = max(d, dmg_samp(v_dmg_t01, 0)); fn.x += 1.0; }
		if (VERTEX.x < -fe) { d = max(d, dmg_samp(v_dmg_t01, 1)); fn.x -= 1.0; }
		if (VERTEX.y > fe) { d = max(d, dmg_samp(v_dmg_t01, 2)); fn.y += 1.0; }
		if (VERTEX.y < -fe) { d = max(d, dmg_samp(v_dmg_t01, 3)); fn.y -= 1.0; }
		if (VERTEX.z > fe) { d = max(d, dmg_samp(v_dmg_t01, 4)); fn.z += 1.0; }
		if (VERTEX.z < -fe) { d = max(d, dmg_samp(v_dmg_t01, 5)); fn.z -= 1.0; }
		if (d > 0.02) {
			vec3 lp3 = (v_dmg_t01 - vec3(0.5)) * dmg_box_size;  // body-local m
			float jag = 0.4 + 1.2 * dmg_fbm(lp3.xy * 3.5 + lp3.z);
			float dist = length(VERTEX);
			float carve = smoothstep(0.05, 1.0, d * jag) * dmg_crater_depth;
			carve = min(carve, dist * 0.92);  // never punch past the chunk centre
			// Erode INWARD along the faces the vertex is on: a flat face caves into a
			// clean bowl (all verts share one inward dir, so no star); an edge folds;
			// a corner (3 faces) collapses toward the centre — keeps the dramatic
			// corner removal while giving flat hits a real crater.
			vec3 erode_dir = length(fn) > 0.001 ? -normalize(fn) : -VERTEX / max(dist, 1e-4);
			vec3 jit = vec3(
				dmg_fbm(lp3.yz * 4.0 + 3.7),
				dmg_fbm(lp3.xz * 4.0 + 19.3),
				dmg_fbm(lp3.xy * 4.0 + 41.1)) - vec3(0.5);
			VERTEX += erode_dir * carve;
			VERTEX += jit * carve * 0.45;
			// Stay inside the original chunk volume (unit box, half-extent 0.5).
			VERTEX = clamp(VERTEX, vec3(-0.5), vec3(0.5));
		}
		v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
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

	// Damage encoded in the crack channel (g): pristine bricks sit at <= 1.6, hits
	// push it toward ~6. Higher damage lowers the crack threshold so more fracture
	// lines emerge, raises their contrast, and scorches the stone darker.
	float dmg = clamp((crack_mul - 1.6) / 4.4, 0.0, 1.0);

	float crack_raw = max(1.0 - abs(rock * 2.0 - 1.0), 1.0 - abs(detail * 2.0 - 1.0));
	// Pristine hairline cracks (per-brick variation), plus damage fractures that
	// grow more numerous (lower threshold) and contrastier as damage rises.
	float base_cracks = smoothstep(0.80, 0.97, crack_raw) * min(crack_mul, 1.5);
	float dmg_cracks = smoothstep(mix(0.82, 0.62, dmg), 0.96, crack_raw) * dmg;
	float crack_line = clamp(max(base_cracks, dmg_cracks), 0.0, 1.0);

	vec3 stone_face = base_color * tint_mul * (0.76 + combined * color_variation);
	stone_face *= 1.0 - dmg * 0.28;
	stone_face = mix(stone_face * 0.62, stone_face, 1.0 - pit * pit_depth);
	float crack_dark = clamp(crack_depth + dmg * 0.4, 0.0, 0.95);
	stone_face = mix(stone_face, stone_face * 0.12, crack_line * crack_dark);

	float edge_dist = min(min(0.5 - abs(lp.x), 0.5 - abs(lp.y)), 0.5 - abs(lp.z));
	float moss_mask = step(0.5, face_local.y) * smoothstep(0.10, 0.18, edge_dist);
	moss_mask *= 1.0 - smoothstep(0.30, 0.56, combined);
	moss_mask *= 1.0 - crack_line * 0.85;
	stone_face = mix(stone_face, moss_color, moss_mask * moss_amount);

	vec3 stone_bevel = base_color * tint_mul * 0.92;
	vec3 col = mix(stone_face, stone_bevel, bevel);

	// --- GPU damage overlay: dark hole, spalled rim, radial cracks (signed region) ---
	if (damage_enabled > 0.5) {
		int region = dmg_face_region(face_local);
		vec2 ruv = dmg_region_local_uv(v_dmg_t01, region);
		vec2 plane = region < 2 ? dmg_box_size.zy : (region < 4 ? dmg_box_size.xz : dmg_box_size.xy);
		vec2 wc = ruv * plane;                          // world-space coords (m)

		float raw = dmg_samp_ruv(ruv, region);
		float j = dmg_fbm(wc * 6.0);
		float c = clamp(raw * (0.4 + 1.25 * j) - 0.05, 0.0, 1.5);
		// Isotropic world-space gradient (4cm step) — same in U and V regardless of
		// the body's aspect or the atlas packing.
		float ws = 0.04;
		vec2 du = vec2(ws / max(plane.x, 0.01), 0.0);
		vec2 dv = vec2(0.0, ws / max(plane.y, 0.01));
		vec2 grad = vec2(
			dmg_samp_ruv(ruv + du, region) - dmg_samp_ruv(ruv - du, region),
			dmg_samp_ruv(ruv + dv, region) - dmg_samp_ruv(ruv - dv, region));

		float hole = smoothstep(0.28, 0.62, c);
		float spall = smoothstep(0.04, 0.3, c) * (1.0 - hole);
		col = mix(col, col * 1.22, spall * 0.6);
		col = mix(col, vec3(0.02), hole);

		// Crater depth via normal perturbation (the chunk mesh is too coarse to
		// displace a bullet-sized pit, so the dome/pit is faked in the shading).
		float nscale = 9.0;
		vec3 dn = normalize(vec3(-grad.x * nscale, -grad.y * nscale, 1.0));
		NORMAL = normalize(TANGENT * dn.x + BINORMAL * dn.y + NORMAL * dn.z);

		float band = smoothstep(0.01, 0.08, raw) * (1.0 - smoothstep(0.4, 0.7, raw));
		band *= smoothstep(0.003, 0.02, length(grad));
		float ang = atan(grad.y, grad.x) + (dmg_fbm(wc * 2.4) - 0.5) * 0.9;
		float phase = dmg_fbm(wc * 0.5) * 12.0;
		float spoke = abs(fract(ang / 6.28318 * 9.0 + phase) - 0.5) * 2.0;
		float radial = (1.0 - smoothstep(0.0, 0.12, spoke)) * band;
		col = mix(col, vec3(0.04), radial * 0.85);
	}

	ALBEDO = col;
	ROUGHNESS = clamp(
		roughness + (1.0 - bevel) * (pit * 0.18 + crack_line * 0.12 + (1.0 - combined) * 0.08),
		0.0, 1.0);
	METALLIC = 0.0;
}
