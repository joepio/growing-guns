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

# Called by ColosseumBuilder with the bowl's ring geometry.
func setup(_inner_r: float, _base_y: float, wall_r: float, wall_h: float) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = TV_SHADER

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
