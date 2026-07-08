class_name StadiumTV
extends Node3D

# Stadium jumbotrons: four screens on the colosseum's outer wall showing a
# live broadcast feed of the arena. Built by ColosseumBuilder.build().
#
# Cost discipline (measured, see AGENTS.md perf notes): all screens share ONE
# ShaderMaterial; the feed is ONE 384x216 SubViewport whose camera slowly
# orbits the arena like a broadcast crane. On this class of scene the extra
# viewport doubles draw calls but doesn't move frame time; on machines where
# it would, the PerfGovernor L1 shed (casings_enabled == false) switches the
# feed off and the screens fall back to shader-drawn color bars.

const TV_SHADER := preload("res://shaders/stadium_tv.gdshader")
const TV_COUNT := 4
const FEED_SIZE := Vector2i(384, 216)
const SCREEN_W := 26.0
const SCREEN_H := SCREEN_W * 9.0 / 16.0
const TILT_DOWN := 0.22          # radians the screens pitch toward the floor
const ORBIT_SPEED := 0.05        # rad/s broadcast-crane orbit
const GOV_CHECK_INTERVAL := 0.5

var _sub: SubViewport = null
var _cam: Camera3D = null
var _mat: ShaderMaterial = null
var _orbit_r: float = 30.0
var _orbit_h: float = 14.0
var _orbit_t: float = 0.0
var _feed_on: bool = false
var _gov_timer: float = 0.0

# Called by ColosseumBuilder with the bowl's ring geometry.
func setup(inner_r: float, base_y: float, wall_r: float, wall_h: float) -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = TV_SHADER

	# Broadcast camera path: high crane orbit looking DOWN at the castle — a
	# steep angle keeps the arena floor as the backdrop; a shallow one filled
	# the frame with hazy far-side stands and the feed read as fog.
	_orbit_r = inner_r * 0.32
	_orbit_h = base_y + 16.0
	_sub = SubViewport.new()
	_sub.size = FEED_SIZE
	_sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_sub.positional_shadow_atlas_size = 0
	add_child(_sub)
	_cam = Camera3D.new()
	_cam.fov = 50.0  # tight on the castle — wide angles fill the frame with haze
	_sub.add_child(_cam)
	_cam.make_current()
	_update_cam_pose()
	_mat.set_shader_parameter("feed_tex", _sub.get_texture())
	_set_feed(true)

	# Screens: crowning the outer wall (top edge pokes above the rim like
	# real stadium boards), evenly spaced, tilted at the floor.
	var screen_y: float = wall_h - SCREEN_H * 0.32
	var screen_r: float = wall_r - 1.35
	for i in TV_COUNT:
		var ang := TAU * (float(i) + 0.5) / float(TV_COUNT)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var screen := MeshInstance3D.new()
		screen.name = "Screen%d" % i
		var quad := QuadMesh.new()
		quad.size = Vector2(SCREEN_W, SCREEN_H)
		screen.mesh = quad
		screen.material_override = _mat
		screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		screen.position = dir * screen_r + Vector3(0.0, screen_y, 0.0)
		add_child(screen)
		# QuadMesh faces +Z; -Z at an outward point leaves +Z facing the
		# arena. Then pitch the face down toward the floor seats.
		screen.look_at(screen.global_position + dir, Vector3.UP)
		screen.rotate_object_local(Vector3.RIGHT, TILT_DOWN)
		# Slab housing behind the screen so it reads mounted, not floating.
		var housing := MeshInstance3D.new()
		var hbox := BoxMesh.new()
		# Extends below the screen so the raised board reads anchored into
		# the wall instead of floating above the rim.
		hbox.size = Vector3(SCREEN_W + 1.2, SCREEN_H + 5.0, 0.8)
		housing.mesh = hbox
		var hmat := StandardMaterial3D.new()
		hmat.albedo_color = Color(0.09, 0.09, 0.11)
		hmat.roughness = 0.85
		housing.material_override = hmat
		housing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		screen.add_child(housing)
		housing.position = Vector3(0.0, -1.9, -0.45)

func _process(delta: float) -> void:
	if _feed_on:
		_orbit_t += delta * ORBIT_SPEED
		_update_cam_pose()
	# Governor poll: ride the L1 shed — if casings are off, this machine has
	# no business rendering a vanity viewport either.
	_gov_timer -= delta
	if _gov_timer <= 0.0:
		_gov_timer = GOV_CHECK_INTERVAL
		var want: bool = PerfGovernor.casings_enabled if PerfGovernor else true
		if want != _feed_on:
			_set_feed(want)

func _set_feed(on: bool) -> void:
	_feed_on = on
	if _sub:
		_sub.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED)
	if _mat:
		_mat.set_shader_parameter("feed_on", 1.0 if on else 0.0)

func _update_cam_pose() -> void:
	if _cam == null:
		return
	_cam.position = Vector3(cos(_orbit_t) * _orbit_r, _orbit_h, sin(_orbit_t) * _orbit_r)
	_cam.look_at(Vector3(0.0, 1.5, 0.0), Vector3.UP)
