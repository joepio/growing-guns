extends CharacterBody3D

const Violence = preload("res://scripts/violence.gd")

# All ragdoll, death, impact, and gore logic lives in scripts/violence.gd.
# The @rpc methods + a few thin wrappers stay here because they need to live
# on this Node, but their bodies just delegate to Violence.

# --- Movement ---
const WALK_SPEED := 14.0
const AIR_ACCEL := 70.0
const GROUND_ACCEL := 100.0
const FRICTION := 8.0
const JUMP_VELOCITY := 9.0
const DOUBLE_JUMP_VELOCITY := 8.5
const WALL_JUMP_V := 10.5
const WALL_JUMP_H := 4.0
const WALL_JUMP_COOLDOWN := 0.14
const DASH_SPEED := 28.0
const DASH_TIME := 0.18
const MAX_DASH_CHARGES := 2
const DASH_RECHARGE_TIME := 3.0
const GRAVITY := 30.0
const MOUSE_SENS := 0.0022
const CONTROLLER_LOOK_SENS := 3.0
const CONTROLLER_LOOK_DEADZONE := 0.18

# --- First-person gun feel ---
const GUN_BOB_AMP_Y := 0.012        # vertical bob amplitude
const GUN_BOB_AMP_X := 0.007        # horizontal sway amplitude (half-frequency)
const GUN_JUMP_BUMP := 0.06         # downward kick on jump, decays
const GUN_STRAFE_TILT_DEG := 3.5    # max gun roll while strafing

# --- View Feel ---
const TILT_MAX_DEG := 2.5
const TILT_SPEED := 6.0

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
const MELEE_RANGE := 5.0
const MELEE_BACKSTAB := 9999  # guaranteed kill
const VFX_TRANSIENT_LIGHTS := false  # gameplay-wide override; the impact/blood
									 # paths now spawn lights based on damage instead.
const VFX_MAX_IMPACT_DUST := 12
const VFX_MAX_BLOOD_DROPS := 16
const REMOTE_INTERP_SPEED := 24.0
const REMOTE_SNAP_DISTANCE := 8.0
const MINE_RELOAD := 2.5
const MINE_FORWARD_OFFSET := 0.9
const GHOST_ALPHA := 0.06
const INVISIBLE_RELOAD := 10.0
const INVISIBLE_DURATION := 4.0
const INVISIBLE_ALPHA := 0.06

@onready var camera: Camera3D = $Camera
@onready var muzzle: Node3D = $Camera/Muzzle
@onready var body_model: Node3D = $BodyModel
@onready var blob_rig: Node3D = $BodyModel/BlobRig
@onready var blob_core: MeshInstance3D = $BodyModel/BlobRig/BlobCore
@onready var head_blob: MeshInstance3D = $BodyModel/BlobRig/HeadBlob
@onready var face_plate: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/FacePlate
@onready var eye_left: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/EyeLeft
@onready var eye_right: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/EyeRight
@onready var pupil_left: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/PupilLeft
@onready var pupil_right: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/PupilRight
@onready var hit_eye_left: Node3D = $BodyModel/BlobRig/HeadBlob/HitEyeLeft
@onready var hit_eye_right: Node3D = $BodyModel/BlobRig/HeadBlob/HitEyeRight
@onready var mouth: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/Mouth
@onready var hand_anchor: Node3D = $BodyModel/BlobRig/HandAnchor
@onready var head_hitbox: Area3D = $HeadHitbox

var _third_person_gun: Node3D = null
var _third_person_gun_rest_pos: Vector3 = Vector3.ZERO
var _third_person_gun_rest_rot: Vector3 = Vector3.ZERO
@onready var torso_hitbox: Area3D = $TorsoHitbox
@onready var legs_hitbox: Area3D = $LegsHitbox
@onready var name_label: Label3D = $NameLabel
@onready var gun_body: MeshInstance3D = $Camera/Muzzle/GunMesh
@onready var blade: MeshInstance3D = $Camera/Muzzle/Blade
var _blade_rest_transform: Transform3D
var gun_barrel: MeshInstance3D = null
var gun_magazine: MeshInstance3D = null
var _procedural_gun: Node3D = null
var _ragdoll_pieces: Array[Node] = []

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
# Round-start "rocket spawn": physics drives the descent but input is gated
# until the server flips this back off. Distinct from `frozen` because we DO
# want gravity + move_and_slide to run while it's on.
var launching: bool = false
var ghost_mode: bool = false
var invisible_mode: bool = false
var is_zooming: bool = false
var _poison_damage_left: float = 0.0
var _poison_dps: float = 0.0
var _poison_from_id: int = 0
var _poison_tick_accum: float = 0.0
var _slow_timer: float = 0.0
var _slow_mult: float = 1.0
var _phoenix_charges_left: int = 0
var _next_shot_damage_mult: float = 1.0
var _next_shot_speed_mult: float = 1.0

# Last broadcast state — avoids flooding the wire when idle.
var _last_sync_pos: Vector3 = Vector3.INF
var _last_sync_yaw: float = INF
var _remote_target_pos: Vector3 = Vector3.INF
var _remote_target_yaw: float = 0.0
var _remote_has_target := false

# Camera / gun feel — updated by fire, decayed per frame.
var look_pitch := 0.0
var recoil_pitch := 0.0
var tilt_z := 0.0
var muzzle_kick_z := 0.0
var shake_amt := 0.0
var melee_offset := Vector3.ZERO
var _muzzle_rest_pos: Vector3
var _walk_bob_phase: float = 0.0
var _gun_jump_bump: float = 0.0
var _gun_tilt_z: float = 0.0
# Long barrels sit further back against the shoulder; updated when the
# weapon changes via _update_gun_visuals.
var _gun_pull_back: Vector3 = Vector3.ZERO
# Dynamic shot-to-shot spread: each fire adds weapon.recoil_per_shot, decays
# back to zero. Combined with weapon.spread + movement bonus at fire time.
var _recoil_spread: float = 0.0
const RECOIL_DECAY_RATE := 4.0           # higher = recovers accuracy faster
const MOVEMENT_SPREAD_MAX := 0.045       # rad of extra spread at full walk speed

# Total effective spread used at fire time AND shown by the crosshair so the
# UI always matches what bullets will actually do.
func get_effective_spread() -> float:
	var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
	var movement_spread: float = clampf(horiz_speed / WALK_SPEED, 0.0, 1.4) * MOVEMENT_SPREAD_MAX
	return weapon.spread + movement_spread + _recoil_spread
var _head_hitbox_rest_y: float = 0.86
var _torso_hitbox_rest_y: float = 0.12
var _legs_hitbox_rest_y: float = -0.55
var reload_offset: Vector3 = Vector3.ZERO
var _reload_tween: Tween = null
var _mag_reload_tween: Tween = null
var _reload_audio: Node = null
var _camera_rest_pos: Vector3
var _landing_bump_y: float = 0.0
var _was_on_floor: bool = true
var _step_distance: float = 0.0
const STEP_STRIDE := 2.2  # meters of ground travel between footstep SFX
var _view_punch_rot: Vector3 = Vector3.ZERO
var _view_punch_pos: Vector3 = Vector3.ZERO
var _melee_tween: Tween = null
var _ragdoll_head: RigidBody3D = null
var _body_materials: Dictionary = {}
var _blob_rig_rest_pos: Vector3 = Vector3.ZERO
var _blob_core_rest_scale: Vector3 = Vector3.ONE
var _head_blob_rest_pos: Vector3 = Vector3.ZERO
var _head_blob_rest_scale: Vector3 = Vector3.ONE
var _hand_anchor_rest_pos: Vector3 = Vector3.ZERO
var _blob_phase: float = 0.0
var _visual_prev_pos: Vector3 = Vector3.INF
var _hit_face_timer: float = 0.0
const HIT_FACE_DURATION := 0.22

@export var player_id: int = 1
@export var player_name: String = "Player"
@export var is_bot: bool = false
@export var local_input_device: int = -1
@export var split_screen_local: bool = false

# --- Bot AI ---
const BOT_MOVE_SPEED := 8.0
const BOT_FOLLOW_DIST := 7.0
const BOT_ROT_SPEED := 6.0
const BOT_SPREAD := 0.09                 # ~5.2° — miss-prone but threatening
const BOT_MISS_CHANCE := 0.45            # fraction of shots that get huge extra spread
const BOT_JUMP_CHANCE := 0.025           # per physics tick, when on floor
const BOT_DASH_CHANCE := 0.018           # per physics tick, when charge available
const BOT_EDGE_PROBE_DIST := 1.8
const BOT_GAP_JUMP_MIN_LANDING := 4.5
const BOT_GAP_JUMP_MAX_LANDING := 12.0

var _bot_target: Node3D = null
var _bot_shoot_cooldown: float = 0.0
var _bot_strafe_timer: float = 0.0
var _bot_strafe_side: float = 0.0        # -1 left, 0 none, +1 right
var _bot_approach: float = 1.0           # -1 retreat, 0 hold, +1 chase
var _bot_jump_cooldown: float = 0.0
var _bot_dash_cooldown: float = 0.0
var _prev_local_actions: Dictionary = {}

var health: int = MAX_HEALTH
var god_mode: bool = false

signal died(killer_id: int)
signal cooldowns_changed  # emitted on local player for HUD

func _enter_tree() -> void:
	# Bots are server-owned — their player_id isn't a real peer.
	set_multiplayer_authority(1 if (is_bot or split_screen_local) else player_id)

func _ready() -> void:
	name_label.text = player_name
	_muzzle_rest_pos = muzzle.position
	_camera_rest_pos = camera.position
	# Capture authored hitbox positions so body-scaling can shift them cleanly.
	if head_hitbox:
		_head_hitbox_rest_y = head_hitbox.position.y
	if torso_hitbox:
		_torso_hitbox_rest_y = torso_hitbox.position.y
	if legs_hitbox:
		_legs_hitbox_rest_y = legs_hitbox.position.y
	_setup_gun_visuals()
	_apply_identity_cosmetics()
	_capture_body_materials()  # after gun setup so we capture the original gun material too
	_update_gun_visuals()
	_update_body_scale()
	_refresh_authority_view()
	if blob_rig:
		_blob_rig_rest_pos = blob_rig.position
	if blob_core:
		_blob_core_rest_scale = blob_core.scale
	if head_blob:
		_head_blob_rest_pos = head_blob.position
		_head_blob_rest_scale = head_blob.scale
		# Bots get a cube head — visually distinguishes them from human players
		# at a glance. Sized to match the sphere's footprint (0.42 radius).
		if is_bot:
			var box := BoxMesh.new()
			box.size = Vector3(0.78, 0.78, 0.78)
			head_blob.mesh = box
	if hand_anchor:
		_hand_anchor_rest_pos = hand_anchor.position
	_visual_prev_pos = global_position
	_set_hit_face_state(false)
	_setup_third_person_gun()
	add_to_group("players")
	# Pre-bake gib chunk meshes off-thread so the first kill doesn't hitch.
	Violence.gib_warm_tree(body_model, Violence.GIB_CHUNK_COUNT)

# Attach a gun mesh to the blob's hand anchor so third-person viewers see
# roughly where the weapon lives. The local player keeps their first-person
# Camera/Muzzle gun.
func _setup_third_person_gun() -> void:
	if hand_anchor == null:
		return
	var gun_root := Node3D.new()
	gun_root.name = "ThirdPersonGun"
	hand_anchor.add_child(gun_root)

	# Simple gun stand-in — a dark metallic box hovering beside the blob body.
	var gun := MeshInstance3D.new()
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.14, 0.14, 0.44)
	gun.mesh = body_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.18, 0.22)
	mat.metallic = 0.8
	mat.roughness = 0.3
	gun.material_override = mat
	gun.position = Vector3(0.0, -0.03, -0.18)
	gun_root.rotation_degrees = Vector3(10.0, 0.0, 0.0)
	gun_root.add_child(gun)
	_third_person_gun = gun_root
	_third_person_gun_rest_pos = gun_root.position
	_third_person_gun_rest_rot = gun_root.rotation

func _apply_identity_cosmetics() -> void:
	if head_blob == null:
		return
	var seed := _identity_seed()
	var hue := float(seed % 360) / 360.0
	var sat := 0.44 + float((seed >> 3) % 24) / 100.0
	var val := 0.72 + float((seed >> 7) % 18) / 100.0
	var skin := Color.from_hsv(hue, sat, val, 1.0)
	var face := skin.lerp(Color(1.0, 0.96, 0.88), 0.64)
	var skin_mat := _make_mat(skin, 0.95, 0.0)
	var face_mat := _make_mat(face, 0.86, 0.0)
	if blob_core:
		blob_core.material_override = skin_mat
	if head_blob:
		head_blob.material_override = skin_mat
	if face_plate:
		face_plate.material_override = face_mat

	var eye_kind := int((seed >> 11) % 3)
	var has_glasses := ((seed >> 15) & 1) == 1
	var mouth_kind := int((seed >> 16) % 3)
	_apply_eye_variant(eye_kind, face_mat)
	if has_glasses:
		_add_glasses()
	_apply_mouth_variant(mouth_kind)

func _identity_seed() -> int:
	var s := "%d:%s" % [player_id, player_name]
	var h := 2166136261
	for i in s.length():
		h = int((h ^ s.unicode_at(i)) * 16777619) & 0x7fffffff
	return h

func _make_mat(color: Color, roughness: float = 0.8, metallic: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	return mat

func _apply_eye_variant(kind: int, eyelid_mat: StandardMaterial3D) -> void:
	if eye_left == null or eye_right == null or pupil_left == null or pupil_right == null:
		return
	match kind:
		1:
			eye_left.scale.y *= 0.78
			eye_right.scale.y *= 0.78
			pupil_left.scale.y *= 0.72
			pupil_right.scale.y *= 0.72
		2:
			eye_left.scale.y *= 0.52
			eye_right.scale.y *= 0.52
			pupil_left.scale.y *= 0.45
			pupil_right.scale.y *= 0.45
			_add_eyelid(-0.14, eyelid_mat)
			_add_eyelid(0.14, eyelid_mat)

func _add_eyelid(x: float, mat: StandardMaterial3D) -> void:
	var lid := MeshInstance3D.new()
	lid.name = "BoredEyelid"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.17, 0.06, 0.025)
	lid.mesh = mesh
	lid.material_override = mat
	lid.position = Vector3(x, 0.065, -0.456)
	head_blob.add_child(lid)

func _add_glasses() -> void:
	if head_blob == null:
		return
	var mat := _make_mat(Color(0.035, 0.03, 0.025), 0.35, 0.15)
	var root := Node3D.new()
	root.name = "Glasses"
	head_blob.add_child(root)
	for x in [-0.14, 0.14]:
		_add_face_bar(root, mat, Vector3(x, 0.088, -0.482), Vector3(0.2, 0.018, 0.018))
		_add_face_bar(root, mat, Vector3(x, -0.018, -0.482), Vector3(0.2, 0.018, 0.018))
		_add_face_bar(root, mat, Vector3(x - 0.09, 0.035, -0.482), Vector3(0.018, 0.12, 0.018))
		_add_face_bar(root, mat, Vector3(x + 0.09, 0.035, -0.482), Vector3(0.018, 0.12, 0.018))
	_add_face_bar(root, mat, Vector3(0.0, 0.04, -0.485), Vector3(0.08, 0.018, 0.018))

func _add_face_bar(parent: Node3D, mat: StandardMaterial3D, pos: Vector3, size: Vector3) -> MeshInstance3D:
	var bar := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	bar.mesh = mesh
	bar.material_override = mat
	bar.position = pos
	parent.add_child(bar)
	return bar

func _apply_mouth_variant(kind: int) -> void:
	if mouth == null:
		return
	mouth.visible = kind != 2
	match kind:
		0:
			_add_mouth_corner(-0.16, true)
			_add_mouth_corner(0.16, true)
		1:
			mouth.position.y -= 0.015
			_add_mouth_corner(-0.16, false)
			_add_mouth_corner(0.16, false)
		2:
			_add_o_mouth()

func _add_mouth_corner(x: float, smile: bool) -> void:
	var corner := MeshInstance3D.new()
	corner.name = "MouthCorner"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.025, 0.085, 0.025)
	corner.mesh = mesh
	corner.material_override = mouth.material_override
	corner.position = Vector3(x, -0.135 if smile else -0.17, -0.425)
	corner.rotation.z = deg_to_rad(-34.0 if (x < 0.0) == smile else 34.0)
	corner.scale = Vector3(1.0, 0.75, 1.0)
	head_blob.add_child(corner)

func _add_o_mouth() -> void:
	var o := MeshInstance3D.new()
	o.name = "OMouth"
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.018
	mesh.outer_radius = 0.055
	mesh.rings = 12
	mesh.ring_segments = 8
	o.mesh = mesh
	o.material_override = mouth.material_override
	o.position = Vector3(0.0, -0.145, -0.43)
	o.rotation.x = PI * 0.5
	o.scale = Vector3(0.85, 1.15, 0.85)
	head_blob.add_child(o)

func _process(delta: float) -> void:
	if _ragdoll_head and is_instance_valid(_ragdoll_head):
		camera.global_transform = _ragdoll_head.global_transform
		return

	if not is_multiplayer_authority():
		_interpolate_remote_state(delta)
	_update_blob_motion(delta)
	if _hit_face_timer > 0.0:
		_hit_face_timer = maxf(0.0, _hit_face_timer - delta)
		if _hit_face_timer <= 0.0:
			_set_hit_face_state(false)
	if is_bot:
		return
	# Re-assert camera state every frame until authority is established.
	# Guards against a connection-state race where is_multiplayer_authority()
	# is false during _ready (peer id == 0 before connected_to_server fires).
	if is_multiplayer_authority() and not split_screen_local and not camera.current:
		_refresh_authority_view()

	if is_multiplayer_authority():
		var target_fov := 30.0 if is_zooming else 75.0
		camera.fov = lerp(camera.fov, target_fov, delta * 12.0)
		camera.rotation.z = lerp_angle(camera.rotation.z, deg_to_rad(tilt_z), delta * TILT_SPEED)

func _interpolate_remote_state(delta: float) -> void:
	if not _remote_has_target:
		return
	var alpha := clampf(delta * REMOTE_INTERP_SPEED, 0.0, 1.0)
	global_position = global_position.lerp(_remote_target_pos, alpha)
	rotation.y = lerp_angle(rotation.y, _remote_target_yaw, alpha)
	if global_position.distance_squared_to(_remote_target_pos) < 0.0004:
		global_position = _remote_target_pos
	if absf(angle_difference(rotation.y, _remote_target_yaw)) < 0.001:
		rotation.y = _remote_target_yaw

func _refresh_authority_view() -> void:
	if is_bot:
		# Bot is always third-person: full body visible, no camera takeover.
		camera.clear_current()
		body_model.visible = true
		name_label.visible = true
		return
	if is_multiplayer_authority():
		if split_screen_local:
			camera.clear_current()
		else:
			camera.make_current()
		body_model.visible = split_screen_local
		name_label.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		Input.use_accumulated_input = false
	else:
		camera.clear_current()
		body_model.visible = true
		name_label.visible = true
	_apply_ghost_visuals()

func _capture_body_materials() -> void:
	_body_materials.clear()
	for mesh in _body_meshes():
		_body_materials[mesh] = mesh.material_override
	# Gun meshes are added at runtime by _setup_gun_visuals() — capture their
	# rest material too so ghost mode can be reverted after respawn.
	if gun_body:
		_body_materials[gun_body] = gun_body.material_override
	if gun_barrel:
		_body_materials[gun_barrel] = gun_barrel.material_override
	if gun_magazine:
		_body_materials[gun_magazine] = gun_magazine.material_override

func _body_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if body_model == null:
		return out
	Violence.collect_meshes(body_model, out)
	return out

func _update_blob_motion(delta: float) -> void:
	if body_model == null or blob_rig == null or blob_core == null:
		return

	var prev_pos := _visual_prev_pos
	if prev_pos == Vector3.INF:
		prev_pos = global_position
	var world_delta := global_position - prev_pos
	_visual_prev_pos = global_position

	var planar_velocity := Vector3.ZERO
	if is_multiplayer_authority() or is_bot:
		planar_velocity = Vector3(velocity.x, 0.0, velocity.z)
	else:
		planar_velocity = Vector3(world_delta.x, 0.0, world_delta.z) / maxf(delta, 0.001)

	var speed := planar_velocity.length()
	var speed_ratio := clampf(speed / maxf(0.1, WALK_SPEED * weapon.move_speed_mult), 0.0, 1.8)
	var vertical_speed := velocity.y if (is_multiplayer_authority() or is_bot) else world_delta.y / maxf(delta, 0.001)
	var airborne := (not is_on_floor()) if (is_multiplayer_authority() or is_bot) else absf(vertical_speed) > 1.5
	var dash_boost := 1.0 if dash_timer > 0.0 else 0.0

	_blob_phase = wrapf(_blob_phase + delta * lerpf(1.8, 8.0, minf(speed_ratio, 1.0)), 0.0, TAU)
	var bob := sin(_blob_phase) * (0.02 + 0.04 * speed_ratio) + 0.04
	if airborne:
		bob += 0.05
	if dash_boost > 0.0:
		bob += 0.03
	var target_pos := _blob_rig_rest_pos + Vector3(0.0, bob, 0.0)
	blob_rig.position = blob_rig.position.lerp(target_pos, clampf(delta * 10.0, 0.0, 1.0))

	var local_vel := global_transform.basis.inverse() * planar_velocity
	var target_roll := deg_to_rad(clampf(-local_vel.x * 1.3, -10.0, 10.0))
	var target_pitch := deg_to_rad(clampf(-local_vel.z * 0.7 - vertical_speed * 1.6, -14.0, 14.0))
	blob_rig.rotation.x = lerp_angle(blob_rig.rotation.x, target_pitch, clampf(delta * 8.0, 0.0, 1.0))
	blob_rig.rotation.z = lerp_angle(blob_rig.rotation.z, target_roll, clampf(delta * 8.0, 0.0, 1.0))

	var floor_squash := 0.12 * minf(speed_ratio, 1.0) + 0.16 * dash_boost
	var air_stretch := 0.12 if airborne else 0.0
	var vertical_stretch := clampf(absf(vertical_speed) / 18.0, 0.0, 0.16)
	var target_scale := _blob_core_rest_scale
	target_scale.x *= 1.0 + floor_squash - air_stretch * 0.35
	target_scale.z *= 1.0 + floor_squash - air_stretch * 0.35
	target_scale.y *= 1.0 - floor_squash * 0.75 + air_stretch + vertical_stretch
	blob_core.scale = blob_core.scale.lerp(target_scale, clampf(delta * 10.0, 0.0, 1.0))

	if head_blob:
		var nod := sin(_blob_phase * 0.5 + 0.7) * (0.02 + 0.015 * speed_ratio)
		var head_target_pos := _head_blob_rest_pos + Vector3(0.0, nod + air_stretch * 0.04, -0.015 * speed_ratio)
		head_blob.position = head_blob.position.lerp(head_target_pos, clampf(delta * 8.0, 0.0, 1.0))
		head_blob.rotation.x = lerp_angle(head_blob.rotation.x, -target_pitch * 0.25, clampf(delta * 6.0, 0.0, 1.0))
		head_blob.rotation.z = lerp_angle(head_blob.rotation.z, -target_roll * 0.2, clampf(delta * 6.0, 0.0, 1.0))
		var head_scale := _head_blob_rest_scale
		head_scale.x *= 1.0 - floor_squash * 0.18 + air_stretch * 0.12
		head_scale.z *= 1.0 - floor_squash * 0.18 + air_stretch * 0.12
		head_scale.y *= 1.0 + floor_squash * 0.12 + air_stretch * 0.18
		head_blob.scale = head_blob.scale.lerp(head_scale, clampf(delta * 8.0, 0.0, 1.0))

	if hand_anchor:
		var sway := sin(_blob_phase * 1.35 + 0.8) * (0.02 + 0.04 * speed_ratio)
		var hand_target := _hand_anchor_rest_pos + Vector3(0.05 * speed_ratio, sway, -0.02 * dash_boost)
		hand_anchor.position = hand_anchor.position.lerp(hand_target, clampf(delta * 10.0, 0.0, 1.0))

func _apply_ghost_visuals() -> void:
	if body_model == null:
		return
	body_model.visible = (is_bot or split_screen_local or not is_multiplayer_authority())
	name_label.visible = not ghost_mode and not invisible_mode and (is_bot or (not split_screen_local and not is_multiplayer_authority()))
	# Hide both first-person muzzle gun and third-person gun while ghosting —
	# spectators shouldn't see their weapon, and other players shouldn't see
	# a gun floating in a translucent ghost.
	muzzle.visible = not ghost_mode
	if _third_person_gun:
		_third_person_gun.visible = not ghost_mode

	var gun_meshes: Array[MeshInstance3D] = []
	if gun_body: gun_meshes.append(gun_body)
	if gun_barrel: gun_meshes.append(gun_barrel)
	if gun_magazine: gun_meshes.append(gun_magazine)

	for mesh in _body_meshes() + gun_meshes:
		if ghost_mode:
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(0.45, 0.95, 1.0, GHOST_ALPHA)
			mat.emission_enabled = true
			mat.emission = Color(0.25, 0.75, 0.9)
			mat.emission_energy_multiplier = 0.05
			mat.metallic = 0.0
			mat.roughness = 1.0
			mesh.material_override = mat
		elif invisible_mode:
			var stealth := StandardMaterial3D.new()
			stealth.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			stealth.albedo_color = Color(0.75, 1.0, 0.9, INVISIBLE_ALPHA)
			stealth.emission_enabled = true
			stealth.emission = Color(0.45, 1.0, 0.8)
			stealth.emission_energy_multiplier = 0.08
			mesh.material_override = stealth
		else:
			mesh.material_override = _body_materials.get(mesh, mesh.material_override)

func _set_hit_face_state(active: bool) -> void:
	Violence.set_hit_face_state(self, active)

@rpc("any_peer", "call_local", "reliable")
func _show_hit_face(duration: float = HIT_FACE_DURATION) -> void:
	_hit_face_timer = maxf(_hit_face_timer, duration)
	Violence.set_hit_face_state(self, true)

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if local_input_device >= 0:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := MOUSE_SENS
		if is_zooming:
			sens *= 0.4 # Slower aim when zoomed
		rotate_y(-event.relative.x * sens)
		look_pitch = clamp(look_pitch - event.relative.y * sens, -1.4, 1.4)
		camera.rotation.x = look_pitch + recoil_pitch
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		var g := get_tree().current_scene
		if g and g.has_method("is_any_modal_open") and g.is_any_modal_open():
			return
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	_tick_status_effects(delta)

	if is_bot:
		_bot_physics(delta)
		return

	if launching:
		# Rocket-spawn descent. Constant downward velocity (set in
		# set_launching), no gravity ramp, no input, no combat. Apply the
		# tilt-down camera + shake jitter every frame; on the first floor
		# contact we end the launch ourselves and play the existing landing
		# thump scaled by impact velocity.
		var pre_impact_y: float = velocity.y
		move_and_slide()
		if not is_bot:
			camera.rotation.x = look_pitch + recoil_pitch + _view_punch_rot.x
			camera.position = _camera_rest_pos + Vector3(
				randf_range(-1.0, 1.0) * shake_amt,
				randf_range(-1.0, 1.0) * shake_amt,
				0.0,
			)
		if is_on_floor():
			launching = false
			if not is_bot:
				SFX.landing(absf(pre_impact_y), global_position)
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
	_landing_bump_y = lerp(_landing_bump_y, 0.0, delta * 10.0) # Smooth recovery
	_recoil_spread = lerp(_recoil_spread, 0.0, clampf(delta * RECOIL_DECAY_RATE, 0.0, 1.0))

	# View punch decay
	_view_punch_pos = _view_punch_pos.lerp(Vector3.ZERO, delta * 12.0)
	_view_punch_rot = _view_punch_rot.lerp(Vector3.ZERO, delta * 12.0)

	if _can_accept_gameplay_input() and (local_input_device >= 0 or not split_screen_local):
		var look_device := local_input_device if local_input_device >= 0 else 0
		var look_input := Vector2(
			Input.get_joy_axis(look_device, JOY_AXIS_RIGHT_X),
			Input.get_joy_axis(look_device, JOY_AXIS_RIGHT_Y)
		)
		if look_input.length() > CONTROLLER_LOOK_DEADZONE:
			var look_mag := inverse_lerp(CONTROLLER_LOOK_DEADZONE, 1.0, minf(look_input.length(), 1.0))
			var look_dir := look_input.normalized() * look_mag
			var sens := CONTROLLER_LOOK_SENS
			if is_zooming:
				sens *= 0.4
			rotate_y(-look_dir.x * sens * delta)
			look_pitch = clamp(look_pitch - look_dir.y * sens * delta, -1.4, 1.4)

	camera.rotation.x = look_pitch + recoil_pitch + _view_punch_rot.x
	camera.rotation.y = _view_punch_rot.y
	camera.rotation.z = deg_to_rad(tilt_z) + _view_punch_rot.z

	# --- Gun feel: walk bob, jump bump, strafe tilt ---
	# Phase advances by π per STEP_STRIDE meters travelled — one bob per
	# footstep, so the gun visibly thumps in sync with the step audio.
	var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
	var moved_this_tick: float = horiz_speed * delta
	var bob_intensity: float = 0.0
	if is_on_floor() and horiz_speed > 0.5:
		bob_intensity = clampf(horiz_speed / WALK_SPEED, 0.0, 1.4)
		_walk_bob_phase += (moved_this_tick / STEP_STRIDE) * PI
	var bob_y: float = sin(_walk_bob_phase) * GUN_BOB_AMP_Y * bob_intensity
	# Horizontal sway runs at half the vertical frequency — classic figure-8 feel.
	var bob_x: float = sin(_walk_bob_phase * 0.5) * GUN_BOB_AMP_X * bob_intensity
	_gun_jump_bump = lerp(_gun_jump_bump, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	# Tilt the gun proportional to actual lateral velocity, not button state —
	# blocked-against-a-wall strafe shouldn't tilt, momentum-only sideways slide
	# should. velocity.dot(basis.x) is positive when sliding right.
	var gun_lateral_factor: float = clampf(velocity.dot(global_transform.basis.x) / WALK_SPEED, -1.0, 1.0)
	_gun_tilt_z = lerp(_gun_tilt_z, deg_to_rad(gun_lateral_factor * GUN_STRAFE_TILT_DEG), clampf(delta * 8.0, 0.0, 1.0))

	muzzle.position = _muzzle_rest_pos + Vector3(bob_x, bob_y - _gun_jump_bump, muzzle_kick_z) + melee_offset + reload_offset + _gun_pull_back
	# Don't fight the melee tween while it's running.
	if not (_melee_tween and _melee_tween.is_valid()):
		muzzle.rotation.z = _gun_tilt_z
	# Height scales with body_scale (and the per-axis Y warp) so the viewpoint
	# follows the taller head — SLENDERMAN sees the world from way up high.
	var cam_y: float = (_camera_rest_pos.y * maxf(0.1, weapon.body_scale) * maxf(0.1, weapon.body_scale_axes.y)) - _landing_bump_y
	camera.position = Vector3(
		_camera_rest_pos.x + randf_range(-1.0, 1.0) * shake_amt,
		cam_y + randf_range(-1.0, 1.0) * shake_amt,
		_camera_rest_pos.z,
	) + _view_punch_pos # Apply hit punch offset
	# --- Gravity ---
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		# Detect landing
		if not _was_on_floor:
			var impact_vel := absf(velocity.y)
			# Scale bump by impact velocity (e.g. 10m/s -> 0.2m dip)
			_landing_bump_y = clampf(impact_vel * 0.02, 0.0, 0.4)
			if not ghost_mode: SFX.landing(impact_vel, global_position)

		# Default: 1 ground jump + 1 air double-jump = 2 total.
		# ACROBAT and similar cards extend this via weapon.extra_jumps.
		jumps_left = 2 + weapon.extra_jumps

	_was_on_floor = is_on_floor()

	# --- Jump / wall-jump / double-jump ---
	# Wall-jump takes priority over double-jump so you can chain WJ → WJ → dash → WJ
	# to climb a building. Each WJ imparts strong up + gentle outward push, so the
	# player must strafe/dash back toward the wall to chain.
	var jump_pressed := _action_just_pressed_local("jump")
	var dash_pressed := _action_just_pressed_local("dash")
	var shoot_pressed := _action_pressed_local("shoot")
	var shoot_just_pressed := _action_just_pressed_local("shoot")
	var reload_pressed := _action_just_pressed_local("reload")
	var special_pressed := _action_just_pressed_local("shoot_grenade")

	if jump_pressed:
		if is_on_floor():
			velocity.y = JUMP_VELOCITY
			jumps_left = 1 + weapon.extra_jumps
			_gun_jump_bump = GUN_JUMP_BUMP
			if not ghost_mode: SFX.jump(global_position)
		elif is_on_wall() and wall_jump_cooldown <= 0.0:
			var n := get_wall_normal()
			velocity.y = WALL_JUMP_V
			velocity.x += n.x * WALL_JUMP_H
			velocity.z += n.z * WALL_JUMP_H
			wall_jump_cooldown = WALL_JUMP_COOLDOWN
			jumps_left = 1 + weapon.extra_jumps  # wall-jump refreshes all air-jumps
			_gun_jump_bump = GUN_JUMP_BUMP
			if not ghost_mode: SFX.jump(global_position)
		elif jumps_left > 0:
			velocity.y = DOUBLE_JUMP_VELOCITY
			jumps_left -= 1
			_gun_jump_bump = GUN_JUMP_BUMP * 0.7
			if not ghost_mode: SFX.jump(global_position)

	# --- Dash ---
	if dash_pressed and dash_charges > 0:
		var input_dir := _input_vector()
		if input_dir == Vector3.ZERO:
			input_dir = -global_transform.basis.z
		dash_dir = input_dir.normalized()
		dash_timer = DASH_TIME
		dash_charges -= 1
		if not ghost_mode: SFX.dash(global_position)

	# --- Movement ---
	# Camera roll keys off lateral velocity so tilt fades when the player is
	# blocked, slows naturally with momentum carryover, and amps up during a
	# sideways dash. (Sign matches the old input-based version: +basis.x dot
	# velocity > 0 when strafing right → positive tilt_z.)
	var lateral_factor: float = clampf(velocity.dot(global_transform.basis.x) / WALK_SPEED, -1.0, 1.0)
	tilt_z = lateral_factor * TILT_MAX_DEG

	var wish_dir := _input_vector()
	var current_walk_speed := WALK_SPEED * weapon.move_speed_mult * _slow_mult
	var target_vel := wish_dir * current_walk_speed

	# Horizontal velocity only for momentum calculations
	var horizontal_vel := Vector3(velocity.x, 0.0, velocity.z)
	var is_speeding := horizontal_vel.length() > current_walk_speed + 0.1

	var accel: float
	if dash_timer > 0.0:
		dash_timer -= delta
		velocity.y = max(velocity.y, 0.0)
		# Taper dash speed at the end (last 50% of duration).
		var dash_factor := clampf(dash_timer / (DASH_TIME * 0.5), 0.0, 1.0)
		var dash_vel := dash_dir * DASH_SPEED
		# Blend between dash velocity and walk velocity.
		target_vel = target_vel.lerp(dash_vel, dash_factor)
		accel = 2000.0 # Snap to dash trajectory
	elif is_on_floor():
		# If we're moving faster than walk speed (e.g. from explosion), use low friction
		# instead of high acceleration to stop us.
		if is_speeding and wish_dir.dot(horizontal_vel.normalized()) <= 0.5:
			accel = FRICTION
		else:
			accel = GROUND_ACCEL
	else:
		accel = AIR_ACCEL

	velocity.x = move_toward(velocity.x, target_vel.x, accel * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, accel * delta)

	if is_on_floor() and wish_dir == Vector3.ZERO and dash_timer <= 0.0 and not is_speeding:
		velocity.x = move_toward(velocity.x, 0.0, FRICTION * delta * current_walk_speed * 0.1)
		velocity.z = move_toward(velocity.z, 0.0, FRICTION * delta * current_walk_speed * 0.1)
	move_and_slide()
	_maybe_broadcast_state()
	_tick_footsteps(delta)

	# --- Combat actions ---
	# Hold LMB to keep firing — the weapon's fire_interval gates the cadence.
	var can_fire := _can_accept_gameplay_input()
	var fire_input := shoot_pressed and can_fire
	if ghost_mode:
		fire_input = false
		if shoot_just_pressed and grenade_cooldown <= 0.0 and can_fire:
			grenade_cooldown = MINE_RELOAD
			_place_mine()
	if fire_input and not reloading and mag > 0 and rifle_cooldown <= 0.0:
		rifle_cooldown = weapon.get_fire_interval()
		mag -= 1
		_fire_rifle()
		# Schedule the bolt-cycling click for the gap before the next shot.
		# Skip on very fast weapons (uzi-class) where the click would just
		# muddy the rapid bang stream.
		var fi: float = weapon.get_fire_interval()
		if fi >= 0.18:
			var click_delay: float = minf(fi * 0.45, 0.13)
			get_tree().create_timer(click_delay).timeout.connect(func() -> void:
				if is_instance_valid(self) and muzzle:
					SFX.next_round(muzzle.global_position))
		if mag <= 0:
			_start_reload()
	elif shoot_just_pressed and can_fire and not ghost_mode and (reloading or mag <= 0):
		# Trigger pulled while the gun isn't ready — the dull "click of nothing".
		if muzzle:
			SFX.empty_chamber(muzzle.global_position)
	if reload_pressed and not ghost_mode and can_fire:
		_start_reload()
	if special_pressed and not ghost_mode and can_fire:
		if weapon.special == Weapon.SPECIAL_ZOOM:
			is_zooming = !is_zooming
		elif grenade_cooldown <= 0.0:
			_use_special()

	if weapon.special != Weapon.SPECIAL_ZOOM:
		is_zooming = false # Auto-cancel zoom if weapon special changes (e.g. card reset)

	# --- Fell off the map ---
	_handle_fell_off_map()

func _input_vector() -> Vector3:
	var input := _move_vector()
	var dir := (global_transform.basis * Vector3(input.x, 0.0, input.y))
	dir.y = 0.0
	return dir

func _can_accept_gameplay_input() -> bool:
	return split_screen_local or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

func _handle_fell_off_map() -> void:
	if global_position.y >= -30.0:
		return
	if ghost_mode:
		global_position = Vector3(0, 5, 0)
		velocity = Vector3.ZERO
		_last_sync_pos = Vector3.INF
	else:
		var lethal_amount: int = max(health, MAX_HEALTH)
		_apply_damage(lethal_amount, player_id)


func handle_environmental_death(_reason: String = "void") -> void:
	# Called by external triggers (lava Area3D, future hazards) when the
	# player crosses into a lethal volume. Each peer's local hitbox fires its
	# own area-entered signal, so the authority guard prevents duplicate
	# damage. Self-attribution keeps it out of the kill-credit log without
	# inventing a fake from_id.
	if not is_multiplayer_authority():
		return
	if ghost_mode or god_mode or health <= 0 or frozen or launching:
		return
	var lethal_amount: int = max(health, MAX_HEALTH)
	_apply_damage(lethal_amount, player_id)

func _move_vector() -> Vector2:
	if local_input_device < 0:
		return Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var raw := Vector2(
		Input.get_joy_axis(local_input_device, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(local_input_device, JOY_AXIS_LEFT_Y)
	)
	if raw.length() < 0.18:
		return Vector2.ZERO
	return raw.limit_length(1.0)

func _move_axis_x() -> float:
	if local_input_device < 0:
		return Input.get_axis("move_right", "move_left")
	var x := Input.get_joy_axis(local_input_device, JOY_AXIS_LEFT_X)
	return 0.0 if absf(x) < 0.18 else x

func _action_pressed_local(action: StringName) -> bool:
	if local_input_device < 0:
		return Input.is_action_pressed(action)
	match action:
		&"shoot":
			return Input.get_joy_axis(local_input_device, JOY_AXIS_TRIGGER_RIGHT) > 0.35
		&"shoot_grenade":
			return Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_RIGHT_SHOULDER) \
				or Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_B)
		&"jump":
			return Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_LEFT_SHOULDER) \
				or Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_A)
		&"reload":
			return Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_X)
		&"dash":
			return Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_LEFT_STICK)
	return false

func _action_just_pressed_local(action: StringName) -> bool:
	if local_input_device < 0:
		return Input.is_action_just_pressed(action)
	var pressed := _action_pressed_local(action)
	var was_pressed := bool(_prev_local_actions.get(action, false))
	_prev_local_actions[action] = pressed
	return pressed and not was_pressed

# -------------------- RIFLE (hitscan) --------------------

func _fire_rifle() -> void:
	var cam_origin: Vector3 = camera.global_position
	var cam_dir: Vector3 = -camera.global_transform.basis.z
	# Bullet visually leaves the gun, but aims at whatever the crosshair sees —
	# raycast from the camera, then point the muzzle at that hit point. Far
	# enough away the parallax is invisible; close range stays believable.
	var origin: Vector3 = muzzle.global_position if muzzle else cam_origin
	var aim_dist: float = RIFLE_RANGE
	var space := get_world_3d().direct_space_state
	var aim_q := PhysicsRayQueryParameters3D.create(cam_origin, cam_origin + cam_dir * aim_dist)
	aim_q.collision_mask = 1 | 2  # world + players
	aim_q.collide_with_areas = true
	aim_q.exclude = get_hitbox_rids()
	var aim_hit := space.intersect_ray(aim_q)
	var aim_point: Vector3 = aim_hit.position if not aim_hit.is_empty() else (cam_origin + cam_dir * aim_dist)
	var base_dir: Vector3 = (aim_point - origin).normalized()
	# Local feel (authority-only; these fields are driven by the local physics loop).
	# Scale recoil and kick by the size of the bullet
	var scale_f := weapon.bullet_scale
	recoil_pitch += RIFLE_RECOIL_PITCH * scale_f
	muzzle_kick_z = max(muzzle_kick_z, RIFLE_RECOIL_KICK * scale_f)
	shake_amt = max(shake_amt, RIFLE_SHAKE * scale_f)
	rotate_y(randf_range(-RIFLE_RECOIL_YAW_JITTER, RIFLE_RECOIL_YAW_JITTER) * scale_f)
	# Physical recoil push — opposite to where you're aiming. Negligible at
	# base damage; meaningful when you stack DAMAGE / HAYMAKER / BAZOOKA.
	# Power 1.6 means scaling is gentle until damage is well above 1×.
	var dmg_ratio: float = weapon.get_damage() / Weapon.BASE_DAMAGE
	var kick_strength: float = clampf(0.4 * pow(dmg_ratio, 1.6), 0.1, 12.0)
	velocity -= cam_dir * kick_strength * float(weapon.get_shots_per_trigger())
	# Snapshot the effective spread BEFORE this shot's recoil kicks in,
	# then add the per-shot recoil so the next shot is sloppier.
	var spread: float = get_effective_spread()
	_recoil_spread += weapon.recoil_per_shot
	var shot_damage_mult := _next_shot_damage_mult
	var shot_speed_mult := _next_shot_speed_mult
	if invisible_mode and weapon.invisible_first_shot_mult > 1.0:
		shot_damage_mult *= weapon.invisible_first_shot_mult
		_end_invisible()
	_next_shot_damage_mult = 1.0
	_next_shot_speed_mult = 1.0
	# Multi-shot: fire N rays with random yaw+pitch spread (MULTI-SHOT card).
	var shots: int = weapon.get_shots_per_trigger()
	var cam_right: Vector3 = camera.global_transform.basis.x
	var cam_up: Vector3 = camera.global_transform.basis.y
	for i in shots:
		var dir := base_dir
		if spread > 0.0:
			# Radial spread, density biased toward the centre. Uniform angle
			# around the crosshair plus an r drawn from randf()² gives a
			# pleasing centre-heavy circular pattern (instead of a flat square).
			var theta: float = randf() * TAU
			var r: float = spread * randf() * randf()
			dir = base_dir.rotated(cam_up, r * cos(theta)).rotated(cam_right, r * sin(theta)).normalized()
		_rifle_fired.rpc(origin, dir, player_id, shot_damage_mult, shot_speed_mult)
	# Barrel overheating — pump in heat per shot, scaled by damage. Cooldown
	# happens passively in procedural_gun._process. Heavy / fast builds
	# steady-state into a red glow; the base gun stays under the threshold.
	if _procedural_gun and _procedural_gun.has_method("add_heat"):
		_procedural_gun.add_heat(weapon.damage_mult * float(shots))
	# Cycle the bolt — charging handles on the receiver snap back on every
	# trigger pull and slide forward over the fire interval, arriving at
	# rest exactly as the next shot snaps them back again.
	if _procedural_gun and _procedural_gun.has_method("cycle_bolt"):
		_procedural_gun.cycle_bolt(weapon.get_fire_interval())
	# Eject one brass casing per bullet — multi-barrel / multi-shot weapons
	# spit out a small burst from the same ejection port. The per-casing
	# velocity jitter inside eject_casing() keeps them from clumping.
	if _procedural_gun and _procedural_gun.has_method("eject_casing"):
		for _i in shots:
			_procedural_gun.eject_casing()

@rpc("any_peer", "call_local", "reliable")
func _rifle_fired(
	origin: Vector3,
	dir: Vector3,
	shooter_id: int,
	shot_damage_mult: float = 1.0,
	shot_speed_mult: float = 1.0,
) -> void:
	var shooter_node: Node3D = get_parent().get_node_or_null(str(shooter_id))
	var w: Weapon = shooter_node.weapon if shooter_node else Weapon.new()
	# `is_self` = the local human is the shooter. Their copy plays a 2D
	# variant with its own volume curve (no 3D bus reverb / distance shaping).
	var is_self: bool = shooter_id == multiplayer.get_unique_id()
	SFX.shot(w, origin, is_self)

	# Bench A/B: skip bullet spawning entirely (one static bool branch out
	# of bench mode). See scripts/bench_flags.gd.
	if BenchFlags.active and BenchFlags.no_bullets:
		return
	var bullet_script: GDScript = preload("res://scripts/bullet.gd")
	var bullet := Node3D.new()
	bullet.set_script(bullet_script)
	get_tree().current_scene.add_child(bullet)
	bullet.setup(origin, dir, shooter_id, w, shot_damage_mult, shot_speed_mult)
	BenchFlags.inc("bullets_spawned")

	# Muzzle flash scales with bullet size AND damage so heavy rounds boom.
	var dmg_ratio: float = clampf(w.get_damage() / Weapon.BASE_DAMAGE, 0.5, 4.0)
	var local_first_person := shooter_id == multiplayer.get_unique_id() and is_multiplayer_authority() and not is_bot
	var visual_anchor := muzzle if local_first_person else _third_person_gun
	if visual_anchor == null:
		visual_anchor = muzzle
	_spawn_muzzle_flash(w.bullet_color, w.bullet_scale * sqrt(dmg_ratio), visual_anchor, local_first_person)
	if not local_first_person:
		_spawn_third_person_casing(w)

func _apply_bullet_splash(pos: Vector3, radius: float, damage: float, shooter_id: int) -> void:
	var shooter := get_parent().get_node_or_null(str(shooter_id))
	for p: Node3D in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		if p.get("ghost_mode") == true:
			continue
		var dist: float = pos.distance_to(p.global_position)
		if dist > radius:
			continue
		# LoS check - target torso (UP 1.0m) to avoid floor clipping
		var target_pos: Vector3 = p.global_position + Vector3.UP * 1.0
		var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.1, target_pos)
		q.collision_mask = 1
		if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			continue

		var dist_ratio := dist / radius
		# Use a square-root falloff so the explosion stays 'hotter' for longer
		var falloff := clampf(1.0 - dist_ratio, 0.0, 1.0)
		var curve_falloff := sqrt(falloff)

		var dmg: int = int(damage * curve_falloff)

		# Self-damage reduction (50%) but keep full knockback
		if p.player_id == shooter_id:
			dmg = int(dmg * 0.5)

		# Explosion Knockback
		var kb_mult: float = 24.0 # Doubled base for explosions
		var weapon_kb: float = shooter.weapon.knockback if shooter and shooter.get("weapon") != null else 1.0

		var dir: Vector3 = (p.global_position - pos)
		if dir.length_squared() > 0.001:
			dir = dir.normalized()
		else:
			dir = Vector3.UP

		# Violent outward push + upward lift, using linear falloff for physics feel
		var impulse: Vector3 = (dir * kb_mult * weapon_kb * falloff) + (Vector3.UP * kb_mult * 0.8 * falloff)
		if dmg > 0:
			p.take_damage.rpc_id(
				p.get_multiplayer_authority(),
				dmg,
				shooter_id,
				pos,
				dir,
				impulse.length(),
				radius,
				falloff
			)
			if p.player_id != shooter_id and shooter and is_instance_valid(shooter):
				shooter._hit_confirm.rpc_id(shooter.get_multiplayer_authority(), false, dmg, p.global_position + Vector3.UP * 0.6)
				if shooter.has_method("_on_dealt_damage"):
					shooter._on_dealt_damage.rpc_id(shooter.get_multiplayer_authority(), dmg)
		p.apply_knockback.rpc_id(p.get_multiplayer_authority(), impulse)

@rpc("any_peer", "call_local", "reliable")
func _on_dealt_damage(damage: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	if damage <= 0:
		return
	if weapon.reload_on_hit > 0:
		mag = mini(weapon.get_mag_size(), mag + weapon.reload_on_hit)
		if mag > 0 and reloading:
			reloading = false
			rifle_cooldown = 0.0
			_stop_reload_audio()
	if weapon.special_cooldown_refund_on_hit > 0.0:
		grenade_cooldown = maxf(0.0, grenade_cooldown - weapon.special_cooldown_refund_on_hit)
	cooldowns_changed.emit()

@rpc("any_peer", "call_local", "reliable")
func apply_damage_over_time(total_damage: int, duration: float, from_id: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	if total_damage <= 0 or duration <= 0.0:
		return
	_poison_damage_left += float(total_damage)
	_poison_dps += float(total_damage) / duration
	_poison_from_id = from_id

@rpc("any_peer", "call_local", "reliable")
func apply_slow(multiplier: float, duration: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	_slow_mult = minf(_slow_mult, clampf(multiplier, 0.2, 1.0))
	_slow_timer = maxf(_slow_timer, duration)

func _tick_status_effects(delta: float) -> void:
	if _slow_timer > 0.0:
		_slow_timer = maxf(0.0, _slow_timer - delta)
		if _slow_timer <= 0.0:
			_slow_mult = 1.0
	if _poison_damage_left <= 0.0 or _poison_dps <= 0.0:
		return
	_poison_tick_accum += delta
	if _poison_tick_accum < 0.25:
		return
	var tick_dt := _poison_tick_accum
	_poison_tick_accum = 0.0
	var amount := mini(int(ceil(_poison_dps * tick_dt)), int(ceil(_poison_damage_left)))
	if amount <= 0:
		return
	_poison_damage_left -= float(amount)
	if _poison_damage_left <= 0.0:
		_poison_dps = 0.0
	_apply_damage(amount, _poison_from_id)

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
	var scene: Node = get_tree().current_scene
	var lp: Node = scene.get("local_player") if scene else null
	Violence.spawn_bullet_blast(scene, pos, radius, color, lp)

func apply_explosion_view_punch(pos: Vector3, radius: float, peak: float = 1.0) -> void:
	Violence.apply_explosion_view_punch(self, pos, radius, peak)

func _spawn_muzzle_flash(
	color: Color = Color(1.0, 0.88, 0.45),
	scale_f: float = 1.0,
	anchor: Node3D = null,
	first_person: bool = true,
) -> void:
	if anchor == null:
		anchor = muzzle
	if anchor == null:
		return
	# Directional flash: a short starburst plus a forward flame plume reads
	# better than a glowing orb and stays cheap enough for multiplayer.
	var flash_root := Node3D.new()
	flash_root.position = Vector3(0.0, 0.0, -0.35)
	flash_root.rotation.z = randf_range(0.0, TAU)
	anchor.add_child(flash_root)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.96)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 4.0 * scale_f
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var cross_mesh := BoxMesh.new()
	cross_mesh.size = Vector3(0.04 * scale_f, 0.26 * scale_f, 0.04 * scale_f)
	for angle in [0.0, PI * 0.5]:
		var arm := MeshInstance3D.new()
		arm.mesh = cross_mesh
		arm.material_override = mat
		arm.rotation.z = angle
		flash_root.add_child(arm)

	var plume := MeshInstance3D.new()
	var plume_mesh := BoxMesh.new()
	plume_mesh.size = Vector3(0.07 * scale_f, 0.07 * scale_f, 0.34 * scale_f)
	plume.mesh = plume_mesh
	plume.material_override = mat
	plume.position = Vector3(0.0, 0.0, -0.18 * scale_f)
	flash_root.add_child(plume)

	var tw := flash_root.create_tween().set_parallel(true)
	tw.tween_property(flash_root, "scale", Vector3(1.35, 0.82, 1.8), 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(flash_root, "position:z", -0.48, 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(1, 1, 1, 0.0), 0.06)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.06)
	# Keep muzzle flashes bright even when the broader transient-light VFX
	# budget is disabled; this is a tiny, short-lived light and sells the shot.
	var light := OmniLight3D.new()
	light.light_color = color.lerp(Color(1.0, 0.95, 0.82), 0.45)
	light.light_energy = 2.5 * scale_f
	light.omni_range = 4.5 * scale_f
	light.position = Vector3(0.0, 0.0, -0.42)
	flash_root.add_child(light)
	tw.tween_property(light, "light_energy", 0.0, 0.07)
	tw.chain().tween_callback(light.queue_free)

	# Small bounce light slightly behind the muzzle so the first-person weapon
	# itself catches a warm flash instead of staying flat during shots.
	var gun_light := OmniLight3D.new()
	gun_light.light_color = color.lerp(Color(1.0, 0.92, 0.8), 0.6)
	gun_light.light_energy = 1.4 * scale_f
	gun_light.omni_range = 1.7 * scale_f
	gun_light.position = Vector3(0.0, 0.0, 0.06)
	anchor.add_child(gun_light)
	tw.tween_property(gun_light, "light_energy", 0.0, 0.08)
	tw.chain().tween_callback(gun_light.queue_free)
	tw.chain().tween_callback(flash_root.queue_free)

	if not first_person:
		var rest_pos := anchor.position
		anchor.position = rest_pos + Vector3(0.0, 0.0, 0.05 * scale_f)
		var kick_tw := create_tween()
		kick_tw.tween_property(anchor, "position", rest_pos, 0.08)\
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)

func _spawn_third_person_casing(w: Weapon) -> void:
	if BenchFlags.active and BenchFlags.no_casings:
		return
	if _third_person_gun == null:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	BenchFlags.inc("casings_spawned")
	var rb := RigidBody3D.new()
	rb.mass = 0.018
	rb.collision_layer = 0
	rb.collision_mask = 1
	var pmat := PhysicsMaterial.new()
	pmat.bounce = 0.3
	pmat.friction = 0.6
	rb.physics_material_override = pmat

	var size := clampf(w.bullet_scale, 0.65, 2.2)
	if not BenchFlags.active:
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.035 * size
		cm.bottom_radius = 0.04 * size
		cm.height = 0.16 * size
		cm.radial_segments = 8
		mi.mesh = cm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.95, 0.66, 0.28)
		mat.metallic = 0.9
		mat.roughness = 0.38
		mi.material_override = mat
		mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		rb.add_child(mi)

	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.04 * size
	shape.height = 0.16 * size
	cs.shape = shape
	cs.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	rb.add_child(cs)

	var basis := _third_person_gun.global_transform.basis
	var spawn_pos := _third_person_gun.global_position + basis.x * 0.16 + basis.y * 0.08 + basis.z * -0.08
	rb.transform = Transform3D(basis, spawn_pos)
	scene.add_child(rb)

	var dir := (basis.x * 1.0 + basis.y * 1.3 + basis.z * 0.15).normalized()
	dir = (dir + Vector3(
		randf_range(-0.25, 0.25),
		randf_range(-0.1, 0.2),
		randf_range(-0.25, 0.25),
	)).normalized()
	rb.linear_velocity = dir * randf_range(2.3, 4.2)
	rb.angular_velocity = Vector3(
		randf_range(-10.0, 10.0),
		randf_range(-10.0, 10.0),
		randf_range(-10.0, 10.0),
	)
	var cleanup := get_tree().create_timer(4.0)
	cleanup.timeout.connect(func() -> void:
		if is_instance_valid(rb):
			rb.queue_free())

@rpc("any_peer", "call_local", "reliable")
func _hit_confirm(is_headshot: bool, dmg: int = 0, hit_pos: Vector3 = Vector3.INF) -> void:
	# Only accept from the server.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if is_bot:
		return  # bot has no HUD
	var g := get_tree().current_scene
	if g and g.has_method("show_hitmarker"):
		g.show_hitmarker("head" if is_headshot else "body", dmg, hit_pos)

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

func _spawn_impact(pos: Vector3, color: Color = Color(1.0, 0.9, 0.3), scale_f: float = 1.0, dmg_ratio: float = 1.0, normal: Vector3 = Vector3.UP, explosive_radius: float = 0.0) -> void:
	Violence.spawn_impact(get_tree().current_scene, pos, color, scale_f, dmg_ratio, VFX_MAX_IMPACT_DUST, normal, explosive_radius)

func _spawn_blood(pos: Vector3, dir: Vector3, dmg_ratio: float) -> void:
	Violence.spawn_blood(get_tree().current_scene, pos, dir, dmg_ratio, VFX_MAX_BLOOD_DROPS)

func _spawn_laser_tracer(from: Vector3, to: Vector3) -> void:
	Violence.spawn_laser_tracer(get_tree().current_scene, from, to)

# -------------------- RAGDOLL / DEATH --------------------

@rpc("any_peer", "call_local", "reliable")
func _ragdoll(
	push_dir: Vector3,
	force_origin: Vector3 = Vector3.INF,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
) -> void:
	Violence.do_ragdoll(self, push_dir, force_origin, gib_force, blast_radius, blast_severity, is_head)

# Hide the first-person gun mesh and turn off the hit areas so a corpse
# can't be shot or seen with a floating gun. Wrapper kept because the
# server_respawn() path also flips visuals back on.
func _set_dead_visuals(dead: bool) -> void:
	Violence.set_dead_visuals(self, dead)

@rpc("any_peer", "call_local", "reliable")
func clear_ragdoll() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	Violence.clear_ragdoll(self)
	# Restore body visibility on every peer except the local authority
	# (their body stays hidden in first-person, same as normal).
	_apply_ghost_visuals()

# -------------------- SPECIAL (RMB) --------------------

const TELEPORT_RELOAD := 2.0
const TELEPORT_RANGE := 45.0
const TELEPORT_OFFSET := 0.8
const SHIELD_RELOAD := 8.0
const SHIELD_DURATION := 2.0

var shielded: bool = false
var _shield_visual: Node3D = null
var _invisible_timer: SceneTreeTimer = null

func _use_special() -> void:
	var mult: float = weapon.special_cooldown_mult
	match weapon.special:
		Weapon.SPECIAL_TELEPORT:
			grenade_cooldown = TELEPORT_RELOAD * mult
		Weapon.SPECIAL_SHIELD:
			grenade_cooldown = SHIELD_RELOAD * mult
		Weapon.SPECIAL_INVISIBLE:
			grenade_cooldown = INVISIBLE_RELOAD * mult
		Weapon.SPECIAL_SWORD:
			grenade_cooldown = MELEE_RELOAD * mult
		_:
			grenade_cooldown = GRENADE_RELOAD * mult
	_apply_special_mods_on_use()
	_activate_special_effect(false)
	for i in weapon.special_echo_count:
		var delay := 0.16 * float(i + 1)
		get_tree().create_timer(delay).timeout.connect(func() -> void:
			if is_instance_valid(self) and not ghost_mode and health > 0:
				_activate_special_effect(true))

func _apply_special_mods_on_use() -> void:
	if weapon.special_reload_amount > 0:
		mag = mini(weapon.get_mag_size(), mag + weapon.special_reload_amount)
		if mag > 0 and reloading:
			reloading = false
			rifle_cooldown = 0.0
			_stop_reload_audio()
	if weapon.special_empower_damage > 1.0 or weapon.special_empower_speed > 1.0:
		_next_shot_damage_mult = maxf(_next_shot_damage_mult, weapon.special_empower_damage)
		_next_shot_speed_mult = maxf(_next_shot_speed_mult, weapon.special_empower_speed)
	cooldowns_changed.emit()

func _activate_special_effect(is_echo: bool) -> void:
	match weapon.special:
		Weapon.SPECIAL_TELEPORT:
			_use_teleport()
		Weapon.SPECIAL_SHIELD:
			_use_shield()
		Weapon.SPECIAL_INVISIBLE:
			if not is_echo:
				_use_invisible()
		Weapon.SPECIAL_SWORD:
			_swing_melee()
		_:
			_fire_grenade()

# -------------------- RELOAD --------------------

func _start_reload() -> void:
	if reloading:
		return
	if mag >= weapon.get_mag_size():
		return
	reloading = true
	var duration := weapon.get_reload_time()
	rifle_cooldown = duration
	_stop_reload_audio()
	_reload_started.rpc(duration)

@rpc("any_peer", "call_local", "reliable")
func _reload_started(duration: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1 and sender != get_multiplayer_authority():
		return
	var local_first_person := is_multiplayer_authority() and not is_bot
	if local_first_person:
		_animate_reload(duration)
		_stop_reload_audio()
		_reload_audio = SFX.reload(duration)
	else:
		_animate_third_person_reload(duration)
		_stop_reload_audio()
		var at := _third_person_gun.global_position if _third_person_gun else global_position
		_reload_audio = SFX.reload(duration, at)

func _stop_reload_audio() -> void:
	if _reload_audio and is_instance_valid(_reload_audio):
		_reload_audio.queue_free()
	_reload_audio = null

func _animate_reload(duration: float) -> void:
	if muzzle == null:
		return
	if _reload_tween and _reload_tween.is_valid():
		_reload_tween.kill()
	if _mag_reload_tween and _mag_reload_tween.is_valid():
		_mag_reload_tween.kill()
	reload_offset = Vector3.ZERO

	# Phased timeline (fractions of `duration`):
	#   0.00–0.18  gun rises + tilts back
	#   0.12–0.28  magazine drops out (overlaps with gun rise tail)
	#   0.28–0.45  gun sways right
	#   0.45–0.62  gun sways back to centre
	#   0.55–0.70  magazine slides back in (overlaps end of sway)
	#   0.70–0.92  gun lowers + levels out
	var gun_up := Vector3(0.0, 0.14, -0.02)
	var gun_up_right := gun_up + Vector3(0.06, 0.0, 0.0)
	var tilt_rad: float = deg_to_rad(22.0)

	_reload_tween = create_tween().set_parallel(true)
	# Rise + tilt.
	_reload_tween.tween_method(_set_reload_offset, Vector3.ZERO, gun_up, duration * 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_reload_tween.tween_property(muzzle, "rotation:x", tilt_rad, duration * 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# Sway right.
	_reload_tween.tween_method(_set_reload_offset, gun_up, gun_up_right, duration * 0.17) \
		.set_delay(duration * 0.28).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Sway back to centre.
	_reload_tween.tween_method(_set_reload_offset, gun_up_right, gun_up, duration * 0.17) \
		.set_delay(duration * 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Lower + level out.
	_reload_tween.tween_method(_set_reload_offset, gun_up, Vector3.ZERO, duration * 0.22) \
		.set_delay(duration * 0.70).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_reload_tween.tween_property(muzzle, "rotation:x", 0.0, duration * 0.22) \
		.set_delay(duration * 0.70).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

	# Magazine drop + return on its own timeline.
	var mag_node: Node3D = null
	if _procedural_gun:
		mag_node = _procedural_gun.get_node_or_null("Magazine") as Node3D
	if mag_node:
		var mag_rest_pos: Vector3 = mag_node.position
		var mag_drop: Vector3 = mag_rest_pos + Vector3(0, -1.2, 0)
		_mag_reload_tween = create_tween().set_parallel(true)
		_mag_reload_tween.tween_property(mag_node, "position", mag_drop, duration * 0.16) \
			.set_delay(duration * 0.12).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_mag_reload_tween.tween_property(mag_node, "position", mag_rest_pos, duration * 0.15) \
			.set_delay(duration * 0.55).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _set_reload_offset(v: Vector3) -> void:
	reload_offset = v

func _animate_third_person_reload(duration: float) -> void:
	if _third_person_gun == null:
		return
	_third_person_gun.position = _third_person_gun_rest_pos
	_third_person_gun.rotation = _third_person_gun_rest_rot
	var lift := _third_person_gun_rest_pos + Vector3(0.0, 0.1, 0.04)
	var tilt := _third_person_gun_rest_rot + Vector3(deg_to_rad(-22.0), deg_to_rad(10.0), deg_to_rad(7.0))
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_third_person_gun, "position", lift, duration * 0.22)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(_third_person_gun, "rotation", tilt, duration * 0.22)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(_third_person_gun, "position", _third_person_gun_rest_pos, duration * 0.24)\
		.set_delay(duration * 0.68).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_property(_third_person_gun, "rotation", _third_person_gun_rest_rot, duration * 0.24)\
		.set_delay(duration * 0.68).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

# -------------------- TELEPORT --------------------

func _use_teleport() -> void:
	var origin: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * TELEPORT_RANGE)
	q.collision_mask = 1  # world only
	q.exclude = get_hitbox_rids() if has_method("get_hitbox_rids") else [get_rid()]
	var result := space.intersect_ray(q)
	var target: Vector3
	if result.is_empty():
		target = origin + dir * TELEPORT_RANGE
	else:
		target = result.position + result.normal * TELEPORT_OFFSET
	var from: Vector3 = global_position
	_teleport_fx.rpc(from, target)
	global_position = target
	velocity = Vector3.ZERO
	if weapon.teleport_blast_radius > 0.0:
		_request_special_blast.rpc_id(1, from, weapon.teleport_blast_radius, 55.0, player_id, weapon.bullet_color)
		_request_special_blast.rpc_id(1, target, weapon.teleport_blast_radius, 55.0, player_id, weapon.bullet_color)
	_broadcast_state.rpc(global_position, rotation.y)
	_last_sync_pos = global_position
	_last_sync_yaw = rotation.y

@rpc("authority", "call_local", "reliable")
func _teleport_fx(from_pos: Vector3, to_pos: Vector3) -> void:
	_spawn_teleport_vfx(from_pos)
	_spawn_teleport_vfx(to_pos)

func _spawn_teleport_vfx(pos: Vector3) -> void:
	var scene := get_tree().current_scene
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.2
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.7, 0.3, 1.0, 0.6)
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.3, 1.0)
	mat.emission_energy_multiplier = 6.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mat
	mesh.position = pos
	scene.add_child(mesh)
	var tw := mesh.create_tween().set_parallel(true)
	tw.tween_property(mesh, "scale", Vector3.ONE * 3.0, 0.3)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(0.7, 0.3, 1.0, 0.0), 0.35)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.35)
	tw.chain().tween_callback(mesh.queue_free)
	if VFX_TRANSIENT_LIGHTS:
		var light := OmniLight3D.new()
		light.light_color = Color(0.7, 0.3, 1.0)
		light.light_energy = 5.0
		light.omni_range = 4.0
		light.position = pos
		scene.add_child(light)
		var ltw := light.create_tween()
		ltw.tween_property(light, "light_energy", 0.0, 0.3)
		ltw.tween_callback(light.queue_free)

# -------------------- SHIELD --------------------

func _use_shield() -> void:
	_shield_on.rpc(SHIELD_DURATION)
	if weapon.shield_pulse_damage > 0.0:
		_request_special_blast.rpc_id(1, global_position, 5.5, weapon.shield_pulse_damage, player_id, Color(0.35, 0.75, 1.0))

func _use_invisible() -> void:
	_invisible_on.rpc(INVISIBLE_DURATION)

@rpc("any_peer", "call_local", "reliable")
func _request_special_blast(pos: Vector3, radius: float, damage: float, shooter_id: int, color: Color) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != 0 and multiplayer.get_remote_sender_id() != shooter_id:
		return
	_spawn_bullet_blast(pos, radius, color)
	_apply_bullet_splash(pos + Vector3.UP * 0.1, radius, damage, shooter_id)

@rpc("authority", "call_local", "reliable")
func _invisible_on(duration: float) -> void:
	invisible_mode = true
	_apply_ghost_visuals()
	if _invisible_timer:
		# timer objects are fire-and-forget; just invalidate by replacing reference
		_invisible_timer = null
	_invisible_timer = get_tree().create_timer(duration)
	_invisible_timer.timeout.connect(_end_invisible, CONNECT_ONE_SHOT)

func _end_invisible() -> void:
	invisible_mode = false
	_invisible_timer = null
	_apply_ghost_visuals()

@rpc("authority", "call_local", "reliable")
func _shield_on(duration: float) -> void:
	shielded = true
	if _shield_visual and is_instance_valid(_shield_visual):
		_shield_visual.queue_free()
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.3
	sphere.height = 2.6
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var is_me := is_multiplayer_authority() and not is_bot
	var base_alpha := 0.04 if is_me else 0.25
	var base_emission := 0.4 if is_me else 1.6

	mat.albedo_color = Color(0.35, 0.75, 1.0, base_alpha)
	mat.emission_enabled = true
	mat.emission = Color(0.35, 0.75, 1.0)
	mat.emission_energy_multiplier = base_emission
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mat
	add_child(mesh)
	_shield_visual = mesh
	# Fade out over the last 30% of the duration.
	var fade_start := duration * 0.7
	var fade_dur := duration - fade_start
	var tw := mesh.create_tween().set_parallel(true)
	tw.tween_property(mat, "albedo_color", Color(0.35, 0.75, 1.0, 0.0), fade_dur).set_delay(fade_start)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, fade_dur).set_delay(fade_start)
	get_tree().create_timer(duration).timeout.connect(_end_shield)
func _end_shield() -> void:
	shielded = false
	if _shield_visual and is_instance_valid(_shield_visual):
		_shield_visual.queue_free()
	_shield_visual = null

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

func _place_mine() -> void:
	var pos := _mine_position()
	if multiplayer.is_server():
		var uname := "M_%d_%d" % [player_id, Time.get_ticks_usec()]
		_spawn_mine.rpc(pos, player_id, uname)
	else:
		_request_mine.rpc_id(1, pos)

func _mine_position() -> Vector3:
	var start := global_position + Vector3.UP * 0.6 - global_transform.basis.z * MINE_FORWARD_OFFSET
	var end := start + Vector3.DOWN * 3.0
	var q := PhysicsRayQueryParameters3D.create(start, end)
	q.collision_mask = 1
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return start + Vector3.DOWN * 0.6
	return Vector3(hit.position.x, hit.position.y + 0.12, hit.position.z)

@rpc("any_peer", "reliable")
func _request_mine(pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = player_id
	var p := get_parent().get_node_or_null(str(sender))
	if p == null or p.get("ghost_mode") != true:
		return
	var uname := "M_%d_%d" % [sender, Time.get_ticks_usec()]
	_spawn_mine.rpc(pos, sender, uname)

@rpc("any_peer", "call_local", "reliable")
func _spawn_mine(pos: Vector3, shooter: int, uname: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	var scene: PackedScene = load("res://scenes/grenade.tscn")
	var g := scene.instantiate()
	g.name = uname
	g.shooter_id = shooter
	g.is_mine = true
	get_tree().current_scene.add_child(g)
	g.global_position = pos
	g.freeze = true
	g.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	g.scale = Vector3(1.35, 0.35, 1.35)
	var mesh := g.get_node_or_null("Mesh")
	if mesh is MeshInstance3D:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.05, 0.35, 0.32, 0.78)
		mat.emission_enabled = true
		mat.emission = Color(0.0, 0.9, 0.75)
		mat.emission_energy_multiplier = 0.45
		(mesh as MeshInstance3D).material_override = mat

	var shooter_node: Node3D = get_parent().get_node_or_null(str(shooter))
	if shooter_node == null or shooter_node.get("ghost_mode") != true:
		SFX.mine_plant(pos)

func _spawn_impact_mine(pos: Vector3, shooter: int) -> void:
	if not multiplayer.is_server():
		return
	var uname := "IM_%d_%d" % [shooter, Time.get_ticks_usec()]
	_spawn_mine.rpc(pos, shooter, uname)

# -------------------- MELEE --------------------

func _swing_melee() -> void:
	var origin: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	_melee_swung.rpc(origin, dir, player_id)

@rpc("any_peer", "call_local", "reliable")
func _melee_swung(origin: Vector3, dir: Vector3, attacker_id: int) -> void:
	var shooter_node := get_parent().get_node_or_null(str(attacker_id))
	var w: Weapon = shooter_node.weapon if shooter_node else Weapon.new()

	SFX.melee(origin, w.get_melee_damage())
	# Gun swing + blade trail play on every peer.
	_animate_gun_slash(w.melee_scale)
	_spawn_slice_trail(origin, dir, w.melee_scale)
	# Camera shake only for the attacker.
	if is_multiplayer_authority():
		shake_amt = max(shake_amt, 0.035 * w.melee_scale)
	# Only the server runs hit detection.
	if not multiplayer.is_server():
		return
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * MELEE_RANGE * w.melee_scale)
	q.collision_mask = 1 | 2
	q.collide_with_areas = true
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
	if target.get("ghost_mode") == true:
		return
	if target.player_id == attacker_id:
		return
	var v_fwd: Vector3 = -target.global_transform.basis.z
	var attacker_fwd: Vector3 = dir
	var backstab: bool = v_fwd.dot(attacker_fwd) > 0.4
	var dmg: int = MELEE_BACKSTAB if backstab else w.get_melee_damage()
	var melee_force := w.knockback if w.knockback > 0.0 else w.get_melee_damage() * 0.06
	target.take_damage.rpc_id(
		target.get_multiplayer_authority(),
		dmg,
		attacker_id,
		result.position,
		dir.normalized(),
		melee_force,
		0.0
	)
	if w.knockback > 0.0:
		var melee_impulse: Vector3 = dir.normalized() * w.knockback + Vector3.UP * w.knockback * 0.25
		target.apply_knockback.rpc_id(target.get_multiplayer_authority(), melee_impulse)
	if shooter_node:
		_hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), backstab, dmg, result.position)
		if shooter_node.has_method("_on_dealt_damage"):
			shooter_node._on_dealt_damage.rpc_id(shooter_node.get_multiplayer_authority(), dmg)

func _animate_gun_slash(m_scale: float = 1.0) -> void:
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
	var slash_pos := Vector3(-0.28, -0.16, -0.2) * m_scale # shove gun left+down+forward
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

func _spawn_slice_trail(origin: Vector3, dir: Vector3, m_scale: float = 1.0) -> void:
	# A bright emissive bar placed in world-space along the diagonal arc the
	# blade sweeps through. Grows outward on X (length) to suggest speed, then
	# fades out. Visible to every peer because it lives in the world.
	var trail := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.4 * m_scale, 0.07 * m_scale, 0.04 * m_scale)
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

	var light: OmniLight3D = null
	if VFX_TRANSIENT_LIGHTS:
		light = OmniLight3D.new()
		light.light_color = Color(0.75, 0.9, 1.0)
		light.light_energy = 3.5 * m_scale
		light.omni_range = 5.0 * m_scale
		trail.add_child(light)

	get_tree().current_scene.add_child(trail)
	trail.global_position = origin + dir * 1.6 * m_scale
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
	if light:
		tw.tween_property(light, "light_energy", 0.0, 0.06)
	tw.chain().tween_callback(trail.queue_free)

# -------------------- DAMAGE / DEATH --------------------

@rpc("any_peer", "call_local", "reliable")
func take_damage(
	amount: int,
	from_id: int,
	force_origin: Vector3 = Vector3.INF,
	hit_dir: Vector3 = Vector3.ZERO,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
) -> void:
	if not is_multiplayer_authority():
		return
	_apply_damage(amount, from_id, force_origin, hit_dir, gib_force, blast_radius, blast_severity, is_head)

func _apply_damage(
	amount: int,
	from_id: int,
	force_origin: Vector3 = Vector3.INF,
	hit_dir: Vector3 = Vector3.ZERO,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
) -> void:
	if ghost_mode or frozen or health <= 0 or god_mode:
		return
	if shielded:
		return  # SHIELD special absorbs the hit
	health = max(0, health - amount)
	var game_scene := get_tree().current_scene
	if game_scene and game_scene.has_method("_report_player_damage"):
		if multiplayer.is_server():
			game_scene._report_player_damage(player_id, from_id, amount, health)
		else:
			game_scene._report_player_damage.rpc_id(1, player_id, from_id, amount, health)
	_show_hit_face.rpc(HIT_FACE_DURATION)
	if from_id != player_id and not is_bot:
		_notify_damage_source(from_id)
		# Scale feedback by damage so a 1hp poison tick is a whisper and a
		# 50hp shotgun hit slams the camera. 25 is "normal hit" — feels like
		# the current pre-scaling response.
		var hit_intensity: float = clampf(float(amount) / 25.0, 0.04, 2.0)
		SFX.hit_received(hit_intensity)

		# View punch: shift camera in the direction of the hit, scaled by
		# the same intensity so poison ticks stop yanking the camera.
		var attacker := get_parent().get_node_or_null(str(from_id))
		if attacker and is_multiplayer_authority():
			var attacker_hit_dir: Vector3 = (attacker.global_position - global_position).normalized()
			# Transform world hit dir to local space
			var local_dir: Vector3 = global_transform.basis.inverse() * attacker_hit_dir
			# Punch camera away from hit
			_view_punch_pos = -local_dir * 0.15 * hit_intensity
			# Add some random rotational kick
			var rot_kick: float = 0.1 * hit_intensity
			_view_punch_rot = Vector3(
				randf_range(-rot_kick, rot_kick),
				randf_range(-rot_kick, rot_kick),
				randf_range(-rot_kick, rot_kick),
			)
	if health <= 0 and _phoenix_charges_left > 0:
		_phoenix_charges_left -= 1
		health = max(1, int(float(MAX_HEALTH + weapon.max_hp_bonus) * 0.35))
		velocity = Vector3.UP * 8.0
		_poison_damage_left = 0.0
		_poison_dps = 0.0
		_slow_timer = 0.0
		_slow_mult = 1.0
		_phoenix_fx.rpc(global_position)
		return
	if health > 0:
		_play_hurt_sound.rpc(global_position)
	else:
		_play_death_sound.rpc(global_position)
		var push: Vector3 = Vector3.UP
		var ctx_force: float = maxf(gib_force, 0.0)
		if hit_dir.length_squared() > 0.001:
			push = hit_dir.normalized()
			if push.y < 0.15:
				push.y = 0.15
		var killer := get_parent().get_node_or_null(str(from_id))
		if killer and killer is Node3D and hit_dir.length_squared() <= 0.001:
			push = (global_position - killer.global_position).normalized() + Vector3.UP * 0.6
			# Scale ragdoll impulse by the killer's knockback stat — HAYMAKER
			# launches the corpse across the map, default push just topples.
			var kb: float = Weapon.BASE_KNOCKBACK
			if killer.get("weapon") != null:
				kb = killer.weapon.knockback
			ctx_force = maxf(ctx_force, kb)
		var kb_scale_max := 8.0
		var upward_bias := 0.25
		var upward_scale := 0.12
		if blast_radius > 0.0:
			kb_scale_max = 4.0
			upward_bias = 0.16
			upward_scale = 0.06
		# Killing-blow damage scales the launch: a 1hp poison tick lands like a
		# nudge, a 50-damage shotgun blast hurls. 25 ≈ a "normal" rifle hit and
		# preserves the previous knockback feel for that case.
		var damage_factor: float = clampf(float(amount) / 25.0, 0.05, 2.5)
		var kb_scale := clampf((ctx_force if ctx_force > 0.0 else push.length()) / Weapon.BASE_KNOCKBACK, 1.0, kb_scale_max)
		kb_scale = clampf(kb_scale * damage_factor, 0.1, kb_scale_max)
		push = push.normalized() * kb_scale + Vector3.UP * (upward_bias + upward_scale * kb_scale)
		_ragdoll.rpc(push, force_origin, ctx_force, blast_radius, blast_severity, is_head)
		died.emit(from_id)
		_report_death.rpc_id(1, from_id)

@rpc("authority", "call_local", "reliable")
func _phoenix_fx(pos: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	_spawn_bullet_blast(pos + Vector3.UP * 0.8, 5.0, Color(1.0, 0.55, 0.15))

@rpc("any_peer", "call_local", "unreliable")
func _play_hurt_sound(pos: Vector3) -> void:
	# `is_self` = this peer owns the player who got hit. Their copy plays a
	# quieter 2D variant; everyone else hears the spatial 3D version.
	SFX.hurt(pos, is_multiplayer_authority() and not is_bot)

@rpc("any_peer", "call_local", "unreliable")
func _play_death_sound(pos: Vector3) -> void:
	SFX.death(pos, is_multiplayer_authority() and not is_bot)

@rpc("any_peer", "call_local", "reliable")
func apply_knockback(impulse: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	Violence.apply_knockback(self, impulse)

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
	# The RPC is invoked on the victim's Player node, so `player_id` IS the
	# victim. Using get_remote_sender_id() here misidentifies server-hosted
	# bot deaths as a self-kill by the host (sender=1 for server-to-self RPCs).
	if not multiplayer.is_server():
		return
	var game := get_tree().current_scene
	if game and game.has_method("report_kill"):
		game.report_kill(killer_id, player_id)

@rpc("any_peer", "call_local", "reliable")
func server_respawn(pos: Vector3, yaw: float = 0.0) -> void:
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0:
		return
	if not is_multiplayer_authority():
		return
	global_position = pos
	rotation.y = yaw
	velocity = Vector3.ZERO
	ghost_mode = false
	invisible_mode = false
	health = MAX_HEALTH + weapon.max_hp_bonus
	_phoenix_charges_left = weapon.phoenix_revives
	_poison_damage_left = 0.0
	_poison_dps = 0.0
	_poison_tick_accum = 0.0
	_slow_timer = 0.0
	_slow_mult = 1.0
	_next_shot_damage_mult = 1.0
	_next_shot_speed_mult = 1.0
	if _procedural_gun and _procedural_gun.has_method("reset_heat"):
		_procedural_gun.reset_heat()
	rifle_cooldown = 0.0
	grenade_cooldown = 0.0
	melee_cooldown = 0.0
	wall_jump_cooldown = 0.0
	mag = weapon.get_mag_size()
	reloading = false
	if _reload_tween and _reload_tween.is_valid():
		_reload_tween.kill()
	if _mag_reload_tween and _mag_reload_tween.is_valid():
		_mag_reload_tween.kill()
	reload_offset = Vector3.ZERO
	if muzzle:
		muzzle.rotation.x = 0.0
	_stop_reload_audio()
	dash_charges = MAX_DASH_CHARGES
	dash_timer = 0.0
	jumps_left = 2 + weapon.extra_jumps
	_hit_face_timer = 0.0
	_set_hit_face_state(false)

	_ragdoll_head = null
	camera.transform = Transform3D(Basis.IDENTITY, _camera_rest_pos)
	var scene := get_tree().current_scene
	if scene and scene.has_method("show_death_effect"):
		scene.show_death_effect(false)

	_end_shield()
	_apply_ghost_visuals()
	# Push the teleport to every peer immediately so they don't see us at the
	# old position for a frame while waiting for the next _physics_process.
	_broadcast_state.rpc(global_position, rotation.y)
	_last_sync_pos = global_position
	_last_sync_yaw = rotation.y

@rpc("any_peer", "call_local", "reliable")
func set_ghost_mode(enabled: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	ghost_mode = enabled
	if enabled:
		frozen = false
		invisible_mode = false
		health = 0
		# Detach the death-cam from the tumbling ragdoll head so the camera
		# snaps back to the body at the death position. Otherwise we'd watch
		# the corpse fly off into the void.
		_ragdoll_head = null
		if camera:
			camera.transform = Transform3D(Basis.IDENTITY, _camera_rest_pos)
		# Make the body itself solid + visible (was hidden + de-collided on death).
		if body_model:
			body_model.visible = true
		_set_dead_visuals(false)
		if is_multiplayer_authority():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		invisible_mode = false
		health = MAX_HEALTH + weapon.max_hp_bonus
		_phoenix_charges_left = weapon.phoenix_revives
	_apply_ghost_visuals()

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
	if not _remote_has_target or global_position.distance_to(pos) > REMOTE_SNAP_DISTANCE:
		global_position = pos
		rotation.y = yaw
		_visual_prev_pos = pos
	_remote_target_pos = pos
	_remote_target_yaw = yaw
	_remote_has_target = true

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
func set_launching(v: bool, downward_vel: float = 0.0) -> void:
	# Round-start rocket-spawn: when v=true, set constant downward velocity,
	# tilt camera down so the player sees the ground rushing up, and pump
	# shake_amt for a sustained "we're being rocketed" rumble. Server-only.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	launching = v
	if v and is_multiplayer_authority():
		velocity = Vector3(0.0, -downward_vel, 0.0)
		# Bots have a camera node but server doesn't drive its view — these
		# adjustments only matter for the local human controlling this body.
		if not is_bot:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			# ~25° down — enough to see where you're rocketing into without
			# losing the horizon.
			look_pitch = -0.44
			# Sustained rumble during the descent. The launching path skips
			# the normal shake-decay step, so this stays high until landing.
			shake_amt = 0.06
			SFX.rocket_descent()

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
		_phoenix_charges_left = max(_phoenix_charges_left, weapon.phoenix_revives)
	_update_gun_visuals()
	_update_body_scale()

@rpc("any_peer", "call_local", "reliable")
func reset_weapon() -> void:
	weapon.reset()
	mag = weapon.get_mag_size()
	reloading = false
	rifle_cooldown = 0.0
	_phoenix_charges_left = weapon.phoenix_revives
	_poison_damage_left = 0.0
	_poison_dps = 0.0
	_slow_timer = 0.0
	_slow_mult = 1.0
	_next_shot_damage_mult = 1.0
	_next_shot_speed_mult = 1.0
	if _procedural_gun and _procedural_gun.has_method("reset_heat"):
		_procedural_gun.reset_heat()
	_update_gun_visuals()
	_update_body_scale()

# -------------------- GUN VISUALS --------------------

func _setup_gun_visuals() -> void:
	# Hide the legacy GunMesh boxes — replaced by the procedural gun below.
	# (Leaving the nodes around so existing references like _apply_ghost_visuals
	# don't crash; they're just invisible.)
	if gun_body:
		gun_body.visible = false
	gun_barrel = MeshInstance3D.new()
	gun_barrel.visible = false
	muzzle.add_child(gun_barrel)
	gun_magazine = MeshInstance3D.new()
	gun_magazine.visible = false
	muzzle.add_child(gun_magazine)

	# Procedural gun — its parts react to weapon stats via apply_weapon_stats.
	_procedural_gun = preload("res://scripts/procedural_gun.gd").new()
	_procedural_gun.name = "ProceduralGun"
	muzzle.add_child(_procedural_gun)

	# Remember the blade's authored position so scaling it doesn't drift.
	if blade:
		_blade_rest_transform = blade.transform

func _update_gun_visuals() -> void:
	# Push the current weapon stats into the procedural gun. All
	# stat→geometry mapping lives in procedural_gun.gd.
	if _procedural_gun and _procedural_gun.has_method("apply_weapon_stats"):
		_procedural_gun.apply_weapon_stats(weapon)
		# Long barrels = pull the gun back against the shoulder (positive Z is
		# behind the camera). 0.5 m barrel = no offset; 1.4 m = 0.3 m back.
		var bl: float = float(_procedural_gun.get("barrel_length"))
		var pull: float = clampf((bl - 0.5) * 0.3, 0.0, 0.3)
		_gun_pull_back = Vector3(0.0, 0.0, pull)

	# Blade — under the gun, grows with melee damage × reach. BIG SWORD makes
	# it very obviously a sword; default melee keeps it a small knife.
	if blade:
		var melee_s: float = sqrt(maxf(0.01, weapon.melee_damage_mult * weapon.melee_scale))
		blade.scale = Vector3.ONE * melee_s
		# Anchor the heel of the blade at its rest spot so the tip extends
		# outward as it grows, rather than clipping into the gun body.
		var base_pos: Vector3 = _blade_rest_transform.origin
		var extra_reach: float = 0.25 * (melee_s - 1.0)    # push forward as blade grows (local +Z → forward-ish)
		blade.transform = Transform3D(_blade_rest_transform.basis,
			Vector3(base_pos.x, base_pos.y, base_pos.z - extra_reach))

func _update_body_scale() -> void:
	# BodyModel holds the visual mesh parts; hitboxes are siblings under the
	# Player root and must be kept in sync with the visual body size + height.
	if body_model == null:
		return
	var bs: float = maxf(0.1, weapon.body_scale)
	var hs: float = maxf(0.1, weapon.head_scale)
	# Per-axis warp lets cards like SLENDERMAN / FLATFISH stretch the body
	# without changing overall mass. Clamped so a 0 axis doesn't squash to nothing.
	var axes: Vector3 = Vector3(
		maxf(0.1, weapon.body_scale_axes.x),
		maxf(0.1, weapon.body_scale_axes.y),
		maxf(0.1, weapon.body_scale_axes.z),
	)
	body_model.scale = axes * bs
	# head_scale does not change the blob mesh itself; it only scales the head
	# hitbox below, so cards like BIG HEAD still change how easy the head is to hit.
	# Hitboxes are siblings under the Player root — shift their y so they sit
	# where the scaled visual parts actually are, and scale them to match.
	if head_hitbox:
		head_hitbox.position.y = _head_hitbox_rest_y * bs * axes.y
		head_hitbox.scale = axes * (bs * hs)
	if torso_hitbox:
		torso_hitbox.position.y = _torso_hitbox_rest_y * bs * axes.y
		torso_hitbox.scale = axes * bs
	if legs_hitbox:
		legs_hitbox.position.y = _legs_hitbox_rest_y * bs * axes.y
		legs_hitbox.scale = axes * bs
	# Camera sits at head height — scale the rest position so a CHONKY player
	# looks out from their actual (taller) head rather than mid-torso.
	if camera:
		camera.position = Vector3(
			_camera_rest_pos.x,
			_camera_rest_pos.y * bs * axes.y,
			_camera_rest_pos.z,
		)
	# Gun feels smaller in the hands of a bigger player (inverse sqrt scaling
	# keeps it gently smaller, not microscopic, as the body grows).
	if muzzle:
		muzzle.scale = Vector3.ONE * (1.0 / sqrt(bs))

# -------------------- BOT AI --------------------

func _bot_physics(delta: float) -> void:
	if launching:
		move_and_slide()
		if is_on_floor():
			launching = false
		return
	if frozen:
		velocity = Vector3.ZERO
		return

	# Passive AI mode: do absolutely nothing.
	var game_scene: Node = get_tree().current_scene
	if game_scene and game_scene.get("bots_hold_fire") == true:
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		else:
			velocity.y = 0.0
		velocity.x = move_toward(velocity.x, 0.0, BOT_MOVE_SPEED * 3.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, BOT_MOVE_SPEED * 3.0 * delta)
		move_and_slide()
		return

	_bot_shoot_cooldown = maxf(0.0, _bot_shoot_cooldown - delta)
	_bot_jump_cooldown = maxf(0.0, _bot_jump_cooldown - delta)
	_bot_dash_cooldown = maxf(0.0, _bot_dash_cooldown - delta)
	rifle_cooldown = maxf(0.0, rifle_cooldown - delta)

	if reloading and rifle_cooldown <= 0.0:
		mag = weapon.get_mag_size()
		reloading = false

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
	else:
		jumps_left = 2 + weapon.extra_jumps

	if _bot_target == null or not is_instance_valid(_bot_target) or _bot_target.get("ghost_mode") == true:
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

	var gap_jump_started := false
	if is_on_floor() and move_dir.length_squared() > 0.01 and not _bot_has_floor_ahead(move_dir, BOT_EDGE_PROBE_DIST):
		var landing_dist := _bot_gap_landing_distance(move_dir)
		if landing_dist > 0.0:
			velocity.y = JUMP_VELOCITY
			jumps_left = 1 + weapon.extra_jumps
			_bot_jump_cooldown = randf_range(0.8, 1.8)
			gap_jump_started = true
			if not ghost_mode:
				SFX.jump(global_position)
			if landing_dist > 7.0 and dash_timer <= 0.0 and dash_charges > 0 and _bot_dash_cooldown <= 0.0:
				dash_dir = move_dir.normalized()
				dash_timer = DASH_TIME
				dash_charges -= 1
				_bot_dash_cooldown = randf_range(2.0, 4.0)
				if not ghost_mode:
					SFX.dash(global_position)
		else:
			move_dir = Vector3.ZERO
			_bot_strafe_timer = 0.0
	elif not is_on_floor() and velocity.y < 1.0 and jumps_left > 0 and move_dir.length_squared() > 0.01:
		if not _bot_has_floor_ahead(move_dir, BOT_EDGE_PROBE_DIST) and _bot_gap_landing_distance(move_dir) > 0.0:
			velocity.y = DOUBLE_JUMP_VELOCITY
			jumps_left -= 1
			gap_jump_started = true
			if not ghost_mode:
				SFX.jump(global_position)

	# Occasional hop — keeps the bot moving vertically, harder to track.
	if not gap_jump_started and is_on_floor() and _bot_jump_cooldown <= 0.0 and randf() < BOT_JUMP_CHANCE:
		velocity.y = JUMP_VELOCITY
		_bot_jump_cooldown = randf_range(1.2, 3.0)
		if not ghost_mode: SFX.jump(global_position)

	# Occasional dash — usually in the current move direction, sometimes sideways.
	if dash_timer <= 0.0 and dash_charges > 0 and _bot_dash_cooldown <= 0.0 \
			and randf() < BOT_DASH_CHANCE:
		var wish: Vector3 = move_dir if move_dir.length_squared() > 0.01 else fwd_dir
		dash_dir = wish.normalized()
		dash_timer = DASH_TIME
		dash_charges -= 1
		_bot_dash_cooldown = randf_range(2.5, 5.5)
		if not ghost_mode: SFX.dash(global_position)

	# --- Movement ---
	var target_vel := move_dir * BOT_MOVE_SPEED * _slow_mult
	var accel := GROUND_ACCEL if is_on_floor() else AIR_ACCEL

	if dash_timer > 0.0:
		dash_timer -= delta
		velocity.y = max(velocity.y, 0.0)
		# Taper dash speed at the end.
		var dash_factor := clampf(dash_timer / (DASH_TIME * 0.5), 0.0, 1.0)
		target_vel = target_vel.lerp(dash_dir * DASH_SPEED, dash_factor)
		accel = 2000.0

	velocity.x = move_toward(velocity.x, target_vel.x, accel * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, accel * delta)

	move_and_slide()
	_maybe_broadcast_state()
	_tick_footsteps(delta)

	# Fell off map.
	_handle_fell_off_map()

	if not ghost_mode and _bot_shoot_cooldown <= 0.0 and not reloading and _bot_has_los(_bot_target):
		# Round must be live (no shooting at corpses during card pick / match
		# over), and the dev toggle in the F1 panel can hold fire entirely.
		var game_scene_shoot: Node = get_tree().current_scene
		var is_playing: bool = game_scene_shoot and int(game_scene_shoot.get("state")) == 1  # State.PLAYING == 1
		if is_playing:
			if _bot_shoot():
				# Bots auto-fire at the weapon's natural cadence, but now obey
				# the same magazine and reload gates as humans.
				_bot_shoot_cooldown = weapon.get_fire_interval()

func _bot_has_floor_ahead(move_dir: Vector3, distance: float) -> bool:
	if move_dir.length_squared() <= 0.001:
		return true
	var dir: Vector3 = move_dir.normalized()
	var origin: Vector3 = global_position + dir * distance + Vector3.UP * 0.8
	var target: Vector3 = origin + Vector3.DOWN * 3.0
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, target, 1)
	q.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()

func _bot_gap_landing_distance(move_dir: Vector3) -> float:
	if move_dir.length_squared() <= 0.001:
		return 0.0
	var dir: Vector3 = move_dir.normalized()
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var landing_probes: Array[float] = [BOT_GAP_JUMP_MIN_LANDING, 6.5, 8.5, 10.5, BOT_GAP_JUMP_MAX_LANDING]
	for distance: float in landing_probes:
		var origin: Vector3 = global_position + dir * distance + Vector3.UP * 3.0
		var target: Vector3 = origin + Vector3.DOWN * 9.0
		var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, target, 1)
		q.exclude = [get_rid()]
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			continue
		var landing_y := float((hit["position"] as Vector3).y)
		if landing_y >= global_position.y - 4.5 and landing_y <= global_position.y + 3.5:
			return float(distance)
	return 0.0

func _tick_footsteps(delta: float) -> void:
	if ghost_mode or not is_on_floor() or dash_timer > 0.0:
		_step_distance = 0.0
		return
	var moved: float = Vector2(velocity.x, velocity.z).length() * delta
	if moved < 0.01:
		_step_distance = 0.0
		return
	_step_distance += moved
	if _step_distance >= STEP_STRIDE:
		_step_distance = 0.0
		# Body-scale-driven footstep weight. Use the geometric mean of all
		# three axes so SLENDERMAN-style stretch (tall, narrow) reads close
		# to 1.0, while CHONKY (uniform 1.5×) clearly thumps deeper.
		var axes := weapon.body_scale_axes
		var ax: float = pow(maxf(0.05, axes.x * axes.y * axes.z), 1.0 / 3.0)
		var size: float = weapon.body_scale * ax
		SFX.footstep(global_position, size)

func _bot_find_target() -> Node3D:
	# Pick the nearest non-ghost player (bot or human) — bots fight everything.
	var best: Node3D = null
	var best_d: float = INF
	for p in get_parent().get_children():
		if p == self:
			continue
		if not p.is_in_group("players"):
			continue
		if p.get("ghost_mode") == true:
			continue
		var p3 := p as Node3D
		if p3 == null:
			continue
		var d: float = global_position.distance_squared_to(p3.global_position)
		if d < best_d:
			best_d = d
			best = p3
	return best

func _bot_has_los(target: Node3D) -> bool:
	var from := global_position + Vector3.UP * 0.7
	var to: Vector3 = target.global_position + Vector3.UP * 0.4
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1  # world only
	q.exclude = get_hitbox_rids()
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()

func _bot_shoot() -> bool:
	if _bot_target == null or not is_instance_valid(_bot_target):
		return false
	if reloading:
		return false
	if mag <= 0:
		_start_reload()
		return false
	mag -= 1
	var from := global_position + Vector3.UP * 0.7
	var to: Vector3 = _bot_target.global_position + Vector3.UP * 0.4
	var dist := from.distance_to(to)

	# --- Target Leading (Projectiles) ---
	# To be "realistic", the bot should try to lead the target based on its velocity.
	# We'll add some intentional error to this leading so it's not perfect.
	var target_vel := Vector3.ZERO
	if "velocity" in _bot_target:
		target_vel = _bot_target.velocity

	var bullet_speed := weapon.get_bullet_speed()
	var time_to_hit := dist / maxf(bullet_speed, 1.0)

	# Lead the target, but with sloppier "reaction lag" so prediction whiffs.
	var lead_multiplier := randf_range(0.55, 1.15)
	var predicted_pos := to + target_vel * time_to_hit * lead_multiplier

	var dir := (predicted_pos - from).normalized()

	# --- Refined Spread ---
	# Even at point-blank the bot has visible wobble; spread climbs sharply
	# with distance so long-range fights don't feel like a sniper duel.
	var base_spread := 0.04 # ~2.3 degrees
	var dist_factor := clampf(dist / 40.0, 0.0, 2.0)
	var spread := base_spread + (BOT_SPREAD * 0.7 * dist_factor)

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
	if mag <= 0:
		_start_reload()
	return true
