extends Node3D

const Violence = preload("res://scripts/violence.gd")
const DestructibleManager = preload("res://scripts/destructible_manager.gd")

const MARKER_COLOR := Color(1.0, 0.08, 0.04)
const ROCKET_TRAVEL_SECONDS := 2.3
const BLAST_RADIUS := 30.0
const BLAST_DAMAGE := 165.0

var target_pos: Vector3 = Vector3.ZERO
var sky_from: Vector3 = Vector3.ZERO

var _fx_scene: Node = null
var _beam: MeshInstance3D = null
var _beam_mat: StandardMaterial3D = null
var _target_light: OmniLight3D = null
var _pulse: float = 0.0
var _inbound: bool = false
var _rocket: Node3D = null
var _body_mat: StandardMaterial3D = null
var _engine_mat: StandardMaterial3D = null
var _plume_mat: StandardMaterial3D = null
var _plume: MeshInstance3D = null
var _core_plume_mat: StandardMaterial3D = null
var _engine_light: OmniLight3D = null
var _core_light: OmniLight3D = null
var _woosh: AudioStreamPlayer3D = null
var _travel_seconds: float = 0.0
var _travel_elapsed: float = 0.0
var _smoke_tick: float = 0.0
var _flight_tween: Tween = null
var _game: Node = null
var _notify_server: bool = false
var shooter_id: int = 0


func _report_error(step: String, detail: String) -> void:
	push_error("AirStrike.%s: %s" % [step, detail])
	print_stack()


func setup(
	fx_scene: Node,
	p_sky_from: Vector3,
	p_target: Vector3,
	p_shooter_id: int = 0,
	game: Node = null,
	notify_server: bool = false,
) -> void:
	if fx_scene == null or not is_instance_valid(fx_scene):
		_report_error("setup", "fx_scene is null/invalid — laser, audio, and blast VFX cannot spawn")
		queue_free()
		return
	_fx_scene = fx_scene
	sky_from = p_sky_from
	target_pos = p_target
	shooter_id = p_shooter_id
	_game = game
	_notify_server = notify_server
	add_to_group("air_strike_markers")
	_travel_seconds = ROCKET_TRAVEL_SECONDS
	if not _spawn_beam():
		_report_error("setup", "targeting beam failed to spawn")
	if not _spawn_target_light():
		_report_error("setup", "target marker light failed to spawn")
	SFX.mine_plant(target_pos)
	begin_flight(fx_scene, game, notify_server)


func begin_flight(fx_scene: Node, game: Node, notify_server: bool = false) -> void:
	if _inbound:
		return
	_inbound = true
	if fx_scene != null:
		_fx_scene = fx_scene
	if game != null:
		_game = game
	_notify_server = notify_server
	_travel_elapsed = 0.0
	_smoke_tick = 0.0

	_rocket = _build_rocket_visual()
	if _rocket == null:
		_report_error("begin_flight", "rocket visual failed to build")
		_inbound = false
		return
	add_child(_rocket)
	_rocket.global_position = sky_from
	_orient_rocket_nose_first(_rocket, sky_from, target_pos)
	var flare_start_dist := maxf(sky_from.distance_to(target_pos), 1.0)
	_rocket.set_meta("flare_target_pos", target_pos)
	_rocket.set_meta("flare_start_dist", flare_start_dist)
	_rocket.set_meta("flare_intensity", 0.0)

	_woosh = SFX.attach_air_strike_inbound(_rocket, _travel_seconds, false)
	if _flight_tween and _flight_tween.is_valid():
		_flight_tween.kill()
	_flight_tween = create_tween()
	_flight_tween.tween_method(_set_rocket_along_path, 0.0, 1.0, _travel_seconds)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_flight_tween.tween_callback(_on_rocket_impact)


func _set_rocket_along_path(t: float) -> void:
	if not is_instance_valid(_rocket):
		return
	_rocket.global_position = sky_from.lerp(target_pos, t)
	_orient_rocket_nose_first(_rocket, sky_from, target_pos)


func _on_rocket_impact() -> void:
	if not _inbound:
		_report_error("impact", "callback fired while not inbound — explosion skipped")
		return
	_inbound = false
	var blast_color := Color(1.0, 0.45, 0.08)
	var impact_intensity := 1.0
	if is_instance_valid(_rocket):
		impact_intensity = clampf(float(_rocket.get_meta("flare_intensity", 1.0)), 0.85, 1.0)
	var scene := _fx_scene if is_instance_valid(_fx_scene) else get_tree().current_scene
	var local_player: Node = null
	if _game and is_instance_valid(_game) and _game.get("local_player"):
		local_player = _game.local_player
	if _notify_server and _game and is_instance_valid(_game) and _game.has_method("_apply_environment_explosion"):
		_game.call("_apply_environment_explosion", target_pos, BLAST_RADIUS, BLAST_DAMAGE, shooter_id)
	if scene:
		Violence.spawn_bullet_blast(scene, target_pos, BLAST_RADIUS, blast_color, local_player)
		DestructibleManager.apply_blast(target_pos, BLAST_RADIUS * 0.52, BLAST_DAMAGE)
	else:
		_report_error("impact", "no fx scene — explosion VFX/audio skipped")
	_spawn_impact_flare(impact_intensity)
	if is_instance_valid(_rocket):
		_rocket.queue_free()
		_rocket = null
	_finish_strike()


func _spawn_impact_flare(intensity: float) -> void:
	if _game and is_instance_valid(_game) and _game.has_method("flash_air_strike_impact"):
		_game.call("flash_air_strike_impact", target_pos + Vector3.UP * 0.35, intensity)


func _finish_strike() -> void:
	if _flight_tween and _flight_tween.is_valid():
		_flight_tween.kill()
		_flight_tween = null
	if is_instance_valid(_beam):
		_beam.queue_free()
		_beam = null
	if is_instance_valid(_target_light):
		_target_light.queue_free()
		_target_light = null
	if is_instance_valid(_rocket):
		_rocket.queue_free()
		_rocket = null
	if _notify_server and _game and is_instance_valid(_game) and _game.has_method("_air_strike_finished"):
		_game.call("_air_strike_finished")
	queue_free()


func _exit_tree() -> void:
	if _flight_tween and _flight_tween.is_valid():
		_flight_tween.kill()
		_flight_tween = null
	_cleanup_fx()


func _cleanup_fx() -> void:
	if is_instance_valid(_beam):
		_beam.queue_free()
		_beam = null
	if is_instance_valid(_target_light):
		_target_light.queue_free()
		_target_light = null
	if is_instance_valid(_rocket):
		_rocket.queue_free()
		_rocket = null


func _spawn_beam() -> bool:
	if _fx_scene == null:
		return false
	var dist := maxf(sky_from.distance_to(target_pos), 0.5)
	_beam = MeshInstance3D.new()
	_beam.name = "StrikeBeam"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.12, 0.12, dist)
	_beam.mesh = mesh
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.albedo_color = Color(MARKER_COLOR.r, MARKER_COLOR.g, MARKER_COLOR.b, 0.72)
	_beam_mat.emission_enabled = true
	_beam_mat.emission = MARKER_COLOR
	_beam_mat.emission_energy_multiplier = 9.0
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam.material_override = _beam_mat
	_fx_scene.add_child(_beam)
	_beam.global_position = sky_from.lerp(target_pos, 0.5)
	_orient_along_path(_beam, sky_from, target_pos)
	_beam.visible = true
	return is_instance_valid(_beam) and _beam.is_inside_tree()


func _spawn_target_light() -> bool:
	if _fx_scene == null:
		return false
	_target_light = OmniLight3D.new()
	_target_light.name = "StrikeTargetLight"
	_target_light.light_color = MARKER_COLOR
	_target_light.light_energy = 6.0
	_target_light.omni_range = 7.0
	_fx_scene.add_child(_target_light)
	_target_light.global_position = target_pos + Vector3.UP * 0.35
	return true


func _orient_along_path(node: Node3D, from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	if dir.length_squared() < 0.0001:
		return
	if absf(dir.dot(Vector3.UP)) > 0.99:
		node.look_at(to, Vector3.RIGHT)
	else:
		node.look_at(to, Vector3.UP)


func _orient_rocket_nose_first(node: Node3D, from: Vector3, to: Vector3) -> void:
	# Face along the flight direction (from→to). Aim at a point offset from the
	# node's own position rather than at `to` directly: on a straight lerp path
	# the node reaches `to` on the final frame, and look_at(to) from there is
	# degenerate ("origin and target in same position"). Offsetting by the unit
	# direction is identical for all earlier frames and never degenerates.
	var dir := (to - from).normalized()
	if dir.length_squared() < 0.0001:
		return
	var side := Vector3.UP
	if absf(dir.dot(side)) > 0.99:
		side = Vector3.RIGHT
	node.look_at(node.global_position + dir, side)
	node.rotate_object_local(Vector3.RIGHT, -PI * 0.5)


func _build_rocket_visual() -> Node3D:
	var root := Node3D.new()
	root.name = "StrikeRocket"
	root.add_to_group("air_strike_rockets")

	var body := MeshInstance3D.new()
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 0.22
	body_mesh.bottom_radius = 0.28
	body_mesh.height = 3.2
	body.mesh = body_mesh
	_body_mat = StandardMaterial3D.new()
	_body_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_body_mat.albedo_color = Color(0.95, 0.72, 0.38)
	_body_mat.emission_enabled = true
	_body_mat.emission = Color(1.0, 0.55, 0.12)
	_body_mat.emission_energy_multiplier = 18.0
	body.material_override = _body_mat
	root.add_child(body)

	var nose := MeshInstance3D.new()
	var nose_mesh := CylinderMesh.new()
	nose_mesh.top_radius = 0.07
	nose_mesh.bottom_radius = 0.22
	nose_mesh.height = 0.8
	nose.mesh = nose_mesh
	nose.position = Vector3(0.0, 2.0, 0.0)
	var nose_mat := StandardMaterial3D.new()
	nose_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	nose_mat.albedo_color = Color(1.0, 0.96, 0.88)
	nose_mat.emission_enabled = true
	nose_mat.emission = Color(1.0, 0.95, 0.82)
	nose_mat.emission_energy_multiplier = 22.0
	nose.material_override = nose_mat
	root.add_child(nose)

	var engine := MeshInstance3D.new()
	engine.name = "EngineCore"
	var engine_mesh := CylinderMesh.new()
	engine_mesh.top_radius = 0.34
	engine_mesh.bottom_radius = 0.16
	engine_mesh.height = 0.75
	engine.mesh = engine_mesh
	engine.position = Vector3(0.0, -1.95, 0.0)
	_engine_mat = StandardMaterial3D.new()
	_engine_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_engine_mat.albedo_color = Color(1.0, 0.82, 0.28)
	_engine_mat.emission_enabled = true
	_engine_mat.emission = Color(1.0, 0.82, 0.35)
	_engine_mat.emission_energy_multiplier = 75.0
	_engine_mat.disable_fog = true
	engine.material_override = _engine_mat
	root.add_child(engine)

	var plume := MeshInstance3D.new()
	plume.name = "EnginePlume"
	var plume_mesh := CylinderMesh.new()
	plume_mesh.top_radius = 0.82
	plume_mesh.bottom_radius = 0.18
	plume_mesh.height = 6.8
	plume.mesh = plume_mesh
	plume.position = Vector3(0.0, -6.2, 0.0)
	_plume_mat = StandardMaterial3D.new()
	_plume_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_plume_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_plume_mat.albedo_color = Color(1.0, 0.62, 0.12, 0.72)
	_plume_mat.emission_enabled = true
	_plume_mat.emission = Color(1.0, 0.58, 0.12)
	_plume_mat.emission_energy_multiplier = 110.0
	_plume_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_plume_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_plume_mat.disable_fog = true
	plume.material_override = _plume_mat
	root.add_child(plume)
	_plume = plume

	var core_plume := MeshInstance3D.new()
	core_plume.name = "EngineCorePlume"
	var core_plume_mesh := CylinderMesh.new()
	core_plume_mesh.top_radius = 0.34
	core_plume_mesh.bottom_radius = 0.06
	core_plume_mesh.height = 4.8
	core_plume.mesh = core_plume_mesh
	core_plume.position = Vector3(0.0, -4.6, 0.0)
	_core_plume_mat = StandardMaterial3D.new()
	_core_plume_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core_plume_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_core_plume_mat.albedo_color = Color(1.0, 0.96, 0.82, 0.82)
	_core_plume_mat.emission_enabled = true
	_core_plume_mat.emission = Color(1.0, 0.94, 0.78)
	_core_plume_mat.emission_energy_multiplier = 180.0
	_core_plume_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_core_plume_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_core_plume_mat.disable_fog = true
	core_plume.material_override = _core_plume_mat
	root.add_child(core_plume)

	var halo_plume := MeshInstance3D.new()
	halo_plume.name = "EngineHaloPlume"
	var halo_mesh := CylinderMesh.new()
	halo_mesh.top_radius = 1.35
	halo_mesh.bottom_radius = 0.28
	halo_mesh.height = 9.0
	halo_plume.mesh = halo_mesh
	halo_plume.position = Vector3(0.0, -7.0, 0.0)
	var halo_mat := StandardMaterial3D.new()
	halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	halo_mat.albedo_color = Color(1.0, 0.48, 0.08, 0.14)
	halo_mat.emission_enabled = true
	halo_mat.emission = Color(1.0, 0.42, 0.06)
	halo_mat.emission_energy_multiplier = 70.0
	halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	halo_mat.disable_fog = true
	halo_plume.material_override = halo_mat
	root.add_child(halo_plume)

	_core_light = OmniLight3D.new()
	_core_light.name = "EngineCoreLight"
	_core_light.light_color = Color(1.0, 0.82, 0.42)
	_core_light.light_energy = 50.0
	_core_light.omni_range = 72.0
	_core_light.position = Vector3(0.0, -2.0, 0.0)
	root.add_child(_core_light)

	_engine_light = OmniLight3D.new()
	_engine_light.name = "EngineLight"
	_engine_light.light_color = Color(1.0, 0.62, 0.16)
	_engine_light.light_energy = 70.0
	_engine_light.omni_range = 155.0
	_engine_light.position = Vector3(0.0, -3.0, 0.0)
	root.add_child(_engine_light)

	return root


func _process(delta: float) -> void:
	_pulse += delta
	var pulse := sin(_pulse * (14.0 if _inbound else 6.2))
	if _beam_mat:
		var beam_energy := (10.0 + pulse * 3.0) if _inbound else (8.0 + pulse * 2.0)
		_beam_mat.emission_energy_multiplier = beam_energy
	if _target_light and not _inbound:
		_target_light.light_energy = 5.0 + pulse * 1.5
	if not _inbound:
		return

	_travel_elapsed += delta
	var u := clampf(_travel_elapsed / maxf(_travel_seconds, 0.001), 0.0, 1.0)
	var approach := u * u
	if _engine_mat:
		_engine_mat.emission_energy_multiplier = lerpf(75.0, 165.0, approach) + pulse * 12.0
	var dist_boost := _engine_distance_boost()
	if _plume_mat:
		_plume_mat.emission_energy_multiplier = (lerpf(110.0, 240.0, approach) + pulse * 16.0) * dist_boost
		_plume_mat.albedo_color = Color(1.0, 0.62, 0.12, lerpf(0.55, 0.82, approach))
	if _core_plume_mat:
		_core_plume_mat.emission_energy_multiplier = (lerpf(180.0, 360.0, approach) + pulse * 20.0) * dist_boost
	if _plume:
		_plume.scale = Vector3(1.0, lerpf(0.85, 2.4, approach), 1.0)
	var light_boost := lerpf(1.0, 1.12, clampf(dist_boost - 1.0, 0.0, 1.0))
	if _core_light:
		_core_light.light_energy = (lerpf(50.0, 105.0, approach) + pulse * 10.0) * light_boost
	if _engine_light:
		_engine_light.light_energy = (lerpf(70.0, 148.0, approach) + pulse * 12.0) * light_boost
	if is_instance_valid(_rocket):
		var start_dist: float = maxf(float(_rocket.get_meta("flare_start_dist", sky_from.distance_to(target_pos))), 1.0)
		var remaining: float = _rocket.global_position.distance_to(target_pos)
		var closeness := 1.0 - clampf(remaining / start_dist, 0.0, 1.0)
		var intensity := closeness * closeness
		_rocket.set_meta("flare_intensity", intensity)
		var flight_dir := (target_pos - sky_from).normalized()
		_rocket.set_meta("flare_flight_dir", flight_dir)
		var tail := _rocket.global_position - flight_dir * 5.2
		_rocket.set_meta("flare_world_pos", tail)
	if is_instance_valid(_rocket) and _fx_scene:
		_smoke_tick += delta
		if _smoke_tick >= 0.016:
			_smoke_tick = 0.0
			var flight_dir := (target_pos - sky_from).normalized()
			var spread := Vector3(
				randf_range(-1.0, 1.0),
				randf_range(-0.15, 0.25),
				randf_range(-1.0, 1.0),
			).normalized()
			var tail_base := _rocket.global_position - flight_dir * randf_range(3.6, 5.8)
			for _burst in 2:
				var tail := tail_base + spread * randf_range(0.08, 0.42)
				Violence.spawn_exhaust_smoke(
					_fx_scene,
					tail,
					randf_range(0.45, 0.85),
					(-flight_dir * 0.35 + Vector3.UP * 0.55 + spread * 0.18).normalized(),
				)
	if _woosh:
		var swell := lerpf(0.62, 1.0, u * u)
		_woosh.volume_db = SFX.air_strike_inbound_db + linear_to_db(swell)
	# Safety net if the flight tween callback is dropped (tree pause, early free, etc.).
	if _travel_elapsed >= _travel_seconds + 0.05:
		_on_rocket_impact()


func _viewer_camera() -> Camera3D:
	if _game and is_instance_valid(_game):
		var local_player: Node = _game.get("local_player")
		if local_player and is_instance_valid(local_player):
			var cam := local_player.get_node_or_null("Camera") as Camera3D
			if cam:
				return cam
	var vp := get_viewport()
	if vp:
		return vp.get_camera_3d()
	return null


func _engine_distance_boost() -> float:
	if not is_instance_valid(_rocket):
		return 1.0
	var dist_to_cam := 280.0
	var cam := _viewer_camera()
	if cam:
		dist_to_cam = cam.global_position.distance_to(_rocket.global_position)
	# Brighten when far, but never inflate mesh size into obvious shapes.
	return clampf(dist_to_cam / 180.0, 1.0, 1.28)
