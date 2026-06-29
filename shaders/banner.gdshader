shader_type spatial;
render_mode cull_disabled, diffuse_lambert;

// Procedural medieval banner: draped cloth with a gold-trimmed heraldic shield
// over crossed swords. All drawn in UV space so no texture assets are needed.

uniform vec3 cloth_color : source_color = vec3(0.46, 0.07, 0.08);   // crimson
uniform vec3 cloth_dark : source_color = vec3(0.20, 0.03, 0.035);
uniform vec3 trim_color : source_color = vec3(0.82, 0.63, 0.22);    // gold
uniform vec3 shield_color : source_color = vec3(0.34, 0.40, 0.54);  // steel blue
uniform vec3 metal_color : source_color = vec3(0.84, 0.86, 0.90);   // blade
uniform vec3 hilt_color : source_color = vec3(0.64, 0.47, 0.16);    // brass

float box(vec2 p, vec2 h) {
	vec2 d = abs(p) - h;
	return step(max(d.x, d.y), 0.0);
}

mat2 rot(float a) { return mat2(vec2(cos(a), -sin(a)), vec2(sin(a), cos(a))); }

// Sword in local space, blade pointing -y. Returns 0 = none, 1 = blade (steel),
// 2 = brass (guard/grip/pommel). Long enough to poke out beyond the shield.
float sword_part(vec2 p) {
	float blade = box(p - vec2(0.0, -0.18), vec2(0.055, 0.74));
	float guard = box(p - vec2(0.0, 0.58), vec2(0.30, 0.058));
	float grip = box(p - vec2(0.0, 0.74), vec2(0.045, 0.12));
	float pommel = step(length(p - vec2(0.0, 0.89)), 0.08);
	if (blade > 0.5) { return 1.0; }
	if (max(max(guard, grip), pommel) > 0.5) { return 2.0; }
	return 0.0;
}

// Heraldic shield mask (rounded top, point at bottom), p scaled to ~[-1,1].
float shield_mask(vec2 p) {
	float top = box(p - vec2(0.0, -0.30), vec2(1.0, 0.52));
	float bw = clamp(1.0 - (p.y - 0.22) / 1.0, 0.0, 1.0);
	float bot = step(abs(p.x), bw) * step(0.22, p.y) * step(p.y, 1.3);
	return clamp(top + bot, 0.0, 1.0);
}

void fragment() {
	vec2 uv = UV;

	// Swallowtail drape: cut the lower corners into two tails with a centre notch.
	float bottom = 0.70 + 0.20 * smoothstep(0.0, 0.22, abs(uv.x - 0.5));
	if (uv.y > bottom || uv.x < 0.015 || uv.x > 0.985) {
		discard;
	}

	// Cloth: vertical fold shading + soft top-down darkening.
	float fold = 0.78 + 0.22 * (0.5 + 0.5 * sin(uv.x * 25.1));
	vec3 col = mix(cloth_dark, cloth_color, fold) * (1.0 - 0.12 * uv.y);

	// Gold trim: side rails, top band, and along the swallowtail hem.
	float trim = step(uv.x, 0.05) + step(0.95, uv.x) + step(uv.y, 0.04);
	trim += step(bottom - uv.y, 0.026);
	col = mix(col, trim_color, clamp(trim, 0.0, 1.0));

	// Emblem space (~[-1,1]) centred in the upper-middle of the banner.
	vec2 e = (uv - vec2(0.5, 0.40)) / 0.30;

	// Two crossed swords at ±45°, drawn first so the shield overlaps the crossing.
	float p1 = sword_part(rot(0.80) * e);
	float p2 = sword_part(rot(-0.80) * e);
	float blade = max(step(0.5, p1) * step(p1, 1.5), step(0.5, p2) * step(p2, 1.5));
	float brass = max(step(1.5, p1), step(1.5, p2));
	col = mix(col, metal_color, blade);
	col = mix(col, hilt_color, brass);

	// Shield over the crossing: steel face + gold border. Smaller than the sword
	// span so blade tips poke out the top and pommels out the bottom.
	vec2 sp = e / vec2(0.52, 0.66);
	float inner = shield_mask(sp);
	float outer = shield_mask(e / vec2(0.62, 0.78));
	col = mix(col, trim_color, outer - inner);
	col = mix(col, shield_color, inner);
	col += inner * vec3(1.0) * 0.08 * smoothstep(0.4, -1.0, sp.y);  // top bevel sheen

	float metalish = clamp(blade + brass, 0.0, 1.0);
	ALBEDO = col;
	ROUGHNESS = mix(0.85, 0.38, metalish + inner * 0.35);
	METALLIC = metalish * 0.55 + inner * 0.2;
}
