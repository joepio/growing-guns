shader_type spatial;
render_mode diffuse_lambert, specular_disabled, blend_mix, depth_draw_never, cull_back;

// Scorch + blood marks on the colosseum steps: flat quads from ONE rolling
// MultiMesh (a fixed pool, oldest overwritten — heavy fights never add draw
// calls). Lit, so marks darken in blackout with everything else.
// INSTANCE_CUSTOM.x picks the atlas frame: 0 = scorch, 1 = blood splatter.
uniform sampler2D atlas : filter_linear, repeat_disable;

varying vec3 v_tint;
varying float v_alpha;
varying float v_frame;

void vertex() {
	v_tint = COLOR.rgb;
	v_alpha = COLOR.a;
	v_frame = INSTANCE_CUSTOM.x;
}

void fragment() {
	vec2 uv = vec2(UV.x * 0.5 + v_frame * 0.5, UV.y);
	ALBEDO = v_tint;
	ALPHA = texture(atlas, uv).a * v_alpha;
	ROUGHNESS = 1.0;
}
