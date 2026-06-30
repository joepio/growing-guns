extends SceneTree

func _initialize() -> void:
	var knight := (load("res://assets/models/knight.fbx") as PackedScene).instantiate()
	var idle := (load("res://assets/animations/Idle.fbx") as PackedScene).instantiate()
	var k_sk: Skeleton3D = knight.find_child("Skeleton3D", true, false) as Skeleton3D
	var i_sk: Skeleton3D = idle.find_child("Skeleton3D", true, false) as Skeleton3D
	print("knight root: ", knight.get_path())
	print("idle root: ", idle.get_path())
	if k_sk and i_sk:
		print("bone count k/i: ", k_sk.get_bone_count(), " / ", i_sk.get_bone_count())
		for i in mini(k_sk.get_bone_count(), i_sk.get_bone_count()):
			var kn := k_sk.get_bone_name(i)
			var ib := i_sk.get_bone_name(i)
			if kn != ib:
				print("  bone mismatch ", i, ": ", kn, " vs ", ib)
	var i_ap: AnimationPlayer = idle.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if i_ap:
		for lib_name: String in i_ap.get_animation_library_list():
			var lib := i_ap.get_animation_library(lib_name)
			var anim := lib.get_animation(lib.get_animation_list()[0])
			print("first track path: ", anim.track_get_path(0))
	if k_sk:
		for i in k_sk.get_bone_count():
			print("bone ", i, ": ", k_sk.get_bone_name(i))
	knight.free()
	idle.free()
	quit(0)
