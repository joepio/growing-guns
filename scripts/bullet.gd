extends Node3D

const Violence = preload("res://scripts/violence.gd")
const DestructibleManager = preload("res://scripts/destructible_manager.gd")

var speed: float = 150.0
var direction: Vector3 = Vector3.FORWARD
# Actual flight vector — updated for gravity (bullet_drop) and homing; direction/
# speed are kept in sync each tick for code that still reads them directly.
var velocity: Vector3 = Vector3.ZERO
var shooter_id: int = 0
var weapon_stats: Weapon = null
var max_range: float = 200.0
var distance_traveled: float = 0.0

var ricochet_left: int = 0          # wall ricochets remaining (Ricochet card)
var world_pierce_left: int = 0      # surfaces the bullet can drill through (Drill card)
var ricochet_hits: int = 0          # how many times we've already bounced (damage scaling)
var body_ricochets_done: int = 0    # body bounces used this flight (Bouncy Castle card)
var last_in_mag: bool = false       # last round in mag — some cards key off this shot
var silenced: bool = false
var visible_to_shooter: bool = false  # silenced tracers: only the shooter may see them
# Colliders this bullet must not re-hit — shooter hitboxes, pierced chunk/body RIDs,
# ghosts passed through, etc. Grows over the projectile's lifetime.
var excluded_rids: Array[RID] = []

# Per-bullet ray query — allocated once in setup() and re-used every physics
# tick by mutating from/to. Avoids the per-tick PhysicsRayQueryParameters3D
# allocation that dominated bullet physics cost in the perf bench.
var _ray_query: PhysicsRayQueryParameters3D = null

# Bullet zip-by audio — triggers once when the bullet passes the closest
# point to the local camera (within ZIP_RADIUS_SQ).
const ZIP_RADIUS_SQ := 144.0  # 12 m — must match the gate in SFX.bullet_zip
var _zipped: bool = false
var _prev_listener_dist_sq: float = INF

# Visuals — head dot + a tracer trail that stretches as the bullet flies.
# Fast bullets cover more distance per frame, so the trail naturally reads
# as a long streak; slow bullets stay short and chunky.
var _trail_inst: MeshInstance3D = null
var _max_trail_length: float = 2.0
var _trail_thickness: float = 0.04

# Shared visual resources. Each bullet used to allocate two BoxMeshes and a
# StandardMaterial3D in setup() — at hundreds of bullets per mag-dump frame
# (minigun + uzi stacks) that alloc + GPU upload churn was a frame-time spike.
# A single unit cube (sized per-bullet via instance scale) and a small dedup
# cache of immutable tracer materials remove nearly all of it.
static var _bullet_box_mesh: BoxMesh = null
static var _tracer_mat_cache: Dictionary = {}

static func _get_bullet_box_mesh() -> BoxMesh:
	if _bullet_box_mesh == null:
		_bullet_box_mesh = BoxMesh.new()
		_bullet_box_mesh.size = Vector3.ONE
	return _bullet_box_mesh

# Tracer materials are never mutated after creation, so identical visuals can
# share one instance. Key on quantized colour/alpha/emission so a weapon's
# stream collapses to ~1-2 materials instead of one per bullet.
static func _get_tracer_material(color: Color, alpha: float, emission_energy: float, additive: bool) -> StandardMaterial3D:
	var key := "%d_%d_%d_%d_%d_%d" % [
		int(color.r * 64.0), int(color.g * 64.0), int(color.b * 64.0),
		int(alpha * 32.0), int(emission_energy * 8.0), 1 if additive else 0]
	var cached: StandardMaterial3D = _tracer_mat_cache.get(key)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if additive:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.no_depth_test = true
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = emission_energy
	_tracer_mat_cache[key] = mat
	return mat

const HITSCAN_THRESHOLD := 550.0  # m/s — faster than this, ray once in setup and despawn
const SILENCED_OWNER_TRACER_ALPHA := 0.12
const RAY_MASK_ALL := 1 | 2 | 4  # terrain + players + projectiles
const RAY_MASK_NO_TERRAIN := 2 | 4  # players + projectiles — terrain via analytical query

func setup(origin: Vector3, dir: Vector3, shooter: int, w: Weapon, p_last_in_mag: bool = false, p_visible_to_shooter: bool = false) -> void:
	global_position = origin
	direction = dir.normalized()
	shooter_id = shooter
	weapon_stats = w
	last_in_mag = p_last_in_mag
	silenced = w.silencer_stacks > 0
	visible_to_shooter = p_visible_to_shooter
	add_to_group("projectiles")
	speed = w.get_bullet_speed()
	velocity = direction * speed
	ricochet_left = w.ricochet_count
	world_pierce_left = w.world_pierce_count

	var shooter_node: Node3D = _shooter_node()
	if shooter_node and shooter_node.has_method("get_hitbox_rids"):
		excluded_rids = shooter_node.call("get_hitbox_rids")

	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collision_mask = RAY_MASK_ALL
	_ray_query.exclude = excluded_rids
	_ray_query.collide_with_areas = true

	# Hitscan optimization: very fast bullets don't need a multi-frame node 
	# lifecycle. We perform an immediate raycast and queue for deletion.
	if speed >= HITSCAN_THRESHOLD:
		call_deferred("_do_hitscan")
		return

	if silenced and not visible_to_shooter:
		return
	if BenchFlags.active and BenchFlags.no_bullet_visuals:
		return

	look_at(global_position + direction)

	var s: float = weapon_stats.get_bullet_scale_for_shot(last_in_mag)
	var tracer_color := weapon_stats.bullet_color.lerp(Color.WHITE, 0.18)
	var tracer_alpha := SILENCED_OWNER_TRACER_ALPHA if silenced else 1.0
	var emission_energy := clampf(1.6 * s, 1.2, 4.5) * (0.45 if silenced else 1.0)
	# Shared/cached material + one shared unit cube (sized via instance scale).
	var mat := _get_tracer_material(tracer_color, tracer_alpha, emission_energy, tracer_alpha < 1.0)
	var cube := _get_bullet_box_mesh()

	# Head — a small bright dot that always sits at the bullet's tip.
	var head_inst := MeshInstance3D.new()
	head_inst.mesh = cube
	head_inst.material_override = mat
	head_inst.scale = Vector3(0.08 * s, 0.08 * s, 0.14 * s)
	add_child(head_inst)

	# Trail — unit cube anchored so its FRONT face touches the head and extends
	# backwards along travel direction (+local Z, since look_at puts our forward
	# at -Z). x/y carry the bullet thickness; each physics tick sets z to match
	# how far we've come, capped to keep the streak from stretching across the map.
	_trail_thickness = 0.04 * s
	_trail_inst = MeshInstance3D.new()
	_trail_inst.mesh = cube
	_trail_inst.material_override = mat
	_trail_inst.scale = Vector3(_trail_thickness, _trail_thickness, 0.001)  # invisible until first tick
	add_child(_trail_inst)

	# Faster rounds get longer max streaks. SNIPER (×2.5) → ~8 m; HITSCAN
	# (×4) → ~12 m; BAZOOKA (×0.1) keeps a stubby tail.
	_max_trail_length = clampf(weapon_stats.bullet_speed_mult * 3.0 + 0.5, 0.5, 14.0)

func _physics_process(delta: float) -> void:
	if weapon_stats == null:
		return
	var _pt := Time.get_ticks_usec() if Trace.enabled else 0

	# Bullet drop — steady downward acceleration on the velocity vector.
	if weapon_stats.bullet_drop > 0.0:
		var drop: float = weapon_stats.bullet_drop
		var game := get_tree().current_scene
		if game and game.has_method("get_bullet_drop_mult"):
			drop *= game.get_bullet_drop_mult()
		velocity.y -= drop * delta

	# Homing: steer toward the closest target in front of us, capped at
	# `weapon_stats.homing` degrees-per-second. Cheap — one pass over players
	# (≤ handful per match), dot-product cone filter, then a single slerp.
	if weapon_stats.homing > 0.0:
		var target: Node3D = _find_homing_target()
		if target:
			var cur_speed: float = velocity.length()
			var dir_now: Vector3 = velocity.normalized() if cur_speed > 0.0001 else direction
			var to_t: Vector3 = (target.global_position - global_position).normalized()
			var cos_ang: float = clampf(dir_now.dot(to_t), -1.0, 1.0)
			var ang: float = acos(cos_ang)
			if ang > 0.0001:
				var max_turn: float = deg_to_rad(weapon_stats.homing) * delta
				var turn: float = minf(ang, max_turn)
				var new_dir: Vector3 = dir_now.slerp(to_t, turn / ang).normalized()
				velocity = new_dir * cur_speed

	# Sync direction/speed for downstream code, and aim the visual mesh.
	direction = velocity.normalized() if velocity.length_squared() > 0.0001 else direction
	speed = velocity.length()
	look_at(global_position + direction)

	var step: Vector3 = velocity * delta
	var step_len: float = step.length()

	# Mutate the cached query — only from/to change tick-to-tick. exclude is
	# kept in sync at setup + in the ghost-passthrough branch of _handle_collision.
	var result: Dictionary = _intersect_ray(global_position, global_position + step)
	if result.is_empty():
		global_position += step
		distance_traveled += step_len
	else:
		_handle_collision(result)

	if _trail_inst:
		var trail_len: float = clampf(distance_traveled, 0.001, _max_trail_length)
		_trail_inst.scale = Vector3(_trail_thickness, _trail_thickness, trail_len)
		# Front face of the unit-Z box sits at the bullet origin; centre is
		# half a length back along +Z (which is "behind" since forward is -Z).
		_trail_inst.position = Vector3(0.0, 0.0, trail_len * 0.5)

	_maybe_zip_by()

	if distance_traveled > max_range:
		queue_free()

	if Trace.enabled:
		Trace.prof("bullet", Time.get_ticks_usec() - _pt)

func _sync_ray_excludes(_from: Vector3, _to: Vector3) -> void:
	if _ray_query == null:
		return
	_ray_query.exclude = excluded_rids


# Physics ray for players / grenades, merged with one analytical destructible pass.
func _intersect_ray(from: Vector3, to: Vector3) -> Dictionary:
	if _ray_query == null:
		return {}
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return {}
	_ray_query.from = from
	_ray_query.to = to
	_ray_query.exclude = excluded_rids
	var _t0 := Time.get_ticks_usec() if Trace.enabled else 0
	var terrain_q: Dictionary = DestructibleManager.query_bullet_ray(from, to, excluded_rids)
	var destruct_hit: Dictionary = terrain_q.get("hit", {})
	var terrain_near: bool = bool(terrain_q.get("terrain_near", false))
	if Trace.enabled:
		Trace.prof("bullet_analytical", Time.get_ticks_usec() - _t0)
	_ray_query.collision_mask = RAY_MASK_NO_TERRAIN if terrain_near else RAY_MASK_ALL
	var _t1 := Time.get_ticks_usec() if Trace.enabled else 0
	var phys_hit: Dictionary = space.intersect_ray(_ray_query)
	if Trace.enabled:
		Trace.prof("bullet_phys_ray", Time.get_ticks_usec() - _t1)
	_ray_query.collision_mask = RAY_MASK_ALL
	if terrain_near and phys_hit.is_empty() and destruct_hit.is_empty():
		_ray_query.collision_mask = RAY_MASK_ALL
		var _t2 := Time.get_ticks_usec() if Trace.enabled else 0
		var fb: Dictionary = space.intersect_ray(_ray_query)
		if Trace.enabled:
			Trace.prof("bullet_phys_fallback", Time.get_ticks_usec() - _t2)
		_ray_query.collision_mask = RAY_MASK_ALL
		return fb
	if phys_hit.is_empty():
		return destruct_hit
	if destruct_hit.is_empty():
		return phys_hit
	var t_phys: float = from.distance_to(phys_hit.position)
	var t_dest: float = from.distance_to(destruct_hit.position)
	return destruct_hit if t_dest < t_phys else phys_hit

func _do_hitscan() -> void:
	if not is_inside_tree():
		return

	var start_pos := global_position
	
	var result: Dictionary = _intersect_ray(start_pos, start_pos + direction * max_range)
	
	var hit_pos: Vector3 = start_pos + direction * max_range
	if not result.is_empty():
		hit_pos = result.position
		# Update distance for correct damage falloff/growth in _handle_collision
		distance_traveled = start_pos.distance_to(hit_pos)
		_handle_collision(result)
	
	# Visual laser tracer
	var shooter_node: Node3D = _shooter_node()
	if (not silenced or visible_to_shooter) and shooter_node and shooter_node.has_method("_spawn_laser_tracer"):
		var tracer_alpha := SILENCED_OWNER_TRACER_ALPHA if silenced else 1.0
		shooter_node.call("_spawn_laser_tracer", start_pos, hit_pos, tracer_alpha)
	
	queue_free()

func _current_damage() -> float:
	var dmg := weapon_stats.get_damage_for_shot(last_in_mag)
	if weapon_stats.grow_damage_per_meter > 0.0:
		dmg *= 1.0 + distance_traveled * weapon_stats.grow_damage_per_meter
	if ricochet_hits > 0 and weapon_stats.ricochet_damage_mult > 1.0:
		dmg *= pow(weapon_stats.ricochet_damage_mult, float(ricochet_hits))
	return dmg

# Detect when the bullet passes its closest point to the local camera and
# play one zip sound. Predictive — extrapolates the bullet's straight-line
# trajectory so fast rounds (supersonic bullets traverse the 12 m bubble in
# under one physics tick) still trigger correctly. Fires once per bullet.
func _maybe_zip_by() -> void:
	if _zipped:
		return
	# Don't zip the shooter — they don't hear their own outgoing rounds.
	if shooter_id == multiplayer.get_unique_id():
		_zipped = true
		return
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var to_cam: Vector3 = cam.global_position - global_position
	var d_sq: float = to_cam.length_squared()
	var v_speed: float = velocity.length()
	if v_speed < 0.001:
		_prev_listener_dist_sq = d_sq
		return
	# Predict the closest-pass distance along the bullet's straight-line
	# trajectory. If the perpendicular distance is inside the bubble, the
	# bullet WILL pass within audible range — even if it does so between two
	# physics ticks (sniper rounds at 660 m/s move ~11 m per tick).
	var v_norm: Vector3 = velocity / v_speed
	var t_close: float = to_cam.dot(v_norm) / v_speed
	# Past the closest-pass and outside the audible bubble — the bullet
	# already missed and will only get further away. Latch _zipped so this
	# function early-exits for the rest of the bullet's lifetime instead of
	# recomputing the dot/length every tick.
	if t_close < 0.0 and d_sq > ZIP_RADIUS_SQ:
		_zipped = true
		return
	var closest_pos: Vector3 = global_position + velocity * maxf(t_close, 0.0)
	var closest_d_sq: float = cam.global_position.distance_squared_to(closest_pos)
	# Trigger if either:
	#   (a) we just passed the closest point this tick (slow bullets), OR
	#   (b) the predicted closest-pass falls inside the bubble AND we entered
	#       the bubble this tick (fast bullets — first-and-only chance).
	var passed: bool = d_sq < ZIP_RADIUS_SQ and d_sq > _prev_listener_dist_sq
	var entered_with_pending_pass: bool = (
		closest_d_sq < ZIP_RADIUS_SQ
		and _prev_listener_dist_sq > ZIP_RADIUS_SQ
		and d_sq < _prev_listener_dist_sq
	)
	if passed or entered_with_pending_pass:
		_zipped = true
		# Spatialise at the predicted closest-pass position so volume +
		# panning reflect the bullet's nearest point to the listener, not
		# whichever side of it we happen to sample on this tick.
		var fire_pos: Vector3 = closest_pos
		SFX.bullet_zip(speed, weapon_stats.get_bullet_scale_for_shot(last_in_mag), fire_pos)
		# Tell the server about the near miss so it can lift the music to
		# "high" — this fires from whichever peer the camera is local to.
		var scene := get_tree().current_scene
		if scene and scene.has_method("_on_player_near_miss"):
			if multiplayer.is_server():
				scene._on_player_near_miss()
			else:
				scene._on_player_near_miss.rpc_id(1)
	_prev_listener_dist_sq = d_sq

func _handle_collision(result: Dictionary) -> void:
	var hit_pos: Vector3 = result.position
	var collider: Node = result.collider
	var normal: Vector3 = result.normal

	global_position = hit_pos

	# Bench instrumentation. BenchFlags.active is false outside the bench so
	# these calls hit one static bool branch and short-circuit.
	BenchFlags.inc("collisions")
	if weapon_stats.explosive_radius > 0.0:
		BenchFlags.inc("explosions")
	var bench_skip_visuals: bool = BenchFlags.active and BenchFlags.no_explosion_visuals

	var shooter_node: Node3D = _shooter_node()
	if not shooter_node:
		queue_free()
		return

	var bullet_damage := _current_damage()
	var raw_dmg_ratio: float = bullet_damage / Weapon.BASE_DAMAGE
	var dmg_ratio: float = clampf(raw_dmg_ratio, 0.5, 5.0)
	var impact_dmg_ratio: float = clampf(raw_dmg_ratio, 0.2, 24.0)

	# Corpse hits run cosmetic-only on every peer (no networked health change).
	# The corpse accumulates damage and disintegrates at CORPSE_DISINTEGRATE_DMG.
	if collider and collider.is_in_group("corpses"):
		var corpse_dmg: float = bullet_damage
		Violence.hit_corpse(collider as RigidBody3D, hit_pos, direction, corpse_dmg)
		# Bullet stops on corpse — same as hitting a wall. Explosive rounds
		# still detonate below.
		if weapon_stats.explosive_radius > 0.0 and Violence.blast_vfx_will_spawn(hit_pos):
			shooter_node.call("_spawn_bullet_blast", hit_pos, weapon_stats.explosive_radius, weapon_stats.bullet_color, true)
			if multiplayer.is_server():
				var splash_pos: Vector3 = hit_pos + normal * 0.1
				shooter_node.call("_apply_bullet_splash", splash_pos, weapon_stats.explosive_radius, weapon_stats.explosive_damage, shooter_id)
		queue_free()
		return

	var hit_player: Node3D = shooter_node.call("_player_from_hit_collider", collider)

	if hit_player:
		var game := get_tree().current_scene
		if game and game.has_method("should_block_player_damage") \
				and game.should_block_player_damage(int(hit_player.get("player_id")), shooter_id):
			var ally_rids: Array = hit_player.call("get_hitbox_rids") if hit_player.has_method("get_hitbox_rids") else [hit_player.get_rid()]
			excluded_rids.append_array(ally_rids)
			if _ray_query:
				_sync_ray_excludes(_ray_query.from, _ray_query.to)
			return

	if hit_player and hit_player.get("ghost_mode") == true:
		var ghosts_rids: Array = hit_player.call("get_hitbox_rids") if hit_player.has_method("get_hitbox_rids") else [hit_player.get_rid()]
		excluded_rids.append_array(ghosts_rids)
		if _ray_query:
			_sync_ray_excludes(_ray_query.from, _ray_query.to)
		return # Continue through ghosts

	var body_ricochet_bounce := false
	if hit_player:
		var is_head: bool = bool(shooter_node.call("_is_head_hit", collider))
		if not is_head:
			var victim_weapon: Weapon = hit_player.get("weapon") as Weapon
			var body_bounces: int = victim_weapon.body_ricochet_count if victim_weapon else 0
			if body_bounces > body_ricochets_done:
				body_ricochet_bounce = true
				body_ricochets_done += 1

	# Visuals on all peers
	if hit_player:
		var is_head_hit: bool = bool(shooter_node.call("_is_head_hit", collider))
		var blood_ratio: float = dmg_ratio * (1.7 if is_head_hit else 1.0)
		shooter_node.call("_spawn_blood", hit_pos, direction, blood_ratio)
		hit_player.call(
			"_spawn_blood_wound",
			hit_pos,
			normal,
			direction,
			collider,
			clampf(blood_ratio * 0.75, 0.45, 1.2),
		)
		if is_head_hit:
			Violence.spawn_headshot_spray(get_tree().current_scene, hit_pos, direction, blood_ratio)
	else:
		if weapon_stats.explosive_radius <= 0.0:
			shooter_node.call("_spawn_impact", hit_pos, weapon_stats.bullet_color, weapon_stats.get_bullet_scale_for_shot(last_in_mag), impact_dmg_ratio, normal, weapon_stats.explosive_radius, collider)
			SFX.impact(hit_pos, dmg_ratio)
		DestructibleManager.carve_from_hit(
			hit_pos,
			impact_dmg_ratio,
			weapon_stats.explosive_radius,
			collider,
			normal,
			weapon_stats.explosive_damage,
		)

	if weapon_stats.explosive_radius > 0.0 and not bench_skip_visuals:
		if Violence.blast_vfx_will_spawn(hit_pos):
			shooter_node.call("_spawn_bullet_blast", hit_pos, weapon_stats.explosive_radius, weapon_stats.bullet_color, true)

	# Server logic
	if multiplayer.is_server():
		if hit_player:
			var is_head: bool = shooter_node.call("_is_head_hit", collider)
			var dmg: int = int(bullet_damage * (weapon_stats.get_headshot_mult() if is_head else 1.0))
			if not is_head:
				var game := get_tree().current_scene
				if game and game.has_method("get_body_damage_mult"):
					dmg = int(float(dmg) * game.get_body_damage_mult())
			var poison_total_damage := 0
			var direct_damage := dmg
			if weapon_stats.damage_over_time > 0.0:
				poison_total_damage = maxi(1, int(round(float(dmg) * (1.0 + weapon_stats.damage_over_time))))
				direct_damage = 0
			var knock_dir: Vector3 = (direction + Vector3.UP * 0.18).normalized()
			var knock_mag := weapon_stats.get_knockback_force(float(maxi(dmg, poison_total_damage)), false, is_head)
			var direct_blast_radius := weapon_stats.explosive_radius
			var direct_blast_severity := 1.0 if direct_blast_radius > 0.0 else 0.0
			if direct_damage > 0:
				hit_player.take_damage.rpc_id(
					hit_player.get_multiplayer_authority(),
					direct_damage,
					shooter_id,
					hit_pos,
					knock_dir,
					knock_mag,
					direct_blast_radius,
					direct_blast_severity,
					is_head
				)
			if knock_mag > 0.0:
				hit_player.apply_knockback.rpc_id(hit_player.get_multiplayer_authority(), knock_dir * knock_mag)

			# Send hit confirmation ONLY to the shooter's client
			if shooter_node:
				shooter_node._hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), is_head, maxi(dmg, poison_total_damage), hit_pos)

			if poison_total_damage > 0 and hit_player.has_method("apply_damage_over_time"):
				hit_player.apply_damage_over_time.rpc_id(
					hit_player.get_multiplayer_authority(),
					poison_total_damage,
					weapon_stats.dot_duration,
					shooter_id
				)
			if weapon_stats.slow_on_hit < 1.0 and weapon_stats.slow_duration > 0.0 and hit_player.has_method("apply_slow"):
				hit_player.apply_slow.rpc_id(
					hit_player.get_multiplayer_authority(),
					weapon_stats.slow_on_hit,
					weapon_stats.slow_duration
				)
			if shooter_node and shooter_node.has_method("_on_dealt_damage"):
				shooter_node._on_dealt_damage.rpc_id(shooter_node.get_multiplayer_authority(), maxi(direct_damage, poison_total_damage))

		elif collider and collider.is_in_group("grenades") and collider.has_method("detonate"):
			collider.detonate()
			if shooter_node:
				shooter_node._hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), true, 0)

		if weapon_stats.explosive_radius > 0.0:
			# Nudge the splash origin off the impact surface so the LoS raycast
			# doesn't immediately self-intersect the wall we just hit.
			var splash_pos: Vector3 = hit_pos + normal * 0.1
			shooter_node.call("_apply_bullet_splash", splash_pos, weapon_stats.explosive_radius, weapon_stats.explosive_damage, shooter_id)
		if not hit_player and weapon_stats.impact_mines > 0 and shooter_node and shooter_node.has_method("_spawn_impact_mine"):
			shooter_node.call("_spawn_impact_mine", hit_pos + normal * 0.14, shooter_id)

	# Drill logic happens before ricochet: the bullet continues through the
	# struck surface, excluding that collider RID so the next ray starts cleanly.
	if not hit_player and world_pierce_left > 0:
		world_pierce_left -= 1
		if result.has("rid"):
			excluded_rids.append(result.rid)
			if _ray_query:
				_sync_ray_excludes(_ray_query.from, _ray_query.to)
		global_position = hit_pos + direction * 0.12
		distance_traveled += 0.12
		return

	# Body ricochet (Bouncy Castle): damage lands, then the bullet reflects.
	if hit_player and body_ricochet_bounce:
		velocity = velocity.bounce(normal)
		direction = velocity.normalized() if velocity.length_squared() > 0.0001 else direction
		look_at(global_position + direction)
		global_position += direction * 0.05
		var victim_rids: Array = hit_player.call("get_hitbox_rids") if hit_player.has_method("get_hitbox_rids") else [hit_player.get_rid()]
		excluded_rids.append_array(victim_rids)
		if _ray_query:
			_sync_ray_excludes(_ray_query.from, _ray_query.to)
		return

	# Ricochet logic
	if not hit_player and ricochet_left > 0:
		ricochet_left -= 1
		ricochet_hits += 1
		# Bounce the full velocity so drop / homing keep working post-ricochet.
		# Reflecting only `direction` would be overwritten next tick when
		# direction is re-derived from velocity.
		velocity = velocity.bounce(normal)
		direction = velocity.normalized() if velocity.length_squared() > 0.0001 else direction
		look_at(global_position + direction)
		global_position += direction * 0.05
		return

	queue_free()

# Pick the valid enemy most "in front" of the bullet. Cone ≈ ±60° from the
# current flight direction; outside the cone the bullet holds straight.
# Returns the player whose direction has the highest dot with `direction`.
func _players_root() -> Node:
	return get_tree().current_scene.get_node_or_null("Players")

func _shooter_node() -> Node3D:
	var root := _players_root()
	return root.get_node_or_null(str(shooter_id)) as Node3D if root else null

func _find_homing_target() -> Node3D:
	var players_root: Node = _players_root()
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
		var game := get_tree().current_scene
		if game and game.has_method("should_block_player_damage") \
				and game.should_block_player_damage(int(p.get("player_id")), shooter_id):
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
