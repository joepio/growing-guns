class_name CharacterVisual
extends Node3D

const KNIGHT_SCENE := preload("res://assets/models/knight.fbx")

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

var enabled: bool = true
var ready_ok: bool = false

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
		var hips_idx := _skeleton.find_bone("Hips")
		if hips_idx >= 0:
			var local := _skeleton.get_bone_global_pose(hips_idx).origin
			return _skeleton.global_transform * local
	return global_position + Vector3(0.0, 1.0, 0.0)


func _build() -> void:
	_model = (KNIGHT_SCENE.instantiate() as Node3D)
	if _model == null:
		push_warning("CharacterVisual: failed to instance knight.fbx")
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
			loco_lib.add_animation(slot_name, anim)
			break
	inst.free()


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


func _attach_weapon_anchor() -> void:
	var attach := BoneAttachment3D.new()
	attach.name = "WeaponBoneAttachment"
	attach.bone_name = "RightHand"
	_skeleton.add_child(attach)
	_weapon_anchor = Node3D.new()
	_weapon_anchor.name = "WeaponAnchor"
	_weapon_anchor.position = Vector3(0.0, 0.0, 0.08)
	attach.add_child(_weapon_anchor)
