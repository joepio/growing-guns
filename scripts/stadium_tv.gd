class_name StadiumTV
extends Node3D

# Stadium jumbotrons: four screens above the colosseum's outer wall showing
# the "broadcast". Built by ColosseumBuilder.build().
#
# The feed costs nothing: the shader samples the viewer's own previous frame
# via hint_screen_texture (the main viewport's shared per-frame screen copy),
# so there is no second scene render, no SubViewport, no extra draw calls —
# each player sees their own POV up on the stadium screens, which is exactly
# what the MORE ROUNDS! broadcast would show. All screens share ONE
# ShaderMaterial; this node is pure static set dressing after setup().

const TV_SHADER := preload("res://shaders/stadium_tv.gdshader")
const TV_COUNT := 4
const SCREEN_W := 26.0
const SCREEN_H := SCREEN_W * 9.0 / 16.0
const TILT_DOWN := 0.22  # radians the screens pitch toward the floor
# Broadcast programming, looped: the viewer's own POV (free), a crowd
# closeup from a small SubViewport (near-free: the crowd is ONE MultiMesh,
# and the viewport only updates during its segment), and sponsor breaks
# (slogans shared with the perimeter boards — see ad_ring.gd).
const PROGRAM: Array = [["live", 12.0], ["crowd", 5.0], ["live", 12.0], ["ad", 5.0]]
const FEED_SIZE := Vector2i(384, 216)

var _mat: ShaderMaterial = null
var _ad_labels: Array[Label3D] = []
var _ad_index: int = 0
var _program_i: int = 0
var _timer: float = 12.0
var _sub: SubViewport = null
var _crowd_cam: Camera3D = null
var _inner_r: float = 50.0
var _base_y: float = 12.0

# Called by ColosseumBuilder with the bowl's ring geometry.
func setup(inner_r: float, base_y: float, wall_r: float, wall_h: float) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = TV_SHADER
	_mat = mat
	_inner_r = inner_r
	_base_y = base_y
	# Crowd-cam viewport: disabled except during its program segment.
	_sub = SubViewport.new()
	_sub.size = FEED_SIZE
	_sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_sub.positional_shadow_atlas_size = 0
	add_child(_sub)
	_crowd_cam = Camera3D.new()
	_crowd_cam.fov = 32.0  # tight closeup framing
	_sub.add_child(_crowd_cam)
	_crowd_cam.make_current()
	mat.set_shader_parameter("feed_tex", _sub.get_texture())

	# Screens: raised well above the rim like real stadium boards — the
	# bottom edge must clear the canopy ring (wall_h + ~0.6) or the roof
	# blocks the lower third of the picture from the arena floor.
	var screen_y: float = wall_h + SCREEN_H * 0.62
	var screen_r: float = wall_r - 1.35
	for i in TV_COUNT:
		# Side midpoints of the squircle bowl (scale 1.0 there, so wall_r
		# aligns with the flat wall face); the corners belong to the
		# floodlight towers.
		var ang := TAU * float(i) / float(TV_COUNT)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var screen := MeshInstance3D.new()
		screen.name = "Screen%d" % i
		var quad := QuadMesh.new()
		quad.size = Vector2(SCREEN_W, SCREEN_H)
		screen.mesh = quad
		screen.material_override = mat
		screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		screen.position = dir * screen_r + Vector3(0.0, screen_y, 0.0)
		add_child(screen)
		# QuadMesh faces +Z; -Z at an outward point leaves +Z facing the
		# arena. Then pitch the face down toward the floor seats.
		screen.look_at(screen.global_position + dir, Vector3.UP)
		screen.rotate_object_local(Vector3.RIGHT, TILT_DOWN)
		# Ad-break slogan, floating just in front of the picture.
		var ad_lbl := Label3D.new()
		ad_lbl.pixel_size = 0.045
		ad_lbl.font_size = 72
		ad_lbl.outline_size = 14
		ad_lbl.width = SCREEN_W / 0.045 * 0.9
		ad_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		ad_lbl.position = Vector3(0.0, 0.6, 0.4)
		ad_lbl.visible = false
		screen.add_child(ad_lbl)
		_ad_labels.append(ad_lbl)
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
		# Mount legs down to the roof line. Their tops stop BELOW the screen's
		# bottom edge — the tilted screen leans its top back past vertical, so
		# taller legs visibly cross the picture from the arena floor.
		var tangent := Vector3(-sin(ang), 0.0, cos(ang))
		var leg_top: float = screen_y - SCREEN_H * 0.5 - 0.4
		for side in [-1.0, 1.0]:
			var leg := MeshInstance3D.new()
			var lbox := BoxMesh.new()
			lbox.size = Vector3(0.9, 16.0, 0.9)
			leg.mesh = lbox
			leg.material_override = hmat
			leg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			leg.position = dir * (screen_r + 0.3) + tangent * side * SCREEN_W * 0.3 \
				+ Vector3(0.0, leg_top - 8.0, 0.0)
			add_child(leg)

func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_program_i = (_program_i + 1) % PROGRAM.size()
	var segment: Array = PROGRAM[_program_i]
	_timer = float(segment[1])
	var kind := str(segment[0])
	_mat.set_shader_parameter("ad_mode", 1.0 if kind == "ad" else 0.0)
	_mat.set_shader_parameter("feed_src", 1.0 if kind == "crowd" else 0.0)
	_sub.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if kind == "crowd" else SubViewport.UPDATE_DISABLED)
	for lbl in _ad_labels:
		lbl.visible = kind == "ad"
	match kind:
		"crowd":
			_aim_crowd_cam()
		"ad":
			var ad: Array = AdRing.ADS[_ad_index % AdRing.ADS.size()]
			_ad_index += 1
			var col: Color = ad[1]
			_mat.set_shader_parameter("ad_col_a", Vector3(col.r, col.g, col.b) * 0.35)
			_mat.set_shader_parameter("ad_col_b", Vector3(col.r, col.g, col.b))
			for lbl in _ad_labels:
				lbl.text = str(ad[0])

# Crowd segment variants: a single blocky fan filling the frame (using REAL
# seat positions from the crowd controller, so we never frame an empty gap),
# or a wider section of seating.
func _aim_crowd_cam() -> void:
	var crowd: Node = get_parent().get_node_or_null("CrowdController")
	if crowd != null and randf() < 0.6:
		var seats: PackedVector3Array = crowd.get("_positions")
		if seats != null and not seats.is_empty():
			var seat: Vector3 = seats[randi() % seats.size()]
			var inward := -Vector3(seat.x, 0.0, seat.z).normalized()
			_crowd_cam.fov = 24.0
			_crowd_cam.position = seat + inward * 3.4 + Vector3(0.0, 1.7, 0.0)
			_crowd_cam.look_at(seat + Vector3(0.0, 1.0, 0.0), Vector3.UP)
			return
	# Section shot: a fresh patch of fans from inside the bowl.
	var ang := randf() * TAU
	var dir := Vector3(cos(ang), 0.0, sin(ang))
	var row_frac := randf_range(0.2, 0.7)
	var seat_r := _inner_r + 18.0 * 2.2 * row_frac  # ColosseumBuilder ROWS/ROW_DEPTH
	var seat_y := _base_y + 18.0 * 1.4 * row_frac
	_crowd_cam.fov = 32.0
	_crowd_cam.position = dir * (_inner_r * 0.7) + Vector3(0.0, seat_y + 3.0, 0.0)
	_crowd_cam.look_at(dir * seat_r + Vector3(0.0, seat_y + 1.0, 0.0), Vector3.UP)
