extends CharacterBody3D

# --- Movement ---
const WALK_SPEED := 11.0
const AIR_ACCEL := 80.0
const GROUND_ACCEL := 120.0
const FRICTION := 10.0
const JUMP_VELOCITY := 9.0
const DOUBLE_JUMP_VELOCITY := 8.5
const WALL_JUMP_V := 10.5
const WALL_JUMP_H := 4.0
const WALL_JUMP_COOLDOWN := 0.14
const DASH_SPEED := 28.0
const DASH_TIME := 0.18
const MAX_DASH_CHARGES := 3
const DASH_RECHARGE_TIME := 3.0
const GRAVITY := 30.0
const MOUSE_SENS := 0.0022

# --- Combat ---
const MAX_HEALTH := 100
const HEAD_HEIGHT := 0.55
const RIFLE_RANGE := 200.0
const RIFLE_RECOIL_PITCH := 0.018         # radians added to camera pitch per shot
const RIFLE_RECOIL_KICK := 0.08           # muzzle pushed back (meters) per shot
const RIFLE_RECOIL_YAW_JITTER := 0.004    # tiny yaw nudge per shot
const RIFLE_SHAKE := 0.015                # camera shake impulse
const GRENADE_RELOAD := 3.0
const GRENADE_LAUNCH_SPEED := 22.0
const GRENADE_LAUNCH_LIFT := 4.0
const MELEE_RELOAD := 0.5
const MELEE_RANGE := 2.2
const MELEE_DAMAGE := 50
const MELEE_BACKSTAB := 9999  # guaranteed kill

@onready var camera: Camera3D = $Camera
@onready var muzzle: Node3D = $Camera/Muzzle
@onready var mesh: MeshInstance3D = $Mesh
@onready var name_label: Label3D = $NameLabel

var jumps_left := 2
var dash_timer := 0.0
var dash_dir := Vector3.ZERO
var dash_charges: int = MAX_DASH_CHARGES
var dash_recharge_timer := 0.0
var rifle_cooldown := 0.0
var grenade_cooldown := 0.0
var melee_cooldown := 0.0
var wall_jump_cooldown := 0.0
var weapon: Weapon = Weapon.new()
var mag: int = Weapon.BASE_MAG_SIZE
var reloading: bool = false
var frozen: bool = false

# Camera / gun feel — updated by fire, decayed per frame.
var look_pitch := 0.0
var recoil_pitch := 0.0
var muzzle_kick_z := 0.0
var shake_amt := 0.0
var melee_offset := Vector3.ZERO
var _muzzle_rest_pos: Vector3
var _camera_rest_pos: Vector3
var _melee_tween: Tween = null

@export var player_id: int = 1
@export var player_name: String = "Player"

var health: int = MAX_HEALTH

signal died(killer_id: int)
signal cooldowns_changed  # emitted on local player for HUD

func _enter_tree() -> void:
	set_multiplayer_authority(player_id)

func _ready() -> void:
	name_label.text = player_name
	_muzzle_rest_pos = muzzle.position
	_camera_rest_pos = camera.position
	_refresh_authority_view()
	add_to_group("players")

func _process(_delta: float) -> void:
	# Re-assert camera state every frame until authority is established.
	# Guards against a connection-state race where is_multiplayer_authority()
	# is false during _ready (peer id == 0 before connected_to_server fires).
	if is_multiplayer_authority() and not camera.current:
		_refresh_authority_view()

func _refresh_authority_view() -> void:
	if is_multiplayer_authority():
		camera.make_current()
		mesh.visible = false
		name_label.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		Input.use_accumulated_input = false
	else:
		camera.clear_current()
		mesh.visible = true
		name_label.visible = true

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENS)
		look_pitch = clamp(look_pitch - event.relative.y * MOUSE_SENS, -1.4, 1.4)
		camera.rotation.x = look_pitch + recoil_pitch
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	if frozen:
		velocity = Vector3.ZERO
		return

	rifle_cooldown = max(0.0, rifle_cooldown - delta)
	grenade_cooldown = max(0.0, grenade_cooldown - delta)
	melee_cooldown = max(0.0, melee_cooldown - delta)
	wall_jump_cooldown = max(0.0, wall_jump_cooldown - delta)
	# Dash charges recharge one at a time while below max.
	if dash_charges < MAX_DASH_CHARGES:
		dash_recharge_timer += delta
		if dash_recharge_timer >= DASH_RECHARGE_TIME:
			dash_charges += 1
			dash_recharge_timer = 0.0
	else:
		dash_recharge_timer = 0.0
	# Reload completes when the cooldown set to the weapon's reload time runs out.
	if reloading and rifle_cooldown <= 0.0:
		mag = weapon.get_mag_size()
		reloading = false
	cooldowns_changed.emit()

	# Recoil decay + apply
	recoil_pitch = lerp(recoil_pitch, 0.0, delta * 9.0)
	muzzle_kick_z = lerp(muzzle_kick_z, 0.0, delta * 14.0)
	shake_amt = lerp(shake_amt, 0.0, delta * 14.0)
	camera.rotation.x = look_pitch + recoil_pitch
	muzzle.position = _muzzle_rest_pos + Vector3(0.0, 0.0, muzzle_kick_z) + melee_offset
	camera.position = _camera_rest_pos + Vector3(
		randf_range(-1.0, 1.0) * shake_amt,
		randf_range(-1.0, 1.0) * shake_amt,
		0.0,
	)

	# --- Gravity ---
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		jumps_left = 2

	# --- Jump / wall-jump / double-jump ---
	# Wall-jump takes priority over double-jump so you can chain WJ → WJ → dash → WJ
	# to climb a building. Each WJ imparts strong up + gentle outward push, so the
	# player must strafe/dash back toward the wall to chain.
	if Input.is_action_just_pressed("jump"):
		if is_on_floor():
			velocity.y = JUMP_VELOCITY
			jumps_left = 1
		elif is_on_wall() and wall_jump_cooldown <= 0.0:
			var n := get_wall_normal()
			velocity.y = WALL_JUMP_V
			velocity.x += n.x * WALL_JUMP_H
			velocity.z += n.z * WALL_JUMP_H
			wall_jump_cooldown = WALL_JUMP_COOLDOWN
			jumps_left = 1  # wall-jump refreshes a double-jump charge
		elif jumps_left > 0:
			velocity.y = DOUBLE_JUMP_VELOCITY
			jumps_left -= 1

	# --- Dash ---
	if Input.is_action_just_pressed("dash") and dash_charges > 0:
		var input_dir := _input_vector()
		if input_dir == Vector3.ZERO:
			input_dir = -global_transform.basis.z
		dash_dir = input_dir.normalized()
		dash_timer = DASH_TIME
		dash_charges -= 1

	# --- Movement ---
	var wish_dir := _input_vector()
	if dash_timer > 0.0:
		dash_timer -= delta
		velocity.x = dash_dir.x * DASH_SPEED
		velocity.z = dash_dir.z * DASH_SPEED
		velocity.y = max(velocity.y, 0.0)
	else:
		var accel := GROUND_ACCEL if is_on_floor() else AIR_ACCEL
		var target_vel := wish_dir * WALK_SPEED
		velocity.x = move_toward(velocity.x, target_vel.x, accel * delta)
		velocity.z = move_toward(velocity.z, target_vel.z, accel * delta)
		if is_on_floor() and wish_dir == Vector3.ZERO:
			velocity.x = move_toward(velocity.x, 0.0, FRICTION * delta * WALK_SPEED * 0.1)
			velocity.z = move_toward(velocity.z, 0.0, FRICTION * delta * WALK_SPEED * 0.1)

	move_and_slide()

	# --- Combat actions ---
	# Full-auto rifle: hold LMB, fires every fire-interval until mag is empty.
	if Input.is_action_pressed("shoot") and not reloading and mag > 0 and rifle_cooldown <= 0.0:
		rifle_cooldown = weapon.get_fire_interval()
		mag -= 1
		_fire_rifle()
		if mag <= 0:
			reloading = true
			rifle_cooldown = weapon.get_reload_time()
	if Input.is_action_just_pressed("shoot_grenade") and grenade_cooldown <= 0.0:
		grenade_cooldown = GRENADE_RELOAD
		_fire_grenade()
	if Input.is_action_just_pressed("melee") and melee_cooldown <= 0.0:
		melee_cooldown = MELEE_RELOAD
		_swing_melee()

	# --- Fell off the map ---
	if global_position.y < -30.0:
		_apply_damage(MAX_HEALTH, player_id)

func _input_vector() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (global_transform.basis * Vector3(input.x, 0.0, input.y))
	dir.y = 0.0
	return dir

# -------------------- RIFLE (hitscan) --------------------

func _fire_rifle() -> void:
	var origin: Vector3 = camera.global_position
	var base_dir: Vector3 = -camera.global_transform.basis.z
	# Local feel (authority-only; these fields are driven by the local physics loop).
	recoil_pitch += RIFLE_RECOIL_PITCH
	muzzle_kick_z = max(muzzle_kick_z, RIFLE_RECOIL_KICK)
	shake_amt = max(shake_amt, RIFLE_SHAKE)
	rotate_y(randf_range(-RIFLE_RECOIL_YAW_JITTER, RIFLE_RECOIL_YAW_JITTER))
	# Multi-shot: fire N rays with random yaw+pitch spread (MULTI-SHOT card).
	var shots: int = weapon.get_shots_per_trigger()
	var spread: float = weapon.spread
	var cam_right: Vector3 = camera.global_transform.basis.x
	var cam_up: Vector3 = camera.global_transform.basis.y
	for i in shots:
		var dir := base_dir
		if spread > 0.0:
			var yaw := randf_range(-spread, spread)
			var pitch := randf_range(-spread, spread)
			dir = base_dir.rotated(cam_up, yaw).rotated(cam_right, pitch).normalized()
		_rifle_fired.rpc(origin, dir, player_id)

@rpc("any_peer", "call_local", "reliable")
func _rifle_fired(origin: Vector3, dir: Vector3, shooter_id: int) -> void:
	var shooter_node := get_parent().get_node_or_null(str(shooter_id))
	var w: Weapon = shooter_node.weapon if shooter_node else Weapon.new()
	var is_server := multiplayer.is_server()
	var space := get_world_3d().direct_space_state

	# Iterative raycast path: pierce through players, ricochet off walls.
	# Each peer runs this loop to render consistent tracer segments; only the
	# server mutates game state (damage / lifesteal / grenade detonation).
	var cur_origin := origin
	var cur_dir := dir
	var pierce_left := w.pierce_count
	var ricochet_left := w.ricochet_count
	var excluded_rids: Array[RID] = []
	if shooter_node:
		excluded_rids.append(shooter_node.get_rid())

	var max_steps := pierce_left + ricochet_left + 1
	for _step in range(max_steps):
		var q := PhysicsRayQueryParameters3D.create(cur_origin, cur_origin + cur_dir * RIFLE_RANGE)
		q.collision_mask = 1 | 2 | 4  # world + players + projectiles
		q.exclude = excluded_rids
		var result := space.intersect_ray(q)
		if result.is_empty():
			_spawn_tracer(cur_origin, cur_origin + cur_dir * RIFLE_RANGE, w.bullet_color, w.bullet_scale)
			break
		_spawn_tracer(cur_origin, result.position, w.bullet_color, w.bullet_scale)
		var collider: Node = result.collider
		var hit_pos: Vector3 = result.position

		if collider and collider.is_in_group("players"):
			var vid: int = collider.player_id
			if is_server and vid != shooter_id:
				var head_y: float = collider.global_position.y + HEAD_HEIGHT
				var is_head: bool = hit_pos.y >= head_y
				var dmg: int = int(w.get_damage() * (w.get_headshot_mult() if is_head else 1.0))
				collider.take_damage.rpc_id(vid, dmg, shooter_id)
				_hit_confirm.rpc_id(shooter_id, is_head)
				if w.lifesteal > 0.0 and shooter_node:
					var heal_amt: int = int(float(dmg) * w.lifesteal)
					if heal_amt > 0:
						shooter_node.heal.rpc_id(shooter_id, heal_amt)
			# Bullet explosion on player hit (visual + server damage)
			if w.explosive_radius > 0.0:
				_spawn_bullet_blast(hit_pos, w.explosive_radius, w.bullet_color)
				if is_server:
					_apply_bullet_splash(hit_pos, w.explosive_radius, w.explosive_damage, shooter_id)
			# Pierce continues; else stop at this hit.
			if pierce_left > 0:
				pierce_left -= 1
				excluded_rids.append(collider.get_rid())
				cur_origin = hit_pos + cur_dir * 0.05
				continue
			break

		elif collider and collider.is_in_group("grenades") and collider.has_method("detonate"):
			if is_server:
				collider.detonate()
				_hit_confirm.rpc_id(shooter_id, true)
			break

		else:
			# World hit. Trigger explosive payload, then ricochet if available.
			if w.explosive_radius > 0.0:
				_spawn_bullet_blast(hit_pos, w.explosive_radius, w.bullet_color)
				if is_server:
					_apply_bullet_splash(hit_pos, w.explosive_radius, w.explosive_damage, shooter_id)
			if ricochet_left > 0:
				ricochet_left -= 1
				cur_dir = cur_dir.bounce(result.normal).normalized()
				cur_origin = hit_pos + result.normal * 0.02
				continue
			break

	_spawn_muzzle_flash(w.bullet_color, w.bullet_scale)

func _apply_bullet_splash(pos: Vector3, radius: float, damage: float, shooter_id: int) -> void:
	for p in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		var dist: float = pos.distance_to(p.global_position)
		if dist > radius:
			continue
		# LoS check.
		var q := PhysicsRayQueryParameters3D.create(pos, p.global_position)
		q.collision_mask = 1
		if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			continue
		if p.player_id == shooter_id:
			continue
		var falloff: float = clamp(1.0 - dist / radius, 0.0, 1.0)
		var dmg: int = int(damage * falloff)
		if dmg > 0:
			p.take_damage.rpc_id(p.player_id, dmg, shooter_id)

func _spawn_bullet_blast(pos: Vector3, radius: float, color: Color) -> void:
	# Small visual only (every peer spawns its own). No camera shake to avoid
	# rattling the screen with full-auto explosive rounds.
	var scene: Node = get_tree().current_scene
	var wave := MeshInstance3D.new()
	var wm := SphereMesh.new()
	wm.radius = 0.2
	wm.height = 0.4
	wave.mesh = wm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.6)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 5.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wave.material_override = mat
	wave.position = pos
	scene.add_child(wave)
	var tw := wave.create_tween().set_parallel(true)
	tw.tween_property(wave, "scale", Vector3.ONE * radius * 1.4, 0.18)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(color.r, color.g, color.b, 0.0), 0.2)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.2)
	tw.chain().tween_callback(wave.queue_free)

	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 6.0
	light.omni_range = radius * 2.0
	light.position = pos
	scene.add_child(light)
	var ltw := light.create_tween()
	ltw.tween_property(light, "light_energy", 0.0, 0.12)
	ltw.tween_callback(light.queue_free)

func _spawn_muzzle_flash(color: Color = Color(1.0, 0.88, 0.45), scale_f: float = 1.0) -> void:
	# Bright emissive sphere + point light at the barrel tip; both fade out quickly.
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.14 * scale_f
	sphere.height = 0.28 * scale_f
	sphere.radial_segments = 8
	sphere.rings = 4
	flash.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.95)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 6.0 * scale_f
	flash.material_override = mat
	flash.position = Vector3(0.0, 0.0, -0.35)
	flash.rotation = Vector3(0.0, 0.0, randf_range(0.0, TAU))
	muzzle.add_child(flash)

	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 4.0 * scale_f
	light.omni_range = 7.0 * scale_f
	light.position = Vector3(0.0, 0.0, -0.35)
	muzzle.add_child(light)

	var tw := flash.create_tween().set_parallel(true)
	tw.tween_property(flash, "scale", Vector3(1.9, 1.9, 1.9), 0.06)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(1, 1, 1, 0.0), 0.08)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.08)
	tw.tween_property(light, "light_energy", 0.0, 0.07)
	tw.chain().tween_callback(flash.queue_free)
	tw.chain().tween_callback(light.queue_free)

@rpc("any_peer", "reliable")
func _hit_confirm(is_headshot: bool) -> void:
	# Only accept from the server.
	if multiplayer.get_remote_sender_id() != 1:
		return
	var g := get_tree().current_scene
	if g and g.has_method("show_hitmarker"):
		g.show_hitmarker(is_headshot)

func _spawn_tracer(from: Vector3, to: Vector3, color: Color = Color(1.0, 0.9, 0.3), scale_f: float = 1.0) -> void:
	var mesh_inst := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0 * scale_f
	mat.albedo_color = color
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	im.surface_add_vertex(from)
	im.surface_add_vertex(to)
	im.surface_end()
	mesh_inst.mesh = im
	get_tree().current_scene.add_child(mesh_inst)
	var tw := mesh_inst.create_tween()
	tw.tween_interval(0.06)
	tw.tween_callback(mesh_inst.queue_free)

# -------------------- GRENADE --------------------

func _fire_grenade() -> void:
	var origin: Vector3 = muzzle.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	if multiplayer.is_server():
		var uname := "G_%d_%d" % [player_id, Time.get_ticks_usec()]
		_spawn_grenade.rpc(origin, dir, player_id, uname)
	else:
		_request_grenade.rpc_id(1, origin, dir)

@rpc("any_peer", "reliable")
func _request_grenade(origin: Vector3, dir: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = player_id
	var uname := "G_%d_%d" % [sender, Time.get_ticks_usec()]
	_spawn_grenade.rpc(origin, dir, sender, uname)

@rpc("any_peer", "call_local", "reliable")
func _spawn_grenade(origin: Vector3, dir: Vector3, shooter: int, uname: String) -> void:
	# Only the server may authorize grenade spawns.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	var scene: PackedScene = load("res://scenes/grenade.tscn")
	var g := scene.instantiate()
	g.name = uname
	g.shooter_id = shooter
	get_tree().current_scene.add_child(g)
	g.global_position = origin + dir * 0.6
	if multiplayer.is_server():
		g.linear_velocity = dir * GRENADE_LAUNCH_SPEED + Vector3(0.0, GRENADE_LAUNCH_LIFT, 0.0)

# -------------------- MELEE --------------------

func _swing_melee() -> void:
	var origin: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	_melee_swung.rpc(origin, dir, player_id)

@rpc("any_peer", "call_local", "reliable")
func _melee_swung(origin: Vector3, dir: Vector3, attacker_id: int) -> void:
	# Gun swing + blade trail play on every peer.
	_animate_gun_slash()
	_spawn_slice_trail(origin, dir)
	# Camera shake only for the attacker.
	if is_multiplayer_authority():
		shake_amt = max(shake_amt, 0.035)
	# Only the server runs hit detection.
	if not multiplayer.is_server():
		return
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * MELEE_RANGE)
	q.collision_mask = 1 | 2
	var shooter_node := get_parent().get_node_or_null(str(attacker_id))
	if shooter_node:
		q.exclude = [shooter_node.get_rid()]
	var result := space.intersect_ray(q)
	if result.is_empty():
		return
	var target: Node = result.collider
	if target == null or not target.is_in_group("players"):
		return
	if target.player_id == attacker_id:
		return
	var v_fwd: Vector3 = -target.global_transform.basis.z
	var attacker_fwd: Vector3 = dir
	var backstab: bool = v_fwd.dot(attacker_fwd) > 0.4
	var dmg: int = MELEE_BACKSTAB if backstab else MELEE_DAMAGE
	target.take_damage.rpc_id(target.player_id, dmg, attacker_id)
	_hit_confirm.rpc_id(attacker_id, backstab)

func _animate_gun_slash() -> void:
	if muzzle == null:
		return
	if _melee_tween and _melee_tween.is_valid():
		_melee_tween.kill()
	# Reset starting pose so repeated slashes always begin from rest.
	muzzle.rotation = Vector3.ZERO
	melee_offset = Vector3.ZERO
	# End-of-slash pose: the blade has swept diagonally across the view, down-and-left,
	# the gun has lunged slightly forward. Rotation + translation together give the
	# blade a large visible path (pure rotation around the muzzle pivot is too tight).
	var slash_rot := Vector3(-0.45, 0.15, -1.25)         # pitch down, slight yaw, hard left roll
	var slash_pos := Vector3(-0.28, -0.16, -0.2)         # shove gun left+down+forward
	_melee_tween = create_tween().set_parallel(true)
	# STRIKE (0.045 s): rest → slash end. EXPO ease-IN peaks velocity at contact.
	_melee_tween.tween_property(muzzle, "rotation", slash_rot, 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	_melee_tween.tween_method(_set_melee_offset, Vector3.ZERO, slash_pos, 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	# RECOVERY (0.12 s): slash end → rest. Smooth follow-through.
	_melee_tween.chain().set_parallel(true)
	_melee_tween.tween_property(muzzle, "rotation", Vector3.ZERO, 0.12)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_melee_tween.tween_method(_set_melee_offset, slash_pos, Vector3.ZERO, 0.12)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)

func _set_melee_offset(v: Vector3) -> void:
	melee_offset = v

func _spawn_slice_trail(origin: Vector3, dir: Vector3) -> void:
	# A bright emissive bar placed in world-space along the diagonal arc the
	# blade sweeps through. Grows outward on X (length) to suggest speed, then
	# fades out. Visible to every peer because it lives in the world.
	var trail := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.4, 0.07, 0.04)
	trail.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.9, 0.95, 1.0, 0.95)
	mat.emission_enabled = true
	mat.emission = Color(0.75, 0.9, 1.0)
	mat.emission_energy_multiplier = 6.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	trail.material_override = mat

	var light := OmniLight3D.new()
	light.light_color = Color(0.75, 0.9, 1.0)
	light.light_energy = 3.5
	light.omni_range = 5.0
	trail.add_child(light)

	get_tree().current_scene.add_child(trail)
	trail.global_position = origin + dir * 1.6
	trail.look_at(origin, Vector3.UP)
	# Tilt the bar along a top-right → bottom-left diagonal (matches the gun swing).
	trail.rotate_object_local(Vector3.FORWARD, deg_to_rad(-55.0))
	trail.scale = Vector3(0.2, 1.0, 1.0)

	var tw := trail.create_tween().set_parallel(true)
	# Bar shoots to full length during the strike (~45 ms) then fades out fast.
	tw.tween_property(trail, "scale", Vector3(1.35, 1.0, 1.0), 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(1, 1, 1, 0.0), 0.07).set_delay(0.02)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.07).set_delay(0.02)
	tw.tween_property(light, "light_energy", 0.0, 0.06)
	tw.chain().tween_callback(trail.queue_free)

# -------------------- DAMAGE / DEATH --------------------

@rpc("any_peer", "call_local", "reliable")
func take_damage(amount: int, from_id: int) -> void:
	if not is_multiplayer_authority():
		return
	_apply_damage(amount, from_id)

func _apply_damage(amount: int, from_id: int) -> void:
	if frozen or health <= 0:
		return
	health = max(0, health - amount)
	if health <= 0:
		died.emit(from_id)
		_report_death.rpc_id(1, from_id)

@rpc("any_peer", "call_local", "reliable")
func _report_death(killer_id: int) -> void:
	# Server-side: tell the game controller the round ended. Respawn is handled
	# by the game controller at the start of the next round (after card pick).
	if not multiplayer.is_server():
		return
	var victim_id := multiplayer.get_remote_sender_id()
	if victim_id == 0:
		victim_id = player_id
	var game := get_tree().current_scene
	if game and game.has_method("report_kill"):
		game.report_kill(killer_id, victim_id)

@rpc("any_peer", "call_local", "reliable")
func server_respawn(pos: Vector3) -> void:
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0:
		return
	if not is_multiplayer_authority():
		return
	global_position = pos
	velocity = Vector3.ZERO
	health = MAX_HEALTH
	rifle_cooldown = 0.0
	grenade_cooldown = 0.0
	melee_cooldown = 0.0
	wall_jump_cooldown = 0.0
	mag = weapon.get_mag_size()
	reloading = false
	dash_charges = MAX_DASH_CHARGES
	dash_timer = 0.0
	jumps_left = 2

@rpc("any_peer", "call_local", "reliable")
func set_frozen(f: bool) -> void:
	# Server-authorized only. Match the pattern used by server_respawn.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	frozen = f
	if f:
		velocity = Vector3.ZERO
	elif is_multiplayer_authority():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

@rpc("any_peer", "call_local", "reliable")
func heal(amount: int) -> void:
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0:
		return
	if not is_multiplayer_authority():
		return
	health = min(MAX_HEALTH, health + amount)

# -------------------- CARDS (ROUNDS-style) --------------------

@rpc("any_peer", "call_local", "reliable")
func apply_card(card_id: String) -> void:
	# Anyone can call (for debug). In a real round flow, only the card owner's
	# authority would be allowed. Broadcast so every peer's copy of this
	# player's weapon stays in sync.
	var card := CardLibrary.by_id(card_id)
	if card.is_empty():
		return
	card.apply.call(weapon)
	weapon.applied_cards.append(card_id)
	# If the mag cap grew, refill up to the new cap immediately.
	mag = min(weapon.get_mag_size(), max(mag, weapon.get_mag_size() if weapon.applied_cards.size() == 1 else mag))

@rpc("any_peer", "call_local", "reliable")
func reset_weapon() -> void:
	weapon.reset()
	mag = weapon.get_mag_size()
	reloading = false
	rifle_cooldown = 0.0
