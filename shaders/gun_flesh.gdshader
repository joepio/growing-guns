shader_type spatial;
render_mode diffuse_toon;

// Stylized living flesh for demon-gun growths (see demon_growth.gd).
// Heartbeat-pulsing emissive veins + breathing vertex displacement.
// Wet/glossy on purpose — contrasts against the gun's matte toon metal so
// organic parts read as a different *substance*, not just a different color.

uniform vec3 base_color : source_color = vec3(0.46, 0.13, 0.15);
uniform vec3 crevice_color : source_color = vec3(0.17, 0.03, 0.09);
uniform vec3 vein_color : source_color = vec3(1.0, 0.25, 0.08);
uniform float vein_emission : hint_range(0.0, 8.0) = 2.4;
// Veins never go fully dark — keeps stills/screenshots readable and the gun
// visibly "on" even between heartbeats.
uniform float emission_floor : hint_range(0.0, 1.0) = 0.35;
uniform float breathe_amp : hint_range(0.0, 0.02) = 0.004;
uniform float beat_period : hint_range(0.3, 3.0) = 1.15;
uniform float noise_scale : hint_range(10.0, 400.0) = 115.0;
// Per-mesh desync so a cluster of growths doesn't pulse in lock-step
// (set via set_instance_shader_parameter in demon_growth.gd).
instance uniform float phase = 0.0;

varying vec3 obj_pos;

float hash3(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash3(i);
	float n100 = hash3(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash3(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash3(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash3(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash3(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash3(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash3(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}

float fbm(vec3 p) {
	return 0.65 * vnoise(p) + 0.35 * vnoise(p * 2.63 + 11.7);
}

// Double-thump cardiac waveform: sharp systole, softer echo, long rest.
float heartbeat(float t) {
	float x = fract(t / beat_period);
	float b1 = exp(-pow((x - 0.12) / 0.045, 2.0));
	float b2 = 0.55 * exp(-pow((x - 0.32) / 0.065, 2.0));
	return clamp(b1 + b2, 0.0, 1.0);
}

void vertex() {
	obj_pos = VERTEX * noise_scale + vec3(phase * 13.7);
	float beat = heartbeat(TIME + phase);
	// Lumpy breathing: displacement varies across the surface so the mass
	// squirms rather than uniformly inflating like a balloon.
	float lump = vnoise(VERTEX * noise_scale * 0.45 + vec3(phase * 7.1));
	VERTEX += NORMAL * breathe_amp * (0.35 + 0.65 * beat) * (0.35 + 0.65 * lump);
}

void fragment() {
	float n = fbm(obj_pos);
	// Ridged noise folded into thin bright lines = vein network. Sampled at
	// low frequency so veins run long and winding instead of dense crackle
	// (dense crackle reads as lava rock, not tissue).
	float ridge = 1.0 - abs(2.0 * vnoise(obj_pos * 0.45 + 7.0) - 1.0);
	float wiggle = vnoise(obj_pos * 1.7 + 3.0) * 0.06;
	float veins = smoothstep(0.9 - wiggle, 0.975, ridge);
	// Veins live in patches, not uniformly everywhere.
	veins *= smoothstep(0.32, 0.62, vnoise(obj_pos * 0.22 + 21.0));

	vec3 col = mix(crevice_color, base_color, smoothstep(0.2, 0.8, n));
	ALBEDO = mix(col, vein_color * 0.55, veins * 0.85);
	ROUGHNESS = mix(0.42, 0.22, veins);  // veins sit wetter than the tissue
	SPECULAR = 0.45;

	float beat = heartbeat(TIME + phase);
	float glow = max(emission_floor, beat);
	EMISSION = vein_color * veins * vein_emission * glow;
	// Faint fresnel so silhouettes read soft/translucent at grazing angles.
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION += base_color * fres * 0.3;
}
