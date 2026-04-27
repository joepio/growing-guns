extends RigidBody3D

const FUSE := 4.0                # fallback if the grenade somehow never touches anything
const ARM_DELAY := 0.04          # ignore contacts for this long after spawn (just enough to clear the muzzle)
const RADIUS := 6.0
const MAX_DAMAGE := 100
const MIN_DAMAGE := 10
const SHAKE_RADIUS := 22.0
const SHAKE_STRENGTH := 0.16     # max camera-shake amplitude (m) at the epicenter
const VFX_TRANSIENT_LIGHTS := false
const MINE_TRIGGER_RADIUS := 1.25
const MINE_LIFETIME := 10.0        # mines quietly expire if nobody wanders in
const SPEED_OF_SOUND := 343.0      # m/s — same constant as audio + visuals use

@export var shooter_id: int = 1
@export var is_mine: bool = false

var _age := 0.0
var _exploded := false

func _ready() -> void:
	set_multiplayer_authority(1)
	add_to_group("projectiles")
	if not multiplayer.is_server():
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	if _exploded:
		return
	_age += delta
	if not multiplayer.is_server():
		return
	if is_mine:
		if _age >= MINE_LIFETIME:
			_disarm()
		else:
			_maybe_trigger_mine()
	elif _age >= FUSE:
		_explode()

func _on_body_entered(_body: Node) -> void:
	# Only the authoritative server triggers explosions; clients are passive visuals.
	if not multiplayer.is_server() or _exploded:
		return
	if _age < ARM_DELAY:
		return
	if is_mine:
		return
	_explode()

func _maybe_trigger_mine() -> void:
	if _age < ARM_DELAY:
		return
	for p in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		if p.get("ghost_mode") == true:
			continue
		if global_position.distance_to(p.global_position) <= MINE_TRIGGER_RADIUS:
			_explode()
			return

# Called when a bullet hits the grenade (server-side raycast on the rifle).
func detonate() -> void:
	if _exploded or not multiplayer.is_server():
		return
	if is_mine:
		_disarm()
		return
	_explode()

func _disarm() -> void:
	if _exploded:
		return
	_exploded = true
	_remove_quietly.rpc()

@rpc("authority", "call_local", "reliable")
func _remove_quietly() -> void:
	queue_free()

func _explode() -> void:
	_exploded = true
	var players_root: Node = get_tree().current_scene.get_node_or_null("Players")
	var shooter_node: Node = players_root.get_node_or_null(str(shooter_id)) if players_root else null
	for p in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		if p.get("ghost_mode") == true:
			continue
		var dist: float = global_position.distance_to(p.global_position)
		if dist > RADIUS:
			continue
		var space := get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(global_position, p.global_position)
		q.collision_mask = 1  # world only — LoS check
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			continue

		var falloff: float = clamp(1.0 - (dist / RADIUS), 0.0, 1.0)
		var dmg: int = int(lerp(float(MIN_DAMAGE), float(MAX_DAMAGE), falloff))

		# Self-damage reduction
		if p.player_id == shooter_id:
			dmg = int(dmg * 0.4)

		# Grenade Knockback
		var kb_force: float = 18.0 # Stronger base for heavy grenades
		var dir: Vector3 = (p.global_position - global_position)
		if dir.length_squared() > 0.001:
			dir = dir.normalized()
		else:
			dir = Vector3.UP

		var impulse: Vector3 = (dir * kb_force * falloff) + (Vector3.UP * kb_force * 0.4 * falloff)
		# Damage / knockback / hitmarker arrive when the shockwave reaches the
		# target — same dist/SPEED_OF_SOUND delay used by the audio + visual
		# shockwave shell. Captured locals so the timer lambda has its own
		# values per-target.
		var ep_pos: Vector3 = global_position
		var c_dmg := dmg
		var c_dir := dir
		var c_imp := impulse
		var c_kb_len := impulse.length()
		var c_falloff := falloff
		var target_player := p
		var target_authority: int = p.get_multiplayer_authority()
		var target_pos: Vector3 = p.global_position
		var target_delay: float = dist / SPEED_OF_SOUND
		var apply_target := func() -> void:
			if not is_instance_valid(target_player):
				return
			if c_dmg > 0:
				target_player.take_damage.rpc_id(
					target_authority, c_dmg, shooter_id, ep_pos,
					c_dir, c_kb_len, RADIUS, c_falloff)
			target_player.apply_knockback.rpc_id(target_authority, c_imp)
		if target_delay < 0.01:
			apply_target.call()
		else:
			get_tree().create_timer(target_delay).timeout.connect(apply_target)
		# Hitmarker arrives when the shockwave reaches the SHOOTER (different
		# distance from the explosion than the target).
		if c_dmg > 0 and p.player_id != shooter_id and shooter_node and is_instance_valid(shooter_node):
			var sn := shooter_node
			var sn_authority: int = sn.get_multiplayer_authority()
			var hit_pos: Vector3 = target_pos + Vector3.UP * 0.6
			var local_dmg := c_dmg
			var shooter_delay: float = ep_pos.distance_to(sn.global_position) / SPEED_OF_SOUND
			var fire_hitmarker := func() -> void:
				if is_instance_valid(sn):
					sn._hit_confirm.rpc_id(sn_authority, false, local_dmg, hit_pos)
			if shooter_delay < 0.01:
				fire_hitmarker.call()
			else:
				get_tree().create_timer(shooter_delay).timeout.connect(fire_hitmarker)
	_do_vfx.rpc()

@rpc("authority", "call_local", "reliable")
func _do_vfx() -> void:
	SFX.explosion(global_position, RADIUS)
	var pos: Vector3 = global_position
	var scene: Node = get_tree().current_scene
	if scene and scene.has_method("trigger_explosion_sidechain"):
		scene.trigger_explosion_sidechain(pos, RADIUS, 1.25)
	_spawn_heat_distortion(scene, pos, RADIUS, 0.3, 0.055)
	_spawn_shockwave_ring(scene, pos, RADIUS)
	# Surface scorch rings — same helper as explosive bullets, raycasts in
	# the 6 cardinal directions and drops a soot crater on each surface hit.
	Violence.spawn_blast_scorches(scene, pos, RADIUS)

	# --- Bright white-hot core flash (very short)
	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.6
	core_mesh.height = 1.2
	core.mesh = core_mesh
	var core_mat := StandardMaterial3D.new()
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.albedo_color = Color(1.0, 0.96, 0.86, 0.08)
	core_mat.emission_enabled = true
	core_mat.emission = Color(1.0, 0.85, 0.4)
	core_mat.emission_energy_multiplier = 18.0
	core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core.material_override = core_mat
	core.position = pos
	scene.add_child(core)
	var ctw := core.create_tween().set_parallel(true)
	var core_expand_time := 0.17
	var core_target_scale := Vector3.ONE * maxf(0.01, RADIUS / core_mesh.radius)
	ctw.tween_property(core, "scale", core_target_scale, core_expand_time)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	ctw.tween_property(core_mat, "albedo_color", Color(1.0, 0.6, 0.18, 0.36), core_expand_time * 0.5)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	ctw.tween_property(core_mat, "albedo_color", Color(0.98, 0.14, 0.02, 0.0), core_expand_time * 0.5)\
		.set_delay(core_expand_time * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	ctw.tween_property(core_mat, "emission", Color(1.0, 0.3, 0.06), core_expand_time * 0.72)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	ctw.tween_property(core_mat, "emission_energy_multiplier", 0.0, core_expand_time * 0.28)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ctw.chain().tween_callback(core.queue_free)

	# --- Dense blast shell (reaches full opacity near the blast border)
	var wave := MeshInstance3D.new()
	var wave_mesh := SphereMesh.new()
	wave_mesh.radius = 0.3
	wave_mesh.height = 0.6
	wave.mesh = wave_mesh
	var wave_mat := StandardMaterial3D.new()
	wave_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wave_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wave_mat.albedo_color = Color(1.0, 0.48, 0.12, 0.02)
	wave_mat.emission_enabled = true
	wave_mat.emission = Color(1.0, 0.35, 0.08)
	wave_mat.emission_energy_multiplier = 6.0
	wave_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wave.material_override = wave_mat
	wave.position = pos
	scene.add_child(wave)
	var wtw := wave.create_tween().set_parallel(true)
	# Shockwave expands at the speed of sound (343 m/s) so the visual wave
	# arrives at distant viewers at the same instant the audio does (which is
	# delayed by distance/343 in SFX). Min 30 ms so tiny blasts stay visible.
	var wave_expand_time := maxf(0.03, RADIUS / 343.0)
	var wave_target_scale := Vector3.ONE * maxf(0.01, (RADIUS * 1.05) / wave_mesh.radius)
	wtw.tween_property(wave, "scale", wave_target_scale, wave_expand_time)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	wtw.tween_property(wave_mat, "albedo_color", Color(1.0, 0.42, 0.08, 0.14), wave_expand_time * 0.5)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	wtw.tween_property(wave_mat, "albedo_color", Color(0.88, 0.08, 0.01, 0.0), wave_expand_time * 0.5)\
		.set_delay(wave_expand_time * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	wtw.tween_property(wave_mat, "emission_energy_multiplier", 0.0, wave_expand_time * 0.26)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	wtw.chain().tween_callback(wave.queue_free)

	# Brief scene-wide flash — way brighter than the warm-ember decay light
	# below, but only ~60 ms so it reads as the moment-of-detonation spike.
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.98, 0.92)
	flash.light_energy = 100.0 + RADIUS * 14.0
	flash.omni_range = maxf(40.0, RADIUS * 6.0)
	flash.position = pos
	scene.add_child(flash)
	var ftw := flash.create_tween()
	ftw.tween_property(flash, "light_energy", 0.0, 0.06)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ftw.tween_callback(flash.queue_free)

	# Bright core glow — small range, longer duration than the scene flash.
	# Reads as the white-hot fireball center hanging around as the blast
	# evolves, distinct from the scene-wide initial spike.
	var core_light := OmniLight3D.new()
	core_light.light_color = Color(1.0, 0.95, 0.78)
	core_light.light_energy = 60.0 + RADIUS * 8.0
	core_light.omni_range = maxf(8.0, RADIUS * 1.4)
	core_light.position = pos
	scene.add_child(core_light)
	var ctlw := core_light.create_tween()
	ctlw.tween_property(core_light, "light_color", Color(1.0, 0.55, 0.18), 0.12)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	ctlw.parallel().tween_property(core_light, "light_energy", 0.0, 0.32)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ctlw.tween_callback(core_light.queue_free)

	var light := OmniLight3D.new()
	var hot_color := Color(1.0, 0.97, 0.9)
	var warm_color := Color(1.0, 0.62, 0.22)
	var ember_color := Color(0.95, 0.18, 0.04)
	light.light_color = hot_color
	light.light_energy = 58.0
	light.omni_range = 26.0
	light.position = pos
	scene.add_child(light)
	var ltw := light.create_tween()
	ltw.set_parallel(true)
	ltw.tween_property(light, "light_color", warm_color, 0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	ltw.tween_property(light, "light_color", ember_color, 0.14).set_delay(0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	ltw.tween_property(light, "light_energy", 0.0, 0.18).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ltw.tween_callback(light.queue_free)

	# --- Local camera shake with distance falloff
	var lp: Node = scene.get("local_player")
	if lp and is_instance_valid(lp) and lp.has_method("apply_explosion_view_punch"):
		lp.apply_explosion_view_punch(pos, RADIUS, 1.25)

	queue_free()

func _spawn_heat_distortion(scene: Node, pos: Vector3, radius: float, duration: float, strength: float) -> void:
	if scene == null:
		return
	var shell := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.3
	mesh.height = 0.6
	mesh.radial_segments = 24
	mesh.rings = 12
	shell.mesh = mesh
	var shader := Shader.new()
	shader.code = """
		shader_type spatial;
		render_mode unshaded, cull_disabled, depth_draw_never;

		uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
		uniform float distortion_strength = 0.05;
		uniform float zoom_strength = 0.018;
		uniform float opacity = 0.2;

		void fragment() {
			vec3 n = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			float fresnel = pow(1.0 - abs(dot(normalize(VIEW), NORMAL)), 2.4);
			vec2 offset = n.xy * distortion_strength * fresnel;
			vec2 zoom = (SCREEN_UV - vec2(0.5)) * zoom_strength * fresnel;
			vec2 uv = SCREEN_UV - zoom + offset;
			vec3 col = texture(screen_tex, uv).rgb;
			ALBEDO = col;
			ALPHA = opacity * fresnel;
		}
	"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("distortion_strength", strength * 2.4)
	mat.set_shader_parameter("zoom_strength", strength * 0.9)
	mat.set_shader_parameter("opacity", 0.38)
	shell.material_override = mat
	shell.position = pos
	scene.add_child(shell)

	var target_scale := Vector3.ONE * maxf(0.01, (radius * 1.95) / mesh.radius)
	var tw := shell.create_tween().set_parallel(true)
	tw.tween_property(shell, "scale", target_scale, duration)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("distortion_strength", v),
		strength,
		0.0,
		duration * 0.9
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("zoom_strength", v),
		strength * 0.35,
		0.0,
		duration * 0.9
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("opacity", v),
		0.38,
		0.0,
		duration * 0.7
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(shell.queue_free)

# Thin-shell screen-space shockwave: a sphere expanding at the speed of sound.
# A high-power fresnel concentrates the pixel displacement on the silhouette
# ring, so the camera sees a thin distorted halo travelling outward.
func _spawn_shockwave_ring(scene: Node, pos: Vector3, radius: float) -> void:
	if scene == null:
		return
	var shell := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.25
	mesh.height = 0.5
	mesh.radial_segments = 32
	mesh.rings = 16
	shell.mesh = mesh
	var shader := Shader.new()
	shader.code = """
		shader_type spatial;
		render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

		uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
		uniform float distortion_strength = 0.04;
		uniform float ring_thickness = 7.0;
		uniform float opacity = 0.85;

		void fragment() {
			// High exponent -> energy concentrated on silhouette ring only.
			float fresnel = pow(1.0 - abs(dot(normalize(VIEW), NORMAL)), ring_thickness);
			vec3 n = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			vec2 offset = n.xy * distortion_strength * fresnel;
			vec3 col = texture(screen_tex, SCREEN_UV + offset).rgb;
			ALBEDO = col;
			ALPHA = fresnel * opacity;
		}
	"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("distortion_strength", 0.05)
	mat.set_shader_parameter("ring_thickness", 7.0)
	mat.set_shader_parameter("opacity", 0.9)
	shell.material_override = mat
	shell.position = pos
	scene.add_child(shell)
	# Sound-speed expansion (matches audio delay) with a 30 ms minimum so
	# tiny blasts remain visible.
	var dur: float = maxf(0.03, radius / 343.0)
	var target_scale := Vector3.ONE * maxf(0.01, (radius * 1.05) / mesh.radius)
	var tw := shell.create_tween().set_parallel(true)
	tw.tween_property(shell, "scale", target_scale, dur)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("distortion_strength", v),
		0.05,
		0.0,
		dur
	).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("opacity", v),
		0.9,
		0.0,
		dur * 0.9
	).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(shell.queue_free)
