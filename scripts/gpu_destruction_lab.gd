extends Node3D

# GPU-accelerated stateful destruction — MVP.
#
# The damage STATE lives entirely on the GPU: a SubViewport render target that is
# never cleared (CLEAR_MODE_ONCE -> NEVER) and never read back to the CPU. On each
# hit the CPU issues ONE additive "splat" draw into it (a sparse event); the GPU
# accumulates. The 3D wall's shader samples that texture for crater displacement +
# scorch. No GPU->CPU readback, no per-chunk CPU state — the dense damage field is
# pure VRAM.
#
# Interactive: godot --path . res://scenes/gpu_destruction_lab.tscn  (click to hit)
# Capture:     godot --path . res://scenes/gpu_destruction_lab.tscn -- --capture out.png

const DMG_SIZE := 1024
const WALL_SIZE := Vector2(12.0, 8.0)
const CAPTURE_SIZE := Vector2i(1280, 720)

var _viewport: SubViewport
var _splatter: Splatter
var _wall_mat: ShaderMaterial
var _camera: Camera3D
var _brush: Texture2D


# 2D canvas drawn INTO the damage SubViewport. Each redraw stamps the queued
# splats additively; with CLEAR_MODE_NEVER the target keeps accumulating.
class Splatter:
	extends Node2D
	var pending: Array = []
	var brush: Texture2D
	var tex_size: float = 1024.0

	func _draw() -> void:
		for s: Dictionary in pending:
			var c: Vector2 = (s["uv"] as Vector2) * tex_size
			var r: float = float(s["radius"]) * tex_size
			var st: float = float(s["strength"])
			draw_texture_rect(
				brush, Rect2(c - Vector2(r, r), Vector2(r * 2.0, r * 2.0)),
				false, Color(st, st, st, 1.0))
		pending.clear()


func _ready() -> void:
	_brush = _make_brush()
	_build_world()
	var cap := _cli_capture_path()
	if not cap.is_empty():
		await _run_capture(cap)


# Soft radial brush: white with a squared radial alpha falloff, stamped additively.
func _make_brush() -> Texture2D:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var p := Vector2(float(x) / float(n - 1) - 0.5, float(y) / float(n - 1) - 0.5)
			var d := p.length() * 2.0
			# Sharp core = the hole/crater; faint wide halo = the zone cracks fan into.
			var core := clampf(1.0 - d * 1.7, 0.0, 1.0)
			core = core * core
			var halo := clampf(1.0 - d, 0.0, 1.0)
			halo = halo * halo * 0.22
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, maxf(core, halo)))
	return ImageTexture.create_from_image(img)


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.42, 0.48)
	env.ambient_light_energy = 0.65
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.93, 0.82)
	key.light_energy = 1.9
	key.rotation_degrees = Vector3(-34.0, 32.0, 0.0)
	add_child(key)

	# --- damage accumulation buffer (GPU-resident, never read back) ---
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(DMG_SIZE, DMG_SIZE)
	_viewport.transparent_bg = false
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_viewport)
	_splatter = Splatter.new()
	_splatter.brush = _brush
	_splatter.tex_size = float(DMG_SIZE)
	var cmat := CanvasItemMaterial.new()
	cmat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_splatter.material = cmat
	_viewport.add_child(_splatter)

	# --- wall: high-subdivision plane sampling the damage buffer ---
	var pm := PlaneMesh.new()
	pm.orientation = PlaneMesh.FACE_Z
	pm.size = WALL_SIZE
	pm.subdivide_width = 200
	pm.subdivide_depth = 130
	var wall := MeshInstance3D.new()
	wall.mesh = pm
	_wall_mat = ShaderMaterial.new()
	_wall_mat.shader = preload("res://shaders/gpu_damage_wall.gdshader")
	_wall_mat.set_shader_parameter("damage_tex", _viewport.get_texture())
	_wall_mat.set_shader_parameter("dmg_size", float(DMG_SIZE))
	wall.material_override = _wall_mat
	add_child(wall)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 0.0, 11.0)
	_camera.fov = 52.0
	add_child(_camera)
	_camera.look_at(Vector3.ZERO, Vector3.UP)


# Queue a hit and trigger ONE viewport render so the GPU accumulates it.
func splat(uv: Vector2, radius: float, strength: float) -> void:
	_splatter.pending.append({"uv": uv, "radius": radius, "strength": strength})
	_splatter.queue_redraw()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


const BASE_RADIUS := 0.022
const BASE_STRENGTH := 0.5


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		var dmg := 0.0
		if mb.button_index == MOUSE_BUTTON_LEFT:
			dmg = 1.0          # default pistol shot
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			dmg = 3.0          # heavy hit
		if dmg > 0.0:
			var uv := _screen_to_wall_uv(mb.position)
			if uv.x >= 0.0:
				_fire(uv, dmg)


# A hit of `dmg` units (1.0 = pistol). More damage digs a bigger, deeper hole.
func _fire(uv: Vector2, dmg: float) -> void:
	var radius := BASE_RADIUS * pow(dmg, 0.45)
	var strength := BASE_STRENGTH * clampf(0.7 + 0.3 * dmg, 0.0, 1.4)
	splat(uv, radius, strength)


# Ray from the camera through the screen point, intersected with the wall plane.
func _screen_to_wall_uv(screen_pos: Vector2) -> Vector2:
	var o := _camera.project_ray_origin(screen_pos)
	var d := _camera.project_ray_normal(screen_pos)
	if absf(d.z) < 0.0001:
		return Vector2(-1.0, -1.0)
	var t := -o.z / d.z
	if t < 0.0:
		return Vector2(-1.0, -1.0)
	var hit := o + d * t
	var u := hit.x / WALL_SIZE.x + 0.5
	var v := 0.5 - hit.y / WALL_SIZE.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return Vector2(-1.0, -1.0)
	return Vector2(u, v)


func _cli_capture_path() -> String:
	var args := OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] == "--capture" and i + 1 < args.size():
			return String(args[i + 1])
	return ""


func _run_capture(path: String) -> void:
	DisplayServer.window_set_size(CAPTURE_SIZE)
	get_viewport().size = CAPTURE_SIZE
	# Oblique angle so vertex displacement shows as real geometry in the profile.
	_camera.position = Vector3(6.5, 0.5, 7.0)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	# Top row: pistol shots (small holes). Bottom row: 3x hits (bigger holes).
	for i in 4:
		_fire(Vector2(0.24 + float(i) * 0.17, 0.32), 1.0)
		await get_tree().process_frame
		await get_tree().process_frame
	for i in 4:
		_fire(Vector2(0.24 + float(i) * 0.17, 0.66), 3.0)
		await get_tree().process_frame
		await get_tree().process_frame
	# ...and a sustained cluster of pistol hits that digs a deep, scorched crater.
	for i in 10:
		var jitter := Vector2(randf() - 0.5, randf() - 0.5) * 0.05
		_fire(Vector2(0.5, 0.5) + jitter, 1.0)
		await get_tree().process_frame
	for _i in 8:
		await get_tree().process_frame
	RenderingServer.force_draw(true)
	await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		push_error("GpuDestructionLab: empty capture")
		get_tree().quit(1)
		return
	if not path.is_absolute_path():
		path = ProjectSettings.globalize_path("res://").path_join(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	print("GpuDestructionLab captured: ", path)
	get_tree().quit()
