class_name Blast
extends RefCounted

const LOS_NONE := 0
const LOS_CENTER := 1
const LOS_TORSO := 2


static func apply(
	scene: Node,
	pos: Vector3,
	radius: float,
	damage: float,
	shooter_id: int,
	min_falloff: float = 0.2,
	self_damage_mult: float = 0.5,
	knockback: float = 9.0,
	upward_knockback: float = 1.6,
	los_mode: int = LOS_TORSO,
	sqrt_damage_falloff: bool = true,
	min_damage: int = 0,
	delay_speed: float = 0.0
) -> void:
	if scene == null or radius <= 0.0:
		return
	var tree := scene.get_tree()
	if tree == null:
		return
	var players_root: Node = scene.get_node_or_null("Players")
	var shooter_node: Node = players_root.get_node_or_null(str(shooter_id)) if players_root else null
	for p: Node3D in tree.get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		if p.get("ghost_mode") == true:
			continue
		var dist: float = pos.distance_to(p.global_position)
		if dist > radius:
			continue
		if not _has_line_of_sight(scene, pos, p, los_mode):
			continue

		var linear_falloff := clampf(1.0 - (dist / radius), 0.0, 1.0)
		var falloff := lerpf(min_falloff, 1.0, linear_falloff)
		var damage_falloff := falloff
		if sqrt_damage_falloff:
			damage_falloff = lerpf(min_falloff, 1.0, sqrt(linear_falloff))
		var dmg := int(damage * damage_falloff)
		if min_damage > 0:
			dmg = max(min_damage, dmg)
		if p.player_id == shooter_id:
			dmg = int(float(dmg) * self_damage_mult)

		var dir: Vector3 = p.global_position - pos
		if dir.length_squared() > 0.001:
			dir = dir.normalized()
		else:
			dir = Vector3.UP
		var impulse: Vector3 = (dir * knockback + Vector3.UP * upward_knockback) * falloff
		_apply_to_player(
			scene,
			p,
			shooter_node,
			pos,
			dir,
			impulse,
			dmg,
			radius,
			falloff,
			shooter_id,
			delay_speed
		)


static func _has_line_of_sight(scene: Node, pos: Vector3, target: Node3D, los_mode: int) -> bool:
	if los_mode == LOS_NONE:
		return true
	var source := pos
	var target_pos := target.global_position
	if los_mode == LOS_TORSO:
		source += Vector3.UP * 0.1
		target_pos += Vector3.UP
	var q := PhysicsRayQueryParameters3D.create(source, target_pos)
	q.collision_mask = 1
	return scene.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


static func _apply_to_player(
	scene: Node,
	target_player: Node3D,
	shooter_node: Node,
	pos: Vector3,
	dir: Vector3,
	impulse: Vector3,
	dmg: int,
	radius: float,
	falloff: float,
	shooter_id: int,
	delay_speed: float
) -> void:
	var target_authority: int = target_player.get_multiplayer_authority()
	var target_pos: Vector3 = target_player.global_position
	var delay := 0.0
	if delay_speed > 0.0:
		delay = pos.distance_to(target_pos) / delay_speed
	var apply_target := func() -> void:
		if not is_instance_valid(target_player):
			return
		if dmg > 0:
			target_player.take_damage.rpc_id(
				target_authority,
				dmg,
				shooter_id,
				pos,
				dir,
				impulse.length(),
				radius,
				falloff
			)
		target_player.apply_knockback.rpc_id(target_authority, impulse)
	if delay < 0.01:
		apply_target.call()
	else:
		scene.get_tree().create_timer(delay).timeout.connect(apply_target)

	if dmg <= 0 or target_player.player_id == shooter_id or shooter_node == null or not is_instance_valid(shooter_node):
		return
	var hit_pos := target_pos + Vector3.UP * 0.6
	var shooter_authority: int = shooter_node.get_multiplayer_authority()
	var hitmarker_delay := 0.0
	if delay_speed > 0.0 and shooter_node is Node3D:
		hitmarker_delay = pos.distance_to((shooter_node as Node3D).global_position) / delay_speed
	var fire_hitmarker := func() -> void:
		if not is_instance_valid(shooter_node):
			return
		shooter_node._hit_confirm.rpc_id(shooter_authority, false, dmg, hit_pos)
		if shooter_node.has_method("_on_dealt_damage"):
			shooter_node._on_dealt_damage.rpc_id(shooter_authority, dmg)
	if hitmarker_delay < 0.01:
		fire_hitmarker.call()
	else:
		scene.get_tree().create_timer(hitmarker_delay).timeout.connect(fire_hitmarker)
