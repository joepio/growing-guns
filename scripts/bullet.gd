extends Node3D

var speed: float = 150.0
var direction: Vector3 = Vector3.FORWARD
var shooter_id: int = 0
var weapon_stats: Weapon = null
var max_range: float = 200.0
var distance_traveled: float = 0.0

var pierce_left: int = 0
var ricochet_left: int = 0
var excluded_rids: Array[RID] = []

func setup(origin: Vector3, dir: Vector3, shooter: int, w: Weapon) -> void:
	global_position = origin
	direction = dir.normalized()
	shooter_id = shooter
	weapon_stats = w
	add_to_group("projectiles")
	speed = w.get_bullet_speed()
	pierce_left = w.pierce_count
	ricochet_left = w.ricochet_count

	look_at(global_position + direction)

	var players_root: Node = get_tree().current_scene.get_node_or_null("Players")
	if players_root:
		var shooter_node: Node3D = players_root.get_node_or_null(str(shooter_id))
		if shooter_node and shooter_node.has_method("get_hitbox_rids"):
			excluded_rids = shooter_node.call("get_hitbox_rids")

	# Create visuals here to ensure weapon_stats is available.
	# Length stretches with bullet_speed_mult so fast rounds read as streaks
	# while sluggish ones stay chunky.
	var mesh_inst: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	var length_scale: float = clampf(weapon_stats.bullet_speed_mult, 0.5, 4.0)
	box.size = Vector3(
		0.06 * weapon_stats.bullet_scale,
		0.06 * weapon_stats.bullet_scale,
		0.6 * weapon_stats.bullet_scale * length_scale,
	)
	mesh_inst.mesh = box

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = weapon_stats.bullet_color
	mat.emission_enabled = true
	mat.emission = weapon_stats.bullet_color
	mat.emission_energy_multiplier = 4.0
	mesh_inst.material_override = mat

	add_child(mesh_inst)

func _physics_process(delta: float) -> void:
	if weapon_stats == null:
		return

	# Homing: steer toward the closest target in front of us, capped at
	# `weapon_stats.homing` degrees-per-second. Cheap — one pass over players
	# (≤ handful per match), dot-product cone filter, then a single slerp.
	if weapon_stats.homing > 0.0:
		var target: Node3D = _find_homing_target()
		if target:
			var to_t: Vector3 = (target.global_position - global_position).normalized()
			var cos_ang: float = clampf(direction.dot(to_t), -1.0, 1.0)
			var ang: float = acos(cos_ang)
			if ang > 0.0001:
				var max_turn: float = deg_to_rad(weapon_stats.homing) * delta
				var turn: float = minf(ang, max_turn)
				direction = direction.slerp(to_t, turn / ang).normalized()
				look_at(global_position + direction)

	var step: Vector3 = direction * speed * delta
	var step_len: float = step.length()

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(global_position, global_position + step)
	q.collision_mask = 1 | 2 | 4 # world + players + projectiles
	q.exclude = excluded_rids
	q.collide_with_areas = true

	var result: Dictionary = space.intersect_ray(q)
	if result.is_empty():
		global_position += step
		distance_traveled += step_len
	else:
		_handle_collision(result)

	if distance_traveled > max_range:
		queue_free()

func _handle_collision(result: Dictionary) -> void:
	var hit_pos: Vector3 = result.position
	var collider: Node = result.collider
	var normal: Vector3 = result.normal

	global_position = hit_pos

	var players_root: Node = get_tree().current_scene.get_node_or_null("Players")
	if not players_root:
		queue_free()
		return

	var shooter_node: Node3D = players_root.get_node_or_null(str(shooter_id))
	if not shooter_node:
		queue_free()
		return

	var dmg_ratio: float = clampf(weapon_stats.get_damage() / Weapon.BASE_DAMAGE, 0.5, 5.0)
	var hit_player: Node3D = shooter_node.call("_player_from_hit_collider", collider)

	if hit_player and hit_player.get("ghost_mode") == true:
		var ghosts_rids: Array = hit_player.call("get_hitbox_rids") if hit_player.has_method("get_hitbox_rids") else [hit_player.get_rid()]
		excluded_rids.append_array(ghosts_rids)
		return # Continue through ghosts

	# Visuals on all peers
	if hit_player:
		shooter_node.call("_spawn_blood", hit_pos, direction, dmg_ratio)
	else:
		shooter_node.call("_spawn_impact", hit_pos, weapon_stats.bullet_color, weapon_stats.bullet_scale, dmg_ratio)

	if weapon_stats.explosive_radius > 0.0:
		shooter_node.call("_spawn_bullet_blast", hit_pos, weapon_stats.explosive_radius, weapon_stats.bullet_color)

	# Server logic
	if multiplayer.is_server():
		if hit_player:
			var is_head: bool = shooter_node.call("_is_head_hit", collider)
			var dmg: int = int(weapon_stats.get_damage() * (weapon_stats.get_headshot_mult() if is_head else 1.0))
			var knock_dir: Vector3 = (direction + Vector3.UP * 0.18).normalized()
			var gib_force := weapon_stats.knockback if weapon_stats.knockback > 0.0 else weapon_stats.get_damage() * 0.08
			hit_player.take_damage.rpc_id(
				hit_player.get_multiplayer_authority(),
				dmg,
				shooter_id,
				hit_pos,
				knock_dir,
				gib_force,
				0.0,
				0.0,
				is_head
			)
			if weapon_stats.knockback > 0.0:
				hit_player.apply_knockback.rpc_id(hit_player.get_multiplayer_authority(), knock_dir * weapon_stats.knockback)

			# Send hit confirmation ONLY to the shooter's client
			if shooter_node:
				shooter_node._hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), is_head, dmg, hit_pos)

			if weapon_stats.lifesteal > 0.0:
				var heal_amt: int = int(float(dmg) * weapon_stats.lifesteal)
				if heal_amt > 0:
					shooter_node.heal.rpc_id(shooter_node.get_multiplayer_authority(), heal_amt)

		elif collider and collider.is_in_group("grenades") and collider.has_method("detonate"):
			collider.detonate()
			if shooter_node:
				shooter_node._hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), true, 0)

		if weapon_stats.explosive_radius > 0.0:
			# Nudge the splash origin off the impact surface so the LoS raycast
			# doesn't immediately self-intersect the wall we just hit.
			var splash_pos: Vector3 = hit_pos + normal * 0.1
			shooter_node.call("_apply_bullet_splash", splash_pos, weapon_stats.explosive_radius, weapon_stats.explosive_damage, shooter_id)

	# Pierce / Ricochet logic
	if hit_player and pierce_left > 0:
		pierce_left -= 1
		var hit_rids: Array = hit_player.call("get_hitbox_rids") if hit_player.has_method("get_hitbox_rids") else [hit_player.get_rid()]
		excluded_rids.append_array(hit_rids)
		# Continue travel after slight nudge
		global_position += direction * 0.05
		return

	if not hit_player and ricochet_left > 0:
		ricochet_left -= 1
		direction = direction.bounce(normal).normalized()
		look_at(global_position + direction)
		global_position += direction * 0.05
		return

	queue_free()

# Pick the valid enemy most "in front" of the bullet. Cone ≈ ±60° from the
# current flight direction; outside the cone the bullet holds straight.
# Returns the player whose direction has the highest dot with `direction`.
func _find_homing_target() -> Node3D:
	var players_root: Node = get_tree().current_scene.get_node_or_null("Players")
	if players_root == null:
		return null
	var best: Node3D = null
	var best_score: float = 0.82  # cos(~35°) — tight cone, only near-path enemies are tracked
	for p in players_root.get_children():
		if not (p is Node3D):
			continue
		if not p.is_in_group("players"):
			continue
		if int(p.get("player_id")) == shooter_id:
			continue
		if p.get("ghost_mode") == true:
			continue
		var hp = p.get("health")
		if hp != null and int(hp) <= 0:
			continue
		var to_p: Vector3 = p.global_position - global_position
		var dist_sq: float = to_p.length_squared()
		if dist_sq < 0.04:
			continue
		var to_n: Vector3 = to_p / sqrt(dist_sq)
		var score: float = direction.dot(to_n)
		if score > best_score:
			best_score = score
			best = p
	return best
