class_name LensFlareOverlay
extends Control

const LENS_FLARE_SHADER := preload("res://shaders/lens_flare.gdshader")
const IMPACT_FLASH_FRAMES := 2

static var _noise_texture: ImageTexture = null

var camera: Camera3D = null

var _flare_rect: ColorRect = null
var _impact_wash: ColorRect = null
var _mat: ShaderMaterial = null
var _impact_flash_ticks: int = 0
var _impact_flash_strength: float = 1.0
var _impact_flash_screen: Vector2 = Vector2.ZERO


static func spawn_impact_flash(_world_pos: Vector3, _intensity: float = 1.0) -> void:
	pass


static func _get_noise_texture() -> ImageTexture:
	if _noise_texture != null:
		return _noise_texture
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RF)
	for y in size:
		for x in size:
			img.set_pixel(x, y, Color(randf(), 0.0, 0.0, 1.0))
	_noise_texture = ImageTexture.create_from_image(img)
	return _noise_texture


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_flare_rect = ColorRect.new()
	_flare_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flare_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flare_rect.color = Color.WHITE
	add_child(_flare_rect)

	_impact_wash = ColorRect.new()
	_impact_wash.name = "ImpactWash"
	_impact_wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_impact_wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_impact_wash.visible = false
	_impact_wash.z_index = 2
	var wash_mat := CanvasItemMaterial.new()
	wash_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_impact_wash.material = wash_mat
	_impact_wash.color = Color(2.4, 2.05, 1.55, 1.0)
	add_child(_impact_wash)

	_mat = ShaderMaterial.new()
	_mat.shader = LENS_FLARE_SHADER
	_mat.set_shader_parameter("noise_texture", _get_noise_texture())
	_mat.set_shader_parameter("noise_tex_size", Vector2(256.0, 256.0))
	_mat.set_shader_parameter("flare_strength", 0.0)
	_mat.set_shader_parameter("impact_flash", 0.0)
	_flare_rect.material = _mat
	_flare_rect.visible = false


func trigger_impact_flash(world_pos: Vector3, intensity: float = 1.0) -> void:
	var screen_v: Variant = _screen_point(world_pos)
	_impact_flash_screen = screen_v if screen_v != null else size * 0.5
	_impact_flash_strength = clampf(intensity, 0.0, 1.0)
	_impact_flash_ticks = IMPACT_FLASH_FRAMES
	call_deferred("_update_flare")


func _process(_delta: float) -> void:
	_update_flare()


func _screen_point(world_pos: Vector3) -> Variant:
	if camera == null or not is_instance_valid(camera):
		return null
	if camera.is_position_behind(world_pos):
		return null
	var screen := camera.unproject_position(world_pos)
	if size.x <= 1.0 or size.y <= 1.0:
		return null
	if screen.x < -80.0 or screen.y < -80.0 or screen.x > size.x + 80.0 or screen.y > size.y + 80.0:
		return null
	return screen


func _rocket_flare_world_pos(rocket: Node3D) -> Vector3:
	if rocket.has_meta("flare_world_pos"):
		return rocket.get_meta("flare_world_pos")
	if rocket.has_meta("flare_flight_dir"):
		var flight_dir: Vector3 = rocket.get_meta("flare_flight_dir")
		return rocket.global_position - flight_dir * 4.2
	return rocket.global_position


func _rocket_flare_intensity(rocket: Node3D) -> float:
	if rocket.has_meta("flare_intensity"):
		return clampf(float(rocket.get_meta("flare_intensity")), 0.0, 1.0)
	if rocket.has_meta("flare_target_pos") and rocket.has_meta("flare_start_dist"):
		var target: Vector3 = rocket.get_meta("flare_target_pos")
		var start_dist: float = maxf(float(rocket.get_meta("flare_start_dist")), 1.0)
		var remaining: float = rocket.global_position.distance_to(target)
		var closeness := 1.0 - clampf(remaining / start_dist, 0.0, 1.0)
		return closeness * closeness
	return 0.0


func _flashlight_flare_world_pos(light: Node3D) -> Vector3:
	if light.has_meta("flare_world_pos"):
		return light.get_meta("flare_world_pos")
	return light.global_position


func _flashlight_flare_intensity(light: Node3D) -> float:
	if not light.visible:
		return 0.0
	if light.has_meta("flare_intensity"):
		return clampf(float(light.get_meta("flare_intensity")), 0.0, 1.0)
	return 1.0


func _flashlight_flare_strength(light: Node3D, intensity: float) -> float:
	if camera == null or not is_instance_valid(camera):
		return 0.0
	var dist := camera.global_position.distance_to(_flashlight_flare_world_pos(light))
	var dist_falloff := 1.0 - clampf(dist / 42.0, 0.0, 1.0)
	return lerpf(0.08, 0.72, pow(intensity * dist_falloff, 0.55))


func _consider_flare_source(best: Dictionary, world_pos: Vector3, intensity: float, strength: float, tint: Vector3) -> Dictionary:
	if intensity < 0.015:
		return best
	var screen_v: Variant = _screen_point(world_pos)
	if screen_v == null:
		return best
	if intensity >= float(best.get("intensity", -1.0)):
		return {
			"screen": screen_v,
			"strength": strength,
			"tint": tint,
			"intensity": intensity,
		}
	return best


func _pick_inbound_flare() -> Dictionary:
	var best: Dictionary = {}
	for node in get_tree().get_nodes_in_group("air_strike_rockets"):
		if not node is Node3D or not is_instance_valid(node):
			continue
		var rocket := node as Node3D
		var intensity := _rocket_flare_intensity(rocket)
		var strength := lerpf(0.03, 1.05, pow(intensity, 0.65))
		best = _consider_flare_source(
			best,
			_rocket_flare_world_pos(rocket),
			intensity,
			strength,
			Vector3(1.08, 0.88, 0.62),
		)
	for node in get_tree().get_nodes_in_group("flashlight_flares"):
		if not node is Node3D or not is_instance_valid(node):
			continue
		var light := node as Node3D
		var intensity := _flashlight_flare_intensity(light)
		var strength := _flashlight_flare_strength(light, intensity)
		var effective_intensity := intensity * strength
		best = _consider_flare_source(
			best,
			_flashlight_flare_world_pos(light),
			effective_intensity,
			strength,
			Vector3(1.05, 0.98, 0.86),
		)
	return best


func _update_flare() -> void:
	if _mat == null or _flare_rect == null:
		return
	if _impact_flash_ticks > 0:
		var flash_mix := lerpf(0.85, 1.0, _impact_flash_strength)
		_impact_wash.visible = true
		_impact_wash.color = Color(2.4, 2.05, 1.55, 1.0) * flash_mix
		_flare_rect.visible = true
		_mat.set_shader_parameter("sun_position", _impact_flash_screen)
		_mat.set_shader_parameter("flare_strength", lerpf(3.5, 5.5, _impact_flash_strength))
		_mat.set_shader_parameter("impact_flash", 1.0)
		_mat.set_shader_parameter("tint", Vector3(1.4, 1.25, 1.05))
		_impact_flash_ticks -= 1
		return
	if _impact_wash:
		_impact_wash.visible = false
	var source := _pick_inbound_flare()
	if source.is_empty():
		_flare_rect.visible = false
		_mat.set_shader_parameter("flare_strength", 0.0)
		_mat.set_shader_parameter("impact_flash", 0.0)
		return
	_flare_rect.visible = true
	_mat.set_shader_parameter("sun_position", source.get("screen", Vector2.ZERO))
	_mat.set_shader_parameter("flare_strength", float(source.get("strength", 1.0)))
	_mat.set_shader_parameter("impact_flash", 0.0)
	_mat.set_shader_parameter("tint", source.get("tint", Vector3(1.4, 1.0, 0.75)))
