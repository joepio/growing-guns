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
@onready var body_model: Node3D = $BodyModel
@onready var head_mesh: MeshInstance3D = $BodyModel/Head
@onready var head_hitbox: Area3D = $HeadHitbox
@onready var torso_hitbox: Area3D = $TorsoHitbox
@onready var legs_hitbox: Area3D = $LegsHitbox
@onready var name_label: Label3D = $NameLabel
@onready var gun_body: MeshInstance3D = $Camera/Muzzle/GunMesh
var gun_barrel: MeshInstance3D = null
var gun_magazine: MeshInstance3D = null

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

# Last broadcast state — avoids flooding the wire when idle.
var _last_sync_pos: Vector3 = Vector3.INF
var _last_sync_yaw: float = INF

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
@export var is_bot: bool = false

# --- Bot AI ---
const BOT_MOVE_SPEED := 8.0
const BOT_SHOOT_INTERVAL := 0.7
const BOT_FOLLOW_DIST := 7.0
const BOT_ROT_SPEED := 6.0
const BOT_SPREAD := 0.055                # ~3.15° — miss-prone but threatening
const BOT_MISS_CHANCE := 0.3             # fraction of shots that get huge extra spread
const BOT_JUMP_CHANCE := 0.025           # per physics tick, when on floor
const BOT_DASH_CHANCE := 0.018           # per physics tick, when charge available

var _bot_target: Node3D = null
var _bot_shoot_cooldown: float = 0.0
var _bot_strafe_timer: float = 0.0
var _bot_strafe_side: float = 0.0        # -1 left, 0 none, +1 right
var _bot_approach: float = 1.0           # -1 retreat, 0 hold, +1 chase
var _bot_jump_cooldown: float = 0.0
var _bot_dash_cooldown: float = 0.0

var health: int = MAX_HEALTH

signal died(killer_id: int)
signal cooldowns_changed  # emitted on local player for HUD

func _enter_tree() -> void:
	# Bots are server-owned — their player_id isn't a real peer.
	set_multiplayer_authority(1 if is_bot else player_id)

func _ready() -> void:
	name_label.text = player_name
	_muzzle_rest_pos = muzzle.position
	_camera_rest_pos = camera.position
	_setup_gun_visuals()
	_update_gun_visuals()
	_update_body_scale()
	_refresh_authority_view()
	add_to_group("players")

func _process(_delta: float) -> void:
	if is_bot:
		return
	# Re-assert camera state every frame until authority is established.
	# Guards against a connection-state race where is_multiplayer_authority()
	# is false during _ready (peer id == 0 before connected_to_server fires).
	if is_multiplayer_authority() and not camera.current:
		_refresh_authority_view()

func _refresh_authority_view() -> void:
	if is_bot:
		# Bot is always third-person: full body visible, no camera takeover.
		camera.clear_current()
		body_model.visible = true
		name_label.visible = true
		return
	if is_multiplayer_authority():
		camera.make_current()
		body_model.visible = false
		name_label.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		Input.use_accumulated_input = false
	else:
		camera.clear_current()
		body_model.visible = true
		name_label.visible = true

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENS)
		look_pitch = clamp(look_pitch - event.relative.y * MOUSE_SENS, -1.4, 1.4)
		camera.rotation.x = look_pitch + recoil_pitch
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		var g := get_tree().current_scene
		if g and g.has_method("is_any_modal_open") and g.is_any_modal_open():
			return
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	if is_bot:
		_bot_physics(delta)
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
		# Default: 1 ground jump + 1 air double-jump = 2 total.
		# ACROBAT and similar cards extend this via weapon.extra_jumps.
		jumps_left = 2 + weapon.extra_jumps

	# --- Jump / wall-jump / double-jump ---
	# Wall-jump takes priority over double-jump so you can chain WJ → WJ → dash → WJ
	# to climb a building. Each WJ imparts strong up + gentle outward push, so the
	# player must strafe/dash back toward the wall to chain.
	if Input.is_action_just_pressed("jump"):
		if is_on_floor():
			velocity.y = JUMP_VELOCITY
			jumps_left = 1 + weapon.extra_jumps
			SFX.jump(global_position)
		elif is_on_wall() and wall_jump_cooldown <= 0.0:
			var n := get_wall_normal()
			velocity.y = WALL_JUMP_V
			velocity.x += n.x * WALL_JUMP_H
			velocity.z += n.z * WALL_JUMP_H
			wall_jump_cooldown = WALL_JUMP_COOLDOWN
			jumps_left = 1 + weapon.extra_jumps  # wall-jump refreshes all air-jumps
			SFX.jump(global_position)
		elif jumps_left > 0:
			velocity.y = DOUBLE_JUMP_VELOCITY
			jumps_left -= 1
			SFX.jump(global_position)

	# --- Dash ---
	if Input.is_action_just_pressed("dash") and dash_charges > 0:
		var input_dir := _input_vector()
		if input_dir == Vector3.ZERO:
			input_dir = -global_transform.basis.z
		dash_dir = input_dir.normalized()
		dash_timer = DASH_TIME
		dash_charges -= 1
		SFX.dash(global_position)

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
	_maybe_broadcast_state()

	# --- Combat actions ---
	# Default is semi-auto (click per shot). The UZI card flips weapon.full_auto
	# so holding LMB fires continuously until the mag runs out.
	var fire_input := Input.is_action_pressed("shoot") if weapon.full_auto \
		else Input.is_action_just_pressed("shoot")
	if fire_input and not reloading and mag > 0 and rifle_cooldown <= 0.0:
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
	SFX.shot(w, origin)
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
		if shooter_node.has_method("get_hitbox_rids"):
			excluded_rids.append_array(shooter_node.get_hitbox_rids())
		else:
			excluded_rids.append(shooter_node.get_rid())

	var max_steps := pierce_left + ricochet_left + 1
	for _step in range(max_steps):
		var q := PhysicsRayQueryParameters3D.create(cur_origin, cur_origin + cur_dir * RIFLE_RANGE)
		q.collision_mask = 1 | 2 | 4  # world + players + projectiles
		q.exclude = excluded_rids
		q.collide_with_areas = true
		var result := space.intersect_ray(q)
		if result.is_empty():
			break
		var dmg_ratio: float = clampf(w.get_damage() / Weapon.BASE_DAMAGE, 0.5, 5.0)
		_spawn_impact(result.position, w.bullet_color, w.bullet_scale, dmg_ratio)
		var collider: Node = result.collider
		var hit_pos: Vector3 = result.position

		var hit_player := _player_from_hit_collider(collider)
		if hit_player:
			var vid: int = hit_player.player_id
			if is_server and vid != shooter_id:
				var is_head := _is_head_hit(collider)
				var dmg: int = int(w.get_damage() * (w.get_headshot_mult() if is_head else 1.0))
				hit_player.take_damage.rpc_id(hit_player.get_multiplayer_authority(), dmg, shooter_id)
				if shooter_node:
					_hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), is_head, dmg)
				if w.lifesteal > 0.0 and shooter_node:
					var heal_amt: int = int(float(dmg) * w.lifesteal)
					if heal_amt > 0:
						shooter_node.heal.rpc_id(shooter_node.get_multiplayer_authority(), heal_amt)
			# Bullet explosion on player hit (visual + server damage)
			if w.explosive_radius > 0.0:
				_spawn_bullet_blast(hit_pos, w.explosive_radius, w.bullet_color)
				if is_server:
					_apply_bullet_splash(hit_pos, w.explosive_radius, w.explosive_damage, shooter_id)
			# Pierce continues; else stop at this hit.
			if pierce_left > 0:
				pierce_left -= 1
				if hit_player.has_method("get_hitbox_rids"):
					excluded_rids.append_array(hit_player.get_hitbox_rids())
				else:
					excluded_rids.append(hit_player.get_rid())
				cur_origin = hit_pos + cur_dir * 0.05
				continue
			break

		elif collider and collider.is_in_group("grenades") and collider.has_method("detonate"):
			if is_server:
				collider.detonate()
				if shooter_node:
					_hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), true, 0)
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
			p.take_damage.rpc_id(p.get_multiplayer_authority(), dmg, shooter_id)

func _player_from_hit_collider(collider: Node) -> Node:
	if collider == null:
		return null
	if collider.is_in_group("players"):
		return collider
	if collider.is_in_group("player_hitboxes"):
		var parent := collider.get_parent()
		if parent and parent.is_in_group("players"):
			return parent
	return null

func _is_head_hit(collider: Node) -> bool:
	return collider != null and collider.is_in_group("player_head_hitboxes")

func get_hitbox_rids() -> Array[RID]:
	var rids: Array[RID] = [get_rid()]
	for child in get_children():
		if child is CollisionObject3D and child.is_in_group("player_hitboxes"):
			rids.append(child.get_rid())
	return rids

func _spawn_bullet_blast(pos: Vector3, radius: float, color: Color) -> void:
	# Bigger blasts expand further, hold a hotter core, and pump a brighter
	# point light — stacked EXPLOSIVE ROUNDS cards should feel earth-shaking.
	var scene: Node = get_tree().current_scene
	var r_norm: float = clampf(radius / 6.0, 0.4, 2.8)
	var expand_time: float = clampf(0.16 + radius * 0.015, 0.16, 0.45)

	# 1) White-hot core flash.
	var core := MeshInstance3D.new()
	var cm := SphereMesh.new()
	cm.radius = 0.25
	cm.height = 0.5
	core.mesh = cm
	var cmat := StandardMaterial3D.new()
	cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cmat.albedo_color = Color(1.0, 0.95, 0.8, 0.92)
	cmat.emission_enabled = true
	cmat.emission = Color(1.0, 0.9, 0.55)
	cmat.emission_energy_multiplier = 9.0
	core.material_override = cmat
	core.position = pos
	scene.add_child(core)
	var ctw := core.create_tween().set_parallel(true)
	ctw.tween_property(core, "scale", Vector3.ONE * r_norm * 2.0, 0.10)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ctw.tween_property(cmat, "albedo_color", Color(1, 1, 1, 0.0), 0.13)
	ctw.tween_property(cmat, "emission_energy_multiplier", 0.0, 0.13)
	ctw.chain().tween_callback(core.queue_free)

	# 2) Colored shockwave — expands to full damage radius.
	var wave := MeshInstance3D.new()
	var wm := SphereMesh.new()
	wm.radius = 0.2
	wm.height = 0.4
	wave.mesh = wm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.55)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 6.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wave.material_override = mat
	wave.position = pos
	scene.add_child(wave)
	var tw := wave.create_tween().set_parallel(true)
	tw.tween_property(wave, "scale", Vector3.ONE * radius * 1.35, expand_time)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(color.r, color.g, color.b, 0.0), expand_time + 0.05)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, expand_time + 0.05)
	tw.chain().tween_callback(wave.queue_free)

	# 3) Point light — scales with blast.
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = clampf(6.0 + radius * 1.2, 6.0, 22.0)
	light.omni_range = radius * 2.5
	light.position = pos
	scene.add_child(light)
	var ltw := light.create_tween()
	ltw.tween_property(light, "light_energy", 0.0, clampf(0.12 + radius * 0.01, 0.12, 0.28))\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ltw.tween_callback(light.queue_free)

	# 4) Big blasts play the full explosion SFX; smaller impacts stay visual.
	if radius >= 3.5:
		SFX.explosion(pos)

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

@rpc("any_peer", "call_local", "reliable")
func _hit_confirm(is_headshot: bool, dmg: int = 0) -> void:
	# Only accept from the server.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if is_bot:
		return  # bot has no HUD
	var g := get_tree().current_scene
	if g and g.has_method("show_hitmarker"):
		g.show_hitmarker("head" if is_headshot else "body", dmg)

@rpc("any_peer", "call_local", "reliable")
func confirm_kill() -> void:
	# Server tells the killer's client to pop a kill-colored hitmarker.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	if is_bot:
		return
	var g := get_tree().current_scene
	if g and g.has_method("show_hitmarker"):
		g.show_hitmarker("kill")

func _spawn_impact(pos: Vector3, color: Color = Color(1.0, 0.9, 0.3), scale_f: float = 1.0, dmg_ratio: float = 1.0) -> void:
	var scene := get_tree().current_scene
	# Heavier guns leave a bigger crater of dust + a brighter spark, and once
	# damage is very high we add a second "heat flash" — as if the slug is
	# hot enough to burn the ground it lands in.
	var sz: float = scale_f * sqrt(dmg_ratio)
	var spark_boost: float = lerpf(1.0, 2.5, clampf((dmg_ratio - 1.0) / 4.0, 0.0, 1.0))

	# Brief colored point light — the hit "spark".
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 3.5 * scale_f * spark_boost
	light.omni_range = 2.2 * sz
	light.position = pos
	scene.add_child(light)
	var ltw := light.create_tween()
	ltw.tween_property(light, "light_energy", 0.0, 0.12) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ltw.tween_callback(light.queue_free)

	# Heat flash: a very brief, almost-white burst for high-damage hits.
	if dmg_ratio > 1.8:
		var heat := OmniLight3D.new()
		heat.light_color = Color(1.0, 0.88, 0.65)
		heat.light_energy = 6.0 + 3.0 * dmg_ratio
		heat.omni_range = 1.4 + 0.45 * dmg_ratio
		heat.position = pos
		scene.add_child(heat)
		var htw := heat.create_tween()
		htw.tween_property(heat, "light_energy", 0.0, 0.08) \
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		htw.tween_callback(heat.queue_free)

	# A handful of dust particles scattering outward and falling.
	var dust_count: int = int(round(5.0 * sqrt(dmg_ratio)))
	for i in dust_count:
		var dust := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.035 * sz
		m.height = 0.07 * sz
		m.radial_segments = 6
		m.rings = 3
		dust.mesh = m
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.72, 0.66, 0.55, 0.75)
		dust.material_override = mat
		dust.position = pos
		scene.add_child(dust)
		var dir := Vector3(
			randf_range(-1.0, 1.0),
			randf_range(0.1, 1.0),
			randf_range(-1.0, 1.0),
		).normalized()
		var end := pos + dir * randf_range(0.25, 0.7) * sz
		var tw := dust.create_tween().set_parallel(true)
		tw.tween_property(dust, "position", end, 0.35) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(0.72, 0.66, 0.55, 0.0), 0.4)
		tw.chain().tween_callback(dust.queue_free)

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
	SFX.grenade_launch(origin)
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
	SFX.melee(origin)
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
	q.collide_with_areas = true
	var shooter_node := get_parent().get_node_or_null(str(attacker_id))
	if shooter_node:
		if shooter_node.has_method("get_hitbox_rids"):
			q.exclude = shooter_node.get_hitbox_rids()
		else:
			q.exclude = [shooter_node.get_rid()]
	var result := space.intersect_ray(q)
	if result.is_empty():
		return
	var target := _player_from_hit_collider(result.collider)
	if target == null:
		return
	if target.player_id == attacker_id:
		return
	var v_fwd: Vector3 = -target.global_transform.basis.z
	var attacker_fwd: Vector3 = dir
	var backstab: bool = v_fwd.dot(attacker_fwd) > 0.4
	var dmg: int = MELEE_BACKSTAB if backstab else MELEE_DAMAGE
	target.take_damage.rpc_id(target.get_multiplayer_authority(), dmg, attacker_id)
	if shooter_node:
		_hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), backstab, dmg)

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
	if from_id != player_id and not is_bot:
		_notify_damage_source(from_id)
		SFX.hit_received()
	if health <= 0:
		died.emit(from_id)
		_report_death.rpc_id(1, from_id)

func _notify_damage_source(from_id: int) -> void:
	var attacker := get_parent().get_node_or_null(str(from_id))
	if not attacker:
		return
	var g := get_tree().current_scene
	if g and g.has_method("show_damage_direction"):
		g.show_damage_direction(attacker.global_position)

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
	health = MAX_HEALTH + weapon.max_hp_bonus
	rifle_cooldown = 0.0
	grenade_cooldown = 0.0
	melee_cooldown = 0.0
	wall_jump_cooldown = 0.0
	mag = weapon.get_mag_size()
	reloading = false
	dash_charges = MAX_DASH_CHARGES
	dash_timer = 0.0
	jumps_left = 2 + weapon.extra_jumps
	# Push the teleport to every peer immediately so they don't see us at the
	# old position for a frame while waiting for the next _physics_process.
	_broadcast_state.rpc(global_position, rotation.y)
	_last_sync_pos = global_position
	_last_sync_yaw = rotation.y

# -------------------- STATE REPLICATION --------------------

func _maybe_broadcast_state() -> void:
	if global_position.distance_squared_to(_last_sync_pos) < 0.0001 \
			and absf(rotation.y - _last_sync_yaw) < 0.001:
		return
	_last_sync_pos = global_position
	_last_sync_yaw = rotation.y
	_broadcast_state.rpc(global_position, rotation.y)

@rpc("authority", "unreliable_ordered")
func _broadcast_state(pos: Vector3, yaw: float) -> void:
	if is_multiplayer_authority():
		return
	global_position = pos
	rotation.y = yaw

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
	health = min(MAX_HEALTH + weapon.max_hp_bonus, health + amount)

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
	# Top up HP if the card just raised the cap.
	if is_multiplayer_authority():
		health = max(health, MAX_HEALTH + weapon.max_hp_bonus)
	_update_gun_visuals()
	_update_body_scale()

@rpc("any_peer", "call_local", "reliable")
func reset_weapon() -> void:
	weapon.reset()
	mag = weapon.get_mag_size()
	reloading = false
	rifle_cooldown = 0.0
	_update_gun_visuals()
	_update_body_scale()

# -------------------- GUN VISUALS --------------------

func _setup_gun_visuals() -> void:
	# Scene's GunMesh uses a shared BoxMesh sub_resource — give this player
	# its own so resizing doesn't mutate every other player's gun.
	gun_body.mesh = BoxMesh.new()
	var mat: Material = gun_body.material_override

	gun_barrel = MeshInstance3D.new()
	gun_barrel.mesh = BoxMesh.new()
	gun_barrel.material_override = mat
	muzzle.add_child(gun_barrel)

	gun_magazine = MeshInstance3D.new()
	gun_magazine.mesh = BoxMesh.new()
	gun_magazine.material_override = mat
	muzzle.add_child(gun_magazine)

func _update_gun_visuals() -> void:
	if gun_body == null or gun_barrel == null or gun_magazine == null:
		return
	var dmg_ratio: float = clampf(weapon.get_damage() / Weapon.BASE_DAMAGE, 0.6, 3.5)
	var mag_ratio: float = clampf(float(weapon.get_mag_size()) / float(Weapon.BASE_MAG_SIZE), 0.3, 5.0)
	# Lower spread = tighter aim = longer barrel. Treat near-zero (sniper) as the max.
	var acc_ratio: float = 5.0 if weapon.spread <= 0.0001 \
		else clampf(Weapon.BASE_SPREAD / weapon.spread, 0.4, 5.0)

	# Body — compact receiver, scales with damage.
	var body_w: float = 0.11 * sqrt(dmg_ratio)
	var body_h: float = 0.10 * sqrt(dmg_ratio)
	var body_d: float = 0.20 * pow(dmg_ratio, 0.4)
	(gun_body.mesh as BoxMesh).size = Vector3(body_w, body_h, body_d)
	# Front of body sits just behind the muzzle point (z = 0); body extends back (+Z in local space).
	var body_front_z: float = 0.04
	gun_body.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, body_front_z + body_d * 0.5))

	# Barrel — thin, length scales aggressively with accuracy. Sniper → ~1.2m barrel.
	var barrel_len: float = 0.24 * acc_ratio
	var barrel_thick: float = 0.045 * sqrt(dmg_ratio)
	(gun_barrel.mesh as BoxMesh).size = Vector3(barrel_thick, barrel_thick, barrel_len)
	gun_barrel.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, body_front_z - barrel_len * 0.5))

	# Magazine — hangs below body, height scales with mag size.
	var mag_h: float = 0.10 * mag_ratio
	var mag_w: float = 0.08 * sqrt(dmg_ratio)
	(gun_magazine.mesh as BoxMesh).size = Vector3(mag_w, mag_h, 0.10)
	gun_magazine.transform = Transform3D(Basis.IDENTITY,
		Vector3(0, -body_h * 0.5 - mag_h * 0.5, body_front_z + body_d * 0.35))

func _update_body_scale() -> void:
	# BodyModel holds the visual mesh parts; hitboxes are siblings under the
	# Player root. We scale visuals + hitboxes independently so the displayed
	# head/body and the physics areas stay in agreement.
	if body_model == null or head_mesh == null:
		return
	var bs: float = maxf(0.1, weapon.body_scale)
	var hs: float = maxf(0.1, weapon.head_scale)
	body_model.scale = Vector3.ONE * bs
	# Body-model scaling already magnifies the head; counter-scale so head
	# ends up at exactly `head_scale` relative to the player root.
	head_mesh.scale = Vector3.ONE * (hs / bs)
	if head_hitbox:
		head_hitbox.scale = Vector3.ONE * hs
	if torso_hitbox:
		torso_hitbox.scale = Vector3.ONE * bs
	if legs_hitbox:
		legs_hitbox.scale = Vector3.ONE * bs

# -------------------- BOT AI --------------------

func _bot_physics(delta: float) -> void:
	if frozen:
		velocity = Vector3.ZERO
		return
	_bot_shoot_cooldown = maxf(0.0, _bot_shoot_cooldown - delta)
	_bot_jump_cooldown = maxf(0.0, _bot_jump_cooldown - delta)
	_bot_dash_cooldown = maxf(0.0, _bot_dash_cooldown - delta)

	# Dash charges tick back up the same as for real players.
	if dash_charges < MAX_DASH_CHARGES:
		dash_recharge_timer += delta
		if dash_recharge_timer >= DASH_RECHARGE_TIME:
			dash_charges += 1
			dash_recharge_timer = 0.0
	else:
		dash_recharge_timer = 0.0

	# Gravity
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	if _bot_target == null or not is_instance_valid(_bot_target):
		_bot_target = _bot_find_target()
	if _bot_target == null:
		velocity.x = move_toward(velocity.x, 0.0, BOT_MOVE_SPEED * 3.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, BOT_MOVE_SPEED * 3.0 * delta)
		move_and_slide()
		_maybe_broadcast_state()
		return

	var to_target: Vector3 = _bot_target.global_position - global_position
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var dist := flat.length()

	# Yaw toward target (convention derived so local -Z aligns with flat).
	if dist > 0.05:
		var target_yaw := atan2(-flat.x, -flat.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, delta * BOT_ROT_SPEED)

	# Re-roll the movement intent every so often so the bot weaves instead of
	# marching in a straight line. Values are blended with a forced
	# approach/retreat if it drifts way off the follow distance.
	_bot_strafe_timer -= delta
	if _bot_strafe_timer <= 0.0:
		_bot_strafe_timer = randf_range(0.5, 1.6)
		_bot_strafe_side = [-1.0, -0.7, 0.0, 0.7, 1.0].pick_random()
		_bot_approach = [-0.6, 0.0, 0.0, 0.6, 1.0].pick_random()

	var fwd_dir: Vector3 = flat.normalized() if dist > 0.01 else -global_transform.basis.z
	var right_dir := Vector3(-fwd_dir.z, 0.0, fwd_dir.x)
	var chase: float = _bot_approach
	if dist > BOT_FOLLOW_DIST * 1.8:
		chase = 1.0          # too far — close the gap
	elif dist < BOT_FOLLOW_DIST * 0.45:
		chase = -0.7         # too close — back off
	var move_dir: Vector3 = fwd_dir * chase + right_dir * _bot_strafe_side
	if move_dir.length() > 1.0:
		move_dir = move_dir.normalized()
	velocity.x = move_dir.x * BOT_MOVE_SPEED
	velocity.z = move_dir.z * BOT_MOVE_SPEED

	# Occasional hop — keeps the bot moving vertically, harder to track.
	if is_on_floor() and _bot_jump_cooldown <= 0.0 and randf() < BOT_JUMP_CHANCE:
		velocity.y = JUMP_VELOCITY
		_bot_jump_cooldown = randf_range(1.2, 3.0)
		SFX.jump(global_position)

	# Occasional dash — usually in the current move direction, sometimes sideways.
	if dash_timer <= 0.0 and dash_charges > 0 and _bot_dash_cooldown <= 0.0 \
			and randf() < BOT_DASH_CHANCE:
		var wish: Vector3 = move_dir if move_dir.length_squared() > 0.01 else fwd_dir
		dash_dir = wish.normalized()
		dash_timer = DASH_TIME
		dash_charges -= 1
		_bot_dash_cooldown = randf_range(2.5, 5.5)
		SFX.dash(global_position)

	# Apply dash override if one is active (same formula as the player path).
	if dash_timer > 0.0:
		dash_timer -= delta
		velocity.x = dash_dir.x * DASH_SPEED
		velocity.z = dash_dir.z * DASH_SPEED
		velocity.y = max(velocity.y, 0.0)

	move_and_slide()
	_maybe_broadcast_state()

	# Fell off map — teleport back up.
	if global_position.y < -30.0:
		global_position = Vector3(0, 5, 0)
		_last_sync_pos = Vector3.INF  # force resync

	if _bot_shoot_cooldown <= 0.0 and _bot_has_los(_bot_target):
		_bot_shoot()
		_bot_shoot_cooldown = BOT_SHOOT_INTERVAL

func _bot_find_target() -> Node3D:
	for p in get_parent().get_children():
		if p == self:
			continue
		if not p.is_in_group("players"):
			continue
		if p.get("is_bot"):
			continue
		return p
	return null

func _bot_has_los(target: Node3D) -> bool:
	var from := global_position + Vector3.UP * 0.7
	var to: Vector3 = target.global_position + Vector3.UP * 0.4
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1  # world only
	q.exclude = get_hitbox_rids()
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()

func _bot_shoot() -> void:
	if _bot_target == null or not is_instance_valid(_bot_target):
		return
	var from := global_position + Vector3.UP * 0.7
	var to: Vector3 = _bot_target.global_position + Vector3.UP * 0.4
	var dir := (to - from).normalized()
	# Farther targets are harder to hit — spread grows with distance so the bot
	# is threatening up close and mostly plinking from across the map.
	var dist: float = from.distance_to(to)
	var dist_mult: float = 1.0 + clampf((dist - BOT_FOLLOW_DIST) / 10.0, 0.0, 3.0)
	var spread: float = BOT_SPREAD * dist_mult
	# Every so often the bot whiffs harder — keeps it from feeling laser-accurate.
	if randf() < BOT_MISS_CHANCE:
		spread *= randf_range(2.5, 5.0)
	var yaw := randf_range(-spread, spread)
	var pitch := randf_range(-spread, spread)
	dir = dir.rotated(Vector3.UP, yaw)
	var right := Vector3.UP.cross(dir)
	if right.length_squared() > 0.0001:
		dir = dir.rotated(right.normalized(), pitch)
	_rifle_fired.rpc(from, dir.normalized(), player_id)
