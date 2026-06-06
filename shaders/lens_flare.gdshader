// TRANSLATED & MODIFIED FROM: https://www.shadertoy.com/view/4sX3Rs

shader_type canvas_item;
render_mode blend_add;

uniform sampler2D noise_texture : repeat_enable, filter_linear;
uniform vec2 sun_position = vec2(-1000.0);
uniform vec3 tint = vec3(1.1, 0.9, 0.65);
uniform float flare_strength = 0.0;
uniform float flare_gain = 0.52;
uniform float impact_flash = 0.0;
uniform vec2 noise_tex_size = vec2(256.0, 256.0);

float noise_vec2(vec2 t, vec2 tex_resolution) {
	return texture(noise_texture, t / tex_resolution).x;
}

vec3 lensflare(vec2 uv, vec2 pos, vec2 tex_resolution) {
	vec2 uvd = uv * length(uv);

	float f2 = max(1.0 / (1.0 + 32.0 * pow(length(uvd + 0.8 * pos), 2.0)), 0.0) * 0.25;
	float f22 = max(1.0 / (1.0 + 32.0 * pow(length(uvd + 0.85 * pos), 2.0)), 0.0) * 0.23;
	float f23 = max(1.0 / (1.0 + 32.0 * pow(length(uvd + 0.9 * pos), 2.0)), 0.0) * 0.21;

	vec2 uvx = mix(uv, uvd, -0.5);
	float f4 = max(0.01 - pow(length(uvx + 0.4 * pos), 2.4), 0.0) * 6.0;
	float f42 = max(0.01 - pow(length(uvx + 0.45 * pos), 2.4), 0.0) * 5.0;
	float f43 = max(0.01 - pow(length(uvx + 0.5 * pos), 2.4), 0.0) * 3.0;

	uvx = mix(uv, uvd, -0.4);
	float f5 = max(0.01 - pow(length(uvx + 0.2 * pos), 5.5), 0.0) * 2.0;
	float f52 = max(0.01 - pow(length(uvx + 0.4 * pos), 5.5), 0.0) * 2.0;
	float f53 = max(0.01 - pow(length(uvx + 0.6 * pos), 5.5), 0.0) * 2.0;

	uvx = mix(uv, uvd, -0.5);
	float f6 = max(0.01 - pow(length(uvx - 0.3 * pos), 1.6), 0.0) * 6.0;
	float f62 = max(0.01 - pow(length(uvx - 0.325 * pos), 1.6), 0.0) * 3.0;
	float f63 = max(0.01 - pow(length(uvx - 0.35 * pos), 1.6), 0.0) * 5.0;

	vec3 c = vec3(0.0);
	c.r += f2 + f4 + f5 + f6;
	c.g += f22 + f42 + f52 + f62;
	c.b += f23 + f43 + f53 + f63;
	c = c * 1.3 - vec3(length(uvd) * 0.05);
	return max(c, vec3(0.0));
}

void fragment() {
	vec2 resolution = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = FRAGCOORD.xy / resolution - 0.5;
	uv.x *= resolution.x / resolution.y;
	vec2 mouse = (sun_position / resolution) - vec2(0.5);
	mouse.x *= resolution.x / resolution.y;

	vec3 flare = tint * lensflare(uv, mouse, noise_tex_size) * flare_strength * flare_gain;
	flare -= noise_vec2(FRAGCOORD.xy, noise_tex_size) * 0.015 * flare_strength;
	vec3 flash = vec3(14.0, 12.0, 8.5) * impact_flash;
	COLOR = vec4(max(flare + flash, vec3(0.0)), 1.0);
}
