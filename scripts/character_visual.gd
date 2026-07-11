class_name CharacterVisual
extends Node3D

const KNIGHT_SCENE := preload("res://assets/models/knight.fbx")

# Character variants — Mixamo-rigged humanoids. Any FBX with a Mixamo
# skeleton drops in unmodified: bone lookups are prefix-tolerant (plain,
# mixamorig_*, mixamorig5_*, …) and animation clips are retargeted onto the
# actual rig at import time (_retarget_clip_to_skeleton). Ragdolls, gibs and
# wounds are generated from the skeleton, so variants inherit all of it.
const VARIANT_SCENES: Array[PackedScene] = [
	preload("res://assets/models/knight.fbx"),
	preload("res://assets/models/paladin.fbx"),
	preload("res://assets/models/ch10.fbx"),  # the classic shambling zombie
	# zombie.fbx (the hulking Avelange brute) is benched: its skeleton's rest
	# pose diverges from the knight-authored animation tracks, so the spine
	# bends ~90° when our clips play. Bringing it back needs real retargeting
	# (SkeletonProfile/BoneMap), not just track renaming.
]

const ANIM_FILES := {
	"pistol_idle": "res://assets/animations/Pistol Idle.fbx",
	"pistol_run": "res://assets/animations/Pistol Run.fbx",
	"pistol_jump": "res://assets/animations/Pistol Jump.fbx",
}

const ONE_SHOT_CLIPS: Array[String] = ["pistol_jump"]

# Mixamo knight rest pose faces +Z; rotate 180° so mesh forward matches Godot -Z.
const MODEL_ROTATION_DEGREES := Vector3(0.0, 180.0, 0.0)
# Capsule bottom is y=-0.9; idle toe bones sit near y=0 in model space.
# Third-person weapon mount — matches player.gd _setup_third_person_gun layering:
# WeaponAnchor (offset) → ThirdPersonGun (aim pitch) → gun (offset + barrel align).
const WEAPON_ROOT_ROTATION_DEGREES := Vector3(10.0, 0.0, 0.0)
const WEAPON_MOUNT_POSITION := Vector3(-0.0942, 0.2227, 0.0858)
const WEAPON_MOUNT_ROTATION_DEGREES := Vector3(89.46, -9.10, 0.00)
const FOOT_OFFSET_Y := -0.9

@export var foot_align_capsule: bool = true
# -1 = derive from the owning player's player_id, so every peer independently
# picks the same skin with zero netcode. Set explicitly in labs/tools.
@export var variant: int = -1

var enabled: bool = true
var ready_ok: bool = false

var _model_scene: PackedScene = KNIGHT_SCENE
var _pending_bone_warps: Dictionary = {}  # survives set_variant rebuilds
var _warped_bones: Array[int] = []
var _model: Node3D
var _skeleton: Skeleton3D
var _anim_player: AnimationPlayer
var _anim_tree: AnimationTree
var _weapon_anchor: Node3D
var _blob_rig: Node3D
var _loco_blend: float = 0.0
var _jump_active: bool = false


func _ready() -> void:
	if get_parent() != null:
		_blob_rig = get_parent().get_node_or_null("BlobRig") as Node3D
	if enabled:
		_build()


func is_active() -> bool:
	return ready_ok and enabled and visible


func get_weapon_anchor() -> Node3D:
	return _weapon_anchor if ready_ok else null


func mount_third_person_weapon(node: Node3D) -> Node3D:
	if _weapon_anchor == null:
		return null
	var root := Node3D.new()
	root.name = "ThirdPersonGun"
	root.rotation_degrees = WEAPON_ROOT_ROTATION_DEGREES
	_weapon_anchor.add_child(root)
	node.position = WEAPON_MOUNT_POSITION
	node.rotation_degrees = WEAPON_MOUNT_ROTATION_DEGREES
	root.add_child(node)
	return root


func apply_weapon_transform(weapon: Node3D, _mount_root: Node3D, pos: Vector3, rot_deg: Vector3) -> void:
	if weapon == null:
		return
	weapon.position = pos
	weapon.rotation_degrees = rot_deg


func set_blob_rig(blob: Node3D) -> void:
	_blob_rig = blob
	if ready_ok and _blob_rig:
		_blob_rig.visible = false


func update_locomotion(planar_speed: float, reference_speed: float) -> void:
	if not is_active() or _anim_tree == null:
		return
	var ref := maxf(0.1, reference_speed)
	var blend := clampf(planar_speed / ref, 0.0, 1.0)
	set_locomotion_blend(blend)


func set_locomotion_blend(blend: float) -> void:
	if not is_active() or _anim_tree == null:
		return
	_loco_blend = clampf(blend, 0.0, 1.0)
	if _jump_active:
		return
	use_locomotion_tree()
	_anim_tree.set("parameters/locomotion/blend_position", _loco_blend)


func play_jump() -> void:
	if not is_active() or _anim_player == null:
		return
	if not _anim_player.has_animation(&"loco/pistol_jump"):
		return
	_jump_active = true
	if _anim_tree:
		_anim_tree.active = false
	_anim_player.play(&"loco/pistol_jump")


func notify_landed() -> void:
	if _jump_active:
		_finish_jump()


func _finish_jump() -> void:
	_jump_active = false
	if _anim_tree == null:
		return
	use_locomotion_tree()
	_anim_tree.set("parameters/locomotion/blend_position", _loco_blend)


func use_locomotion_tree() -> void:
	if _anim_tree:
		_anim_tree.active = true


func get_clip_names() -> PackedStringArray:
	var out := PackedStringArray()
	if _anim_player == null:
		return out
	var lib: AnimationLibrary = _anim_player.get_animation_library("loco")
	if lib == null:
		return out
	for anim_name: String in lib.get_animation_list():
		out.append(anim_name)
	return out


func play_clip(clip_name: String) -> void:
	if not is_active() or _anim_player == null:
		return
	if _anim_tree:
		_anim_tree.active = false
	_jump_active = clip_name == "pistol_jump"
	var path := "loco/%s" % clip_name
	if _anim_player.has_animation(path):
		_anim_player.play(path)


func import_animation_clip(slot_name: String, path: String) -> bool:
	if not ready_ok or _anim_player == null:
		return false
	var lib: AnimationLibrary = _anim_player.get_animation_library("loco")
	if lib == null:
		return false
	if lib.has_animation(slot_name):
		return true
	_import_anim_clip(lib, slot_name, path)
	return lib.has_animation(slot_name)


func scan_animation_dir(dir_path: String = "res://assets/animations/") -> PackedStringArray:
	var added := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return added
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".fbx"):
			var slot := file_name.get_basename()
			slot = slot.to_lower().replace(" ", "_")
			var full := dir_path.path_join(file_name)
			if import_animation_clip(slot, full):
				added.append(slot)
		file_name = dir.get_next()
	dir.list_dir_end()
	return added


func collect_meshes(out: Array[MeshInstance3D]) -> void:
	if _model == null:
		return
	Violence.collect_meshes(_model, out)


func get_camera_pivot() -> Vector3:
	if _skeleton != null:
		var hips_idx := find_bone_any(_skeleton, "Hips")
		if hips_idx >= 0:
			var local := _skeleton.get_bone_global_pose(hips_idx).origin
			return _skeleton.global_transform * local
	return global_position + Vector3(0.0, 1.0, 0.0)


# Case-exact bone lookup first, then tolerate Mixamo namespace prefixes
# ("mixamorig:Hips" imports as "mixamorig_Hips", numbered rigs as
# "mixamorig5_Hips"). Suffix match is safe: "_Spine" never matches "Spine1".
static func find_bone_any(skel: Skeleton3D, plain: String) -> int:
	var idx := skel.find_bone(plain)
	if idx >= 0:
		return idx
	var suffix := "_" + plain
	for i in skel.get_bone_count():
		if skel.get_bone_name(i).ends_with(suffix):
			return i
	return -1


func get_model_scene() -> PackedScene:
	return _model_scene


# Swap to a different roster model at runtime (co-op enemy skins). Returns
# true when the model actually changed — the caller must re-mount the
# third-person weapon, since the hand anchor died with the old skeleton.
func set_variant(v: int) -> bool:
	v = posmod(v, VARIANT_SCENES.size())
	if ready_ok and v == variant:
		return false
	variant = v
	_teardown()
	if enabled:
		_build()
	return true


# Per-bone visual scales by plain Mixamo bone name ("Head" -> Vector3(1.8,
# 1.8, 1.8)) — how cards warp PARTS of the body instead of shearing the whole
# model. Bone pose scale persists because our clips carry no scale tracks
# (position + rotation only); if future animations animate scale, this needs
# to move into a SkeletonModifier3D. Scale inherits down the bone chain, so
# counter-scale children explicitly in the map if that's unwanted. Kept and
# re-applied across variant swaps; ragdoll clones copy the pose, so a BIG
# HEAD corpse keeps its big head.
func apply_bone_warps(by_plain_name: Dictionary) -> void:
	_pending_bone_warps = by_plain_name
	_apply_pending_bone_warps()


func _apply_pending_bone_warps() -> void:
	if _skeleton == null:
		return
	# Reset bones warped by a previous map that the new one no longer touches
	# (round reset clears cards; DICE can reroll body stats).
	for idx in _warped_bones:
		_skeleton.set_bone_pose_scale(idx, Vector3.ONE)
	_warped_bones.clear()
	for plain in _pending_bone_warps:
		var idx := find_bone_any(_skeleton, str(plain))
		if idx >= 0:
			_skeleton.set_bone_pose_scale(idx, _pending_bone_warps[plain])
			_warped_bones.append(idx)


func _teardown() -> void:
	ready_ok = false
	_jump_active = false
	if _anim_tree:
		_anim_tree.queue_free()
		_anim_tree = null
	if _anim_player:
		_anim_player.queue_free()
		_anim_player = null
	if _model:
		_model.queue_free()
		_model = null
	_skeleton = null
	_weapon_anchor = null


func _derive_variant() -> int:
	# Walk up to the owning Player for its player_id — same id on every peer,
	# so everyone renders the same skin. Bots have consecutive ids and cycle
	# through the roster.
	var n: Node = get_parent()
	while n != null:
		var pid: Variant = n.get("player_id")
		if typeof(pid) == TYPE_INT:
			return posmod(int(pid), VARIANT_SCENES.size())
		n = n.get_parent()
	return randi() % VARIANT_SCENES.size()


func _build() -> void:
	if variant < 0:
		variant = _derive_variant()
	_model_scene = VARIANT_SCENES[variant % VARIANT_SCENES.size()]
	_model = (_model_scene.instantiate() as Node3D)
	if _model == null:
		push_warning("CharacterVisual: failed to instance character variant %d" % variant)
		return
	_model.name = "KnightModel"
	add_child(_model)
	_model.rotation_degrees = MODEL_ROTATION_DEGREES
	position.y = FOOT_OFFSET_Y if foot_align_capsule else 0.0

	_skeleton = _model.find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton == null:
		push_warning("CharacterVisual: knight has no Skeleton3D")
		_model.queue_free()
		_model = null
		return

	# Pre-bake this rig's gib variants off-thread so the first disintegration
	# doesn't Voronoi a many-thousand-tri skinned mesh synchronously mid-death.
	# All knights share the FBX's mesh resources, so this warms once per process.
	Violence.gib_warm_tree(_model, Violence.KNIGHT_GIB_CHUNK_COUNT)

	_anim_player = AnimationPlayer.new()
	_anim_player.name = "AnimationPlayer"
	add_child(_anim_player)
	_anim_player.root_node = _anim_player.get_path_to(_model)
	_anim_player.animation_finished.connect(_on_animation_finished)

	var loco_lib := AnimationLibrary.new()
	_anim_player.add_animation_library("loco", loco_lib)
	for slot_name: String in ANIM_FILES:
		_import_anim_clip(loco_lib, slot_name, ANIM_FILES[slot_name])

	if not _has_locomotion_clips(loco_lib):
		push_warning("CharacterVisual: missing locomotion clips (need pistol_idle + pistol_run)")
		_model.queue_free()
		_model = null
		return

	_setup_anim_tree()
	_attach_weapon_anchor()
	_warped_bones.clear()  # fresh skeleton — no stale indices
	_apply_pending_bone_warps()

	ready_ok = true
	if _blob_rig:
		_blob_rig.visible = false
	_anim_tree.set("parameters/locomotion/blend_position", 0.0)


func _import_anim_clip(loco_lib: AnimationLibrary, slot_name: String, path: String) -> void:
	if not ResourceLoader.exists(path):
		push_warning("CharacterVisual: missing animation %s" % path)
		return
	var inst: Node = (load(path) as PackedScene).instantiate()
	var src_ap: AnimationPlayer = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if src_ap == null:
		inst.free()
		return
	for lib_name: String in src_ap.get_animation_library_list():
		var lib: AnimationLibrary = src_ap.get_animation_library(lib_name)
		for anim_name: String in lib.get_animation_list():
			var anim: Animation = lib.get_animation(anim_name).duplicate()
			anim.loop_mode = (
				Animation.LOOP_NONE if slot_name in ONE_SHOT_CLIPS else Animation.LOOP_LINEAR
			)
			_retarget_clip_to_skeleton(anim)
			loco_lib.add_animation(slot_name, anim)
			break
	inst.free()


# Anim FBXs address bones as "Armature/Skeleton3D:PlainName" (the knight's
# layout). Other rigs park the skeleton elsewhere and prefix bone names, so
# rewrite every track to THIS model's skeleton path + actual bone names.
# Tracks whose bone doesn't exist on this rig (e.g. the knight's extra
# "root" bone) are dropped.
func _retarget_clip_to_skeleton(anim: Animation) -> void:
	if _model == null or _skeleton == null:
		return
	var skel_path := str(_model.get_path_to(_skeleton))
	for t in range(anim.get_track_count() - 1, -1, -1):
		var p := str(anim.track_get_path(t))
		var colon := p.find(":")
		if colon < 0:
			continue
		var bone := p.substr(colon + 1)
		var idx := find_bone_any(_skeleton, bone)
		if idx < 0:
			anim.remove_track(t)
			continue
		var want := skel_path + ":" + _skeleton.get_bone_name(idx)
		if p != want:
			anim.track_set_path(t, NodePath(want))


func _setup_anim_tree() -> void:
	_anim_tree = AnimationTree.new()
	_anim_tree.name = "AnimationTree"
	add_child(_anim_tree)
	_anim_tree.anim_player = _anim_player.get_path()

	var tree := AnimationNodeBlendTree.new()
	_anim_tree.tree_root = tree

	var idle_node := AnimationNodeAnimation.new()
	idle_node.animation = _loco_idle_clip()
	var run_node := AnimationNodeAnimation.new()
	run_node.animation = _loco_run_clip()

	var space := AnimationNodeBlendSpace1D.new()
	space.add_blend_point(idle_node, 0.0)
	space.add_blend_point(run_node, 1.0)
	space.min_space = 0.0
	space.max_space = 1.0
	space.sync = true

	tree.add_node("locomotion", space)
	tree.connect_node(&"output", 0, &"locomotion")

	_anim_tree.active = true


func _has_locomotion_clips(loco_lib: AnimationLibrary) -> bool:
	var has_idle := loco_lib.has_animation("pistol_idle") or loco_lib.has_animation("idle")
	var has_run := loco_lib.has_animation("pistol_run") or loco_lib.has_animation("run")
	return has_idle and has_run


func _loco_idle_clip() -> StringName:
	if _anim_player.has_animation(&"loco/pistol_idle"):
		return &"loco/pistol_idle"
	return &"loco/idle"


func _loco_run_clip() -> StringName:
	if _anim_player.has_animation(&"loco/pistol_run"):
		return &"loco/pistol_run"
	return &"loco/run"


func _on_animation_finished(anim_name: StringName) -> void:
	if not _jump_active:
		return
	if String(anim_name).ends_with("pistol_jump"):
		_finish_jump()


# The weapon mount constants were hand-tuned against the KNIGHT's RightHand
# bone axes. Raw Mixamo rigs orient the hand bone differently, which left
# rifles floating upside down beside the palm — so the anchor sits inside a
# corrective frame that maps this rig's hand rest basis onto the knight's.
static var _ref_hand_rest: Basis
static var _ref_hand_rest_ok := false

static func _knight_hand_rest() -> Basis:
	if not _ref_hand_rest_ok:
		_ref_hand_rest = Basis.IDENTITY
		var inst := KNIGHT_SCENE.instantiate()
		var skel := inst.find_child("Skeleton3D", true, false) as Skeleton3D
		if skel:
			var idx := find_bone_any(skel, "RightHand")
			if idx >= 0:
				_ref_hand_rest = skel.get_bone_global_rest(idx).basis.orthonormalized()
		inst.free()
		_ref_hand_rest_ok = true
	return _ref_hand_rest


func _attach_weapon_anchor() -> void:
	var attach := BoneAttachment3D.new()
	attach.name = "WeaponBoneAttachment"
	var hand_idx := find_bone_any(_skeleton, "RightHand")
	attach.bone_name = _skeleton.get_bone_name(hand_idx) if hand_idx >= 0 else "RightHand"
	_skeleton.add_child(attach)
	var frame := Node3D.new()
	frame.name = "HandFrame"
	if hand_idx >= 0:
		var own: Basis = _skeleton.get_bone_global_rest(hand_idx).basis.orthonormalized()
		frame.basis = own.inverse() * _knight_hand_rest()
	attach.add_child(frame)
	_weapon_anchor = Node3D.new()
	_weapon_anchor.name = "WeaponAnchor"
	_weapon_anchor.position = Vector3(0.0, 0.0, 0.08)
	frame.add_child(_weapon_anchor)
