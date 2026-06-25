class_name RetroFilter
extends RefCounted

const MenuHelpers = preload("res://scripts/menu_helpers.gd")

# Full-screen post-process layer. Sits above HUD/menus; loading overlays use 100+.
const LAYER := 90

static var _shader: Shader = null


static func build(parent: Node) -> Dictionary:
	var layer := CanvasLayer.new()
	layer.name = "RetroLayer"
	layer.layer = LAYER
	parent.add_child(layer)
	var overlay := ColorRect.new()
	overlay.name = "RetroOverlay"
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := _make_material()
	overlay.material = material
	layer.add_child(overlay)
	apply(layer, material, MenuHelpers.retro_enabled)
	return {"layer": layer, "material": material, "overlay": overlay}


static func apply(layer: CanvasLayer, material: ShaderMaterial, enabled: bool) -> void:
	if material:
		material.set_shader_parameter("dither_strength", 1.0 if enabled else 0.0)
		material.set_shader_parameter("fisheye_strength", 1.0 if enabled else 0.0)
		material.set_shader_parameter("cursor_visible", 0.0)
	if layer:
		layer.visible = enabled


static func _make_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _shader_code()
	return mat


static func _shader_code() -> Shader:
	if _shader:
		return _shader
	var shader := Shader.new()
	shader.code = "
		shader_type canvas_item;
		uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
		uniform vec2 mouse_uv = vec2(-1.0);
		uniform float cursor_visible = 0.0;
		uniform float fisheye_strength = 1.0;
		uniform float dither_strength = 1.0;

		const float bayer[16] = {
			0.0/16.0, 8.0/16.0, 2.0/16.0, 10.0/16.0,
			12.0/16.0, 4.0/16.0, 14.0/16.0, 6.0/16.0,
			3.0/16.0, 11.0/16.0, 1.0/16.0, 9.0/16.0,
			15.0/16.0, 7.0/16.0, 13.0/16.0, 5.0/16.0
		};

		void fragment() {
			vec2 uv = SCREEN_UV;
			vec2 centered_uv = uv - 0.5;
			float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
			vec2 aspect_uv = centered_uv * vec2(aspect, 1.0);
			float dist = length(aspect_uv);
			float distortion = 0.15 * fisheye_strength;
			float max_dist_sq = dot(vec2(0.5 * aspect, 0.5), vec2(0.5 * aspect, 0.5));
			float zoom = mix(1.0, 0.995 / (1.0 + 0.15 * max_dist_sq), fisheye_strength);
			uv = 0.5 + centered_uv * zoom * (1.0 + distortion * dist * dist);

			vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
			int p_size = max(1, int(round(res.y / 1080.0)));
			uv = (floor(uv * res / float(p_size)) + 0.5) * float(p_size) / res;
			vec2 uv_min = SCREEN_PIXEL_SIZE * 0.5;
			vec2 uv_max = vec2(1.0) - uv_min;

			float amount = 0.001 * (dist * dist);
			float r = texture(screen_texture, clamp(uv + vec2(amount, 0.0), uv_min, uv_max)).r;
			float g = texture(screen_texture, clamp(uv, uv_min, uv_max)).g;
			float b = texture(screen_texture, clamp(uv - vec2(amount, 0.0), uv_min, uv_max)).b;
			vec3 color = vec3(r, g, b);

			vec3 bleed = vec3(0.0);
			vec2 b_offset = SCREEN_PIXEL_SIZE * float(p_size) * 1.5;
			bleed += texture(screen_texture, clamp(uv + vec2(b_offset.x, b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(-b_offset.x, b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(b_offset.x, -b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(-b_offset.x, -b_offset.y), uv_min, uv_max)).rgb;
			color += bleed * 0.15;

			ivec2 p = ivec2(FRAGCOORD.xy / float(p_size));
			float threshold = (bayer[(p.x % 4) * 4 + (p.y % 4)] - 0.5) * 0.5 * dither_strength;

			float levels = 32.0;
			float vignette = clamp(1.0 - dist * 1.4, 0.0, 1.0);
			color = floor(color * levels + threshold + 0.5) / levels;
			color *= mix(0.7, 1.0, vignette);

			if (cursor_visible > 0.5) {
				vec2 d = (uv - mouse_uv) * res;
				bool arrow = d.x >= 0.0 && d.y >= 0.0 && (d.x + d.y) <= 12.0;
				bool outline = d.x >= -1.5 && d.y >= -1.5 && (d.x + d.y) <= 13.5 && !arrow;
				if (arrow) color = vec3(1.0);
				else if (outline) color = vec3(0.05);
			}

			COLOR.rgb = color;
			COLOR.a = 1.0;
		}
	"
	_shader = shader
	return _shader
