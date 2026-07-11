class_name CardLibrary
extends RefCounted

# ROUNDS-style card pool. Each card is a dict:
#   id    : stable identifier (used by apply_card RPC)
#   name  : display name
#   desc  : one-line description
#   rarity: common | rare
#   tags  : optional; "firepower" marks cards that improve the gun itself
#           (damage, accuracy, ammo, handling, on-hit) — see the pity slot
#           in random_ids()
#   color : tint used in the menu + lerped into bullet_color when applicable
#   apply : Callable(Weapon) -> void. Mutates the weapon in place. Must be
#           deterministic (no randomness) so every peer arrives at the same
#           state when applied via RPC.

static func all() -> Array:
	return [
		{
			"id": "dmg_up",
			"tags": ["firepower"],
			"name": "DAMAGE",
			"desc": "",
			"color": Color(1.0, 0.25, 0.25),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 1.5,
		},
		{
			"id": "healthy",
			"name": "HEALTHY",
			"desc": "",
			"color": Color(0.45, 1.0, 0.55),
			"apply": func(w: Weapon) -> void:
				w.max_hp_bonus += 35,
		},
		{
			"id": "steady_hands",
			"tags": ["firepower"],
			"name": "STEADY HANDS",
			"desc": "Tighter spread",
			"color": Color(0.65, 0.9, 1.0),
			"apply": func(w: Weapon) -> void:
				w.spread *= 0.65,
		},
		{
			"id": "precision",
			"tags": ["firepower"],
			"name": "PRECISION",
			"desc": "Tighter spread and steadier aim",
			"color": Color(0.45, 0.95, 1.0),
			"apply": func(w: Weapon) -> void:
				w.spread *= 0.4
				w.recoil_per_shot *= 0.5,
		},
		{
			"id": "sneakers",
			"name": "SNEAKERS",
			"desc": "",
			"color": Color(0.65, 1.0, 0.85),
			"apply": func(w: Weapon) -> void:
				w.move_speed_mult *= 1.15,
		},
		{
			"id": "rapid_fire",
			"tags": ["firepower"],
			"name": "RAPID FIRE",
			"desc": "",
			"color": Color(1.0, 0.8, 0.2),
			"apply": func(w: Weapon) -> void:
				w.fire_rate_mult *= 1.6,
		},
		{
			"id": "bullet_speed",
			"tags": ["firepower"],
			"name": "FAST ROUNDS",
			"desc": "Bullets travel faster",
			"color": Color(0.72, 0.94, 1.0),
			"apply": func(w: Weapon) -> void:
				w.bullet_speed_mult *= 1.5
				w.bullet_color = w.bullet_color.lerp(Color(0.65, 0.92, 1.0), 0.3),
		},
		{
			"id": "big_mag",
			"tags": ["firepower"],
			"name": "BIG MAG",
			"desc": "",
			"color": Color(0.3, 0.8, 1.0),
			"apply": func(w: Weapon) -> void:
				w.mag_size_bonus += 20,
		},
		{
			"id": "quick_reload",
			"tags": ["firepower"],
			"name": "QUICK RELOAD",
			"desc": "",
			"color": Color(0.3, 1.0, 0.6),
			"apply": func(w: Weapon) -> void:
				w.reload_mult *= 2.0,
		},
		{
			"id": "ricochet",
			"tags": ["firepower"],
			"name": "RICOCHET",
			"desc": "Bullets bounce off walls",
			"color": Color(1.0, 0.65, 0.25),
			"apply": func(w: Weapon) -> void:
				w.ricochet_count += 2,
		},
		{
			"id": "last_bullet",
			"tags": ["firepower"],
			"name": "LAST BULLET",
			"desc": "Final round in mag deals 5× damage",
			"color": Color(1.0, 0.82, 0.25),
			"apply": func(w: Weapon) -> void:
				w.last_shot_damage_mult *= 5.0
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.75, 0.15), 0.4),
		},
		{
			"id": "silencer",
			"name": "SILENCER",
			"desc": "Hidden shots; faint tracer for you; −10% damage",
			"color": Color(0.55, 0.58, 0.62),
			"apply": func(w: Weapon) -> void:
				w.silencer_stacks += 1
				w.damage_mult *= 0.9
				w.bullet_color = w.bullet_color.lerp(Color(0.45, 0.48, 0.52), 0.55),
		},
		{
			"id": "shotgun",
			"tags": ["firepower"],
			"name": "SHOTGUN",
			"desc": "Multi-projectile burst",
			"color": Color(1.0, 0.5, 0.75),
			"apply": func(w: Weapon) -> void:
					w.extra_projectiles += 2
					w.reload_mult *= 1.5
					w.damage_mult *= 1.5
					w.fire_rate_mult *= 0.3
					w.bullet_speed_mult *= 0.75
					w.spread = max(w.spread, deg_to_rad(2.0)) + deg_to_rad(2.0),
		},
		{
			"id": "extra_barrel",
			"tags": ["firepower"],
			"name": "EXTRA BARREL",
			"desc": "Each shot fires an extra parallel bullet",
			"rarity": "rare",
			"color": Color(0.72, 0.74, 0.82),
			"apply": func(w: Weapon) -> void:
				w.extra_projectiles += 1,
		},
		{
			"id": "lifesteal",
			"name": "LIFESTEAL",
			"desc": "Damage enemies, gain some health",
			"color": Color(0.8, 0.2, 0.85),
			"apply": func(w: Weapon) -> void:
				w.lifesteal += 0.4
				w.bullet_color = w.bullet_color.lerp(Color(0.85, 0.15, 0.8), 0.4),
		},
		{
			"id": "explosive",
			"tags": ["firepower"],
			"name": "EXPLOSIVE ROUNDS",
			"desc": "Bullets explode on impact (stackable)",
			"color": Color(1.0, 0.4, 0.1),
			"apply": func(w: Weapon) -> void:
				# First stack establishes a sizable baseline; each extra one
				# grows the blast. Three stacks → ~9m one-shot zone.
				if w.explosive_radius <= 0.0:
					w.explosive_radius += 4.0
				else:
					w.explosive_radius += 2.5
				w.explosive_damage += 25.0
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.45, 0.08), 0.45),
		},
			{
				"id": "headhunter",
				"tags": ["firepower"],
				"name": "HEADHUNTER",
				"desc": "Deadly headshots",
				"color": Color(0.9, 0.9, 1.0),
				"apply": func(w: Weapon) -> void:
					w.headshot_mult *= 2.0,
			},
			{
				"id": "hitscan",
				"tags": ["firepower"],
				"name": "HITSCAN",
				"desc": "Extreme muzzle velocity and near-perfect accuracy",
				"rarity": "rare",
				"color": Color(0.7, 0.95, 1.0),
				"apply": func(w: Weapon) -> void:
					w.bullet_speed_mult *= 4.0
					w.spread *= 0.1
					w.bullet_color = w.bullet_color.lerp(Color(0.72, 0.96, 1.0), 0.55),
			},
			{
					"id": "heavy_rounds",
					"tags": ["firepower"],
					"name": "HEAVY ROUNDS",
					"desc": "Powerful but slow projectiles",
				"rarity": "rare",
				"color": Color(0.7, 0.4, 0.2),
				"apply": func(w: Weapon) -> void:
						w.damage_mult *= 2.5
						w.bullet_speed_mult *= 0.65
						w.fire_rate_mult *= 0.7
						w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.55, 0.2), 0.3),
		},
		{
				"id": "sniper",
				"tags": ["firepower"],
				"name": "SNIPER",
				"desc": "Railgun-like shots with RMB Zoom",
				"rarity": "rare",
				"color": Color(0.55, 0.85, 1.0),
				"apply": func(w: Weapon) -> void:
						w.damage_mult *= 3.0
						w.bullet_speed_mult *= 2.5
						w.fire_rate_mult *= 0.4
						w.spread *= 0.1
						w.headshot_mult *= 1.5
						w.special = Weapon.SPECIAL_ZOOM
						w.bullet_color = w.bullet_color.lerp(Color(0.55, 0.85, 1.0), 0.6),
		},		{
				"id": "uzi",
				"tags": ["firepower"],
				"name": "UZI",
				"desc": "High-volume automatic fire",
				"rarity": "rare",
				"color": Color(1.0, 0.65, 0.25),
				"apply": func(w: Weapon) -> void:
						w.fire_rate_mult *= 3.0
						w.mag_size_bonus += 20
						w.damage_mult *= 0.7
						w.spread *= 2
						w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.55, 0.15), 0.5),
		},
		{
				"id": "minigun",
				"tags": ["firepower"],
				"name": "MINIGUN",
				"desc": "Ten barrels, absurd fire rate, tiny bullet damage",
				"rarity": "rare",
				"color": Color(1.0, 0.78, 0.28),
				"apply": func(w: Weapon) -> void:
						w.fire_rate_mult *= 10.0
						w.mag_size_bonus += 95
						w.damage_mult *= 0.2
						w.spread = max(w.spread, deg_to_rad(1.2)) + deg_to_rad(1.2)
						w.recoil_per_shot *= 0.65
						w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.72, 0.12), 0.65),
		},		{
			"id": "ninja",
			"name": "NINJA",
			"desc": "Shift ends with a quick slash",
			"color": Color(0.35, 0.38, 0.48),
			"apply": func(w: Weapon) -> void:
				w.dash_end_melee = true
				w.bullet_color = w.bullet_color.lerp(Color(0.45, 0.48, 0.62), 0.25),
		},
		{
			"id": "homing",
			"tags": ["firepower"],
			"name": "HOMING",
			"desc": "Bullets lazily curve toward enemies",
			"rarity": "rare",
			"color": Color(0.7, 1.0, 0.55),
			"apply": func(w: Weapon) -> void:
				# Subtle steering — ~25°/s lets near-misses sometimes bend into
				# hits, but direct aim is still required. Slower projectiles
				# give defenders time to dodge the curve.
				w.homing += 25.0
				w.bullet_speed_mult *= 0.6
				w.bullet_color = w.bullet_color.lerp(Color(0.6, 1.0, 0.45), 0.35),
		},
		{
			"id": "haymaker",
			"tags": ["firepower"],
			"name": "HAYMAKER",
			"desc": "Enormous bullets with massive kick",
			"rarity": "rare",
			"color": Color(0.65, 0.85, 1.0),
			"apply": func(w: Weapon) -> void:
				w.knockback_mult *= 3.5
				w.damage_mult *= 1.5
				w.bullet_color = w.bullet_color.lerp(Color(0.6, 0.9, 1.0), 0.45),
		},
		{
			"id": "big_head",
			"tags": ["firepower"],
			"name": "BIG HEAD",
			"desc": "Easier to land headshots, but easier to be headshotted",
			"color": Color(0.95, 0.55, 0.9),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 1.8
				w.head_scale *= 1.8
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.5, 0.85), 0.3),
		},
		{
			"id": "chonky",
			"name": "CHONKY",
			"desc": "Higher durability, but a larger target",
			"color": Color(0.55, 0.9, 0.55),
			"apply": func(w: Weapon) -> void:
				w.max_hp_bonus += 75
				w.body_scale *= 1.5,
		},
		{
			"id": "slenderman",
			"name": "SLENDERMAN",
			"desc": "Tall and narrow — hard to hit body-on",
			"color": Color(0.35, 0.35, 0.45),
			"apply": func(w: Weapon) -> void:
				# Softer global stretch than the old 2.4x (which sheared the
				# animated rig); the lank comes from bone warps instead.
				w.body_scale_axes *= Vector3(0.72, 1.8, 0.72)
				w.bone_warps["Neck"] = w.bone_warps.get("Neck", Vector3.ONE) * Vector3(1.0, 1.5, 1.0)
				w.bone_warps["LeftArm"] = w.bone_warps.get("LeftArm", Vector3.ONE) * Vector3(0.85, 1.3, 0.85)
				w.bone_warps["RightArm"] = w.bone_warps.get("RightArm", Vector3.ONE) * Vector3(0.85, 1.3, 0.85),
		},
		{
			"id": "flatfish",
			"name": "FLATFISH",
			"desc": "Squished — small from the front, big from the sides",
			"color": Color(0.55, 0.85, 1.0),
			"apply": func(w: Weapon) -> void:
				# X (left-right) narrow, Y (height) unchanged, Z (front-back) deep.
				w.body_scale_axes *= Vector3(0.65, 1.0, 1.45),
		},
		{
			"id": "acrobat",
			"name": "ACROBAT",
			"desc": "Jump like a ninja",
			"color": Color(0.5, 0.9, 1.0),
			"apply": func(w: Weapon) -> void:
				w.extra_jumps += 2,
		},
		{
			"id": "glass_cannon",
			"tags": ["firepower"],
			"name": "GLASS CANNON",
			"desc": "Huge damage and speed, much lower health",
			"color": Color(1.0, 0.25, 0.45),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 2.2
				w.bullet_speed_mult *= 1.35
				w.max_hp_bonus -= 45
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.12, 0.32), 0.45),
		},
		{
			"id": "spray",
			"tags": ["firepower"],
			"name": "SPRAY",
			"desc": "Full-auto bullet hose — held fire sprays wild",
			"color": Color(1.0, 0.78, 0.18),
			"apply": func(w: Weapon) -> void:
				w.fire_rate_mult *= 2.2
				w.mag_size_bonus += 15
				w.damage_mult *= 0.65
				w.spread += deg_to_rad(1.0)
				# The real penalty: each held shot blooms hard, so sustained
				# fire walks wide and only tapping stays controllable.
				w.recoil_per_shot *= 3.0
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.72, 0.12), 0.4),
		},
		{
			"id": "careful_planning",
			"tags": ["firepower"],
			"name": "CAREFUL PLANNING",
			"desc": "Massive shots, slow fire and reload",
			"color": Color(0.95, 0.65, 0.35),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 2.5
				w.fire_rate_mult *= 0.45
				w.reload_mult *= 0.65
				w.recoil_per_shot *= 1.25,
		},
		{
			"id": "wind_up",
			"tags": ["firepower"],
			"name": "WIND UP",
			"desc": "Harder, faster bullets with slower cadence",
			"color": Color(0.45, 0.85, 1.0),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 1.7
				w.bullet_speed_mult *= 1.8
				w.fire_rate_mult *= 0.65
				w.bullet_color = w.bullet_color.lerp(Color(0.35, 0.8, 1.0), 0.4),
		},
		{
			"id": "grow",
			"tags": ["firepower"],
			"name": "GROW",
			"desc": "Bullets swell and gain damage the farther they fly",
			"color": Color(0.6, 1.0, 0.45),
			"apply": func(w: Weapon) -> void:
				w.grow_damage_per_meter += 0.015
				w.bullet_speed_mult *= 0.85
				w.bullet_color = w.bullet_color.lerp(Color(0.45, 1.0, 0.25), 0.4),
		},
		{
			"id": "poison",
			"tags": ["firepower"],
			"name": "POISON",
			"desc": "Hits deal more damage, spread over time",
			"color": Color(0.45, 1.0, 0.25),
			"apply": func(w: Weapon) -> void:
				w.damage_over_time += 0.7
				w.dot_duration = maxf(w.dot_duration, 3.5)
				w.bullet_color = w.bullet_color.lerp(Color(0.35, 1.0, 0.1), 0.45),
		},
		{
			"id": "chilling_rounds",
			"tags": ["firepower"],
			"name": "CHILLING ROUNDS",
			"desc": "Hits heavily slow enemy movement",
			"color": Color(0.55, 0.9, 1.0),
			"apply": func(w: Weapon) -> void:
				w.slow_on_hit = clampf(w.slow_on_hit * 0.48, 0.22, 1.0)
				w.slow_duration += 2.6
				w.bullet_speed_mult *= 0.9
				w.bullet_color = w.bullet_color.lerp(Color(0.45, 0.85, 1.0), 0.45),
		},
		{
			"id": "scavenger",
			"tags": ["firepower"],
			"name": "SCAVENGER",
			"desc": "Damaging enemies feeds ammo back into the mag",
			"color": Color(0.3, 1.0, 0.55),
			"apply": func(w: Weapon) -> void:
				w.reload_on_hit += 2,
		},
		{
			"id": "phoenix",
			"name": "PHOENIX",
			"desc": "Revive once per round at low health",
			"rarity": "rare",
			"color": Color(1.0, 0.45, 0.12),
			"apply": func(w: Weapon) -> void:
				w.phoenix_revives += 1
				w.max_hp_bonus -= 10
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.45, 0.08), 0.35),
		},
		{
			"id": "dodge",
			"name": "DODGE",
			"desc": "Shift grants brief invulnerability",
			"color": Color(0.72, 0.92, 1.0),
			"apply": func(w: Weapon) -> void:
				w.dash_iframes = true,
		},
		{
			"id": "drill_rounds",
			"tags": ["firepower"],
			"name": "DRILL ROUNDS",
			"desc": "Bullets bore through walls before stopping",
			"color": Color(0.75, 0.75, 0.82),
			"apply": func(w: Weapon) -> void:
				w.world_pierce_count += 2
				w.damage_mult *= 1.25
				w.bullet_speed_mult *= 0.8,
		},
		{
			"id": "landmine_rounds",
			"tags": ["firepower"],
			"name": "LANDMINE ROUNDS",
			"desc": "Bullet impacts plant proximity mines",
			"rarity": "rare",
			"color": Color(0.05, 0.9, 0.72),
			"apply": func(w: Weapon) -> void:
				w.impact_mines += 1
				w.fire_rate_mult *= 0.8
				w.bullet_speed_mult *= 0.85
				w.bullet_color = w.bullet_color.lerp(Color(0.0, 0.95, 0.75), 0.5),
		},
		{
			"id": "echo",
			"name": "ECHO",
			"desc": "RMB repeats a moment later, and recharges faster",
			"color": Color(0.8, 0.55, 1.0),
			"apply": func(w: Weapon) -> void:
				w.special_echo_count += 1
				w.special_cooldown_mult *= 0.85,
		},
		{
			"id": "tactical_reload",
			"tags": ["firepower"],
			"name": "TACTICAL RELOAD",
			"desc": "RMB also loads rounds into your mag",
			"color": Color(0.3, 1.0, 0.75),
			"apply": func(w: Weapon) -> void:
				w.special_reload_amount += 3,
		},
		{
			"id": "refreshed",
			"name": "REFRESHED",
			"desc": "Damaging enemies refunds RMB cooldown",
			"color": Color(0.65, 0.95, 1.0),
			"apply": func(w: Weapon) -> void:
				w.special_cooldown_refund_on_hit += 0.45,
		},
		{
			"id": "teleport",
			"name": "TELEPORT",
			"desc": "RMB: teleport where you aim",
			"color": Color(0.75, 0.35, 1.0),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_TELEPORT,
		},
		{
			"id": "sword",
			"name": "SWORD",
			"desc": "RMB: powerful melee slash",
			"color": Color(0.8, 0.8, 0.9),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_SWORD,
		},
		{
			"id": "air_strike",
			"name": "AIR STRIKE",
			"desc": "RMB: call a rocket on your crosshair",
			"rarity": "rare",
			"color": Color(1.0, 0.28, 0.12),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_AIR_STRIKE,
		},
		{
			"id": "ion_cannon",
			"name": "ION CANNON",
			"desc": "RMB: orbital beam on your crosshair",
			"rarity": "rare",
			"color": Color(0.35, 0.72, 1.0),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_ION_CANNON,
		},
		{
			"id": "cluster_grenade",
			"name": "CLUSTER",
			"desc": "RMB: grenade that splits into smaller blasts",
			"rarity": "rare",
			"color": Color(1.0, 0.52, 0.12),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_CLUSTER_GRENADE,
		},
		{
			"id": "backblast",
			"name": "BACKBLAST",
			"desc": "Shift leaves a bomb where you dashed from",
			"color": Color(1.0, 0.42, 0.12),
			"apply": func(w: Weapon) -> void:
				w.dash_spawn_bomb = true,
		},
		{
			"id": "bazooka",
			"tags": ["firepower"],
			"name": "BAZOOKA",
			"desc": "Slow rocket-like shots with a massive explosion",
			"rarity": "rare",
			"color": Color(1.0, 0.25, 0.0),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 4.0
				w.fire_rate_mult *= 0.12
				w.reload_mult *= 0.45
				w.bullet_speed_mult *= 0.12
				w.explosive_radius += 12.0
				w.explosive_damage += 180.0
				w.bullet_drop *= 0.1  # rocket thrust mostly cancels gravity
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.1, 0.0), 0.8),
		},
	]
static func by_id(id: String) -> Dictionary:
	for c in all():
		if c.id == id:
			return c
	return {}

# Pick `count` unique random card ids. If count > pool size, returns the full pool.
# score_factor: 1.0 is neutral. > 1.0 means higher chance of rare cards (for losers).
#
# Pity slot: an offer with zero gun-improving cards feels like a wasted round,
# so when a draw comes up dry one random slot is rerolled from the "firepower"
# pool (cards tagged as improving the gun itself — damage, accuracy, ammo,
# handling, on-hit effects).
static func random_ids(count: int, score_factor: float = 1.0) -> Array[String]:
	var out: Array[String] = []
	var pool: Array = all()
	while out.size() < count and not pool.is_empty():
		var idx := _weighted_pick(pool, score_factor)
		out.append(str(pool[idx].id))
		pool.remove_at(idx)
	if not out.is_empty() and not out.any(func(id: String) -> bool: return _is_firepower(by_id(id))):
		var fp_pool: Array = all().filter(func(c) -> bool:
			return _is_firepower(c) and not out.has(str(c.id)))
		if not fp_pool.is_empty():
			out[randi() % out.size()] = str(fp_pool[_weighted_pick(fp_pool, score_factor)].id)
	return out

static func _is_firepower(card: Dictionary) -> bool:
	return card.has("tags") and (card.tags as Array).has("firepower")

static func _weighted_pick(pool: Array, score_factor: float) -> int:
	var total := 0.0
	for card in pool:
		total += _card_weight(card, score_factor)
	var pick := randf() * total
	for i in pool.size():
		pick -= _card_weight(pool[i], score_factor)
		if pick <= 0.0:
			return i
	return pool.size() - 1

static func _card_weight(card: Dictionary, score_factor: float) -> float:
	var w := _rarity_weight(str(card.get("rarity", "common")))
	if str(card.get("rarity", "common")) == "rare":
		w *= score_factor
	return w

static func _rarity_weight(rarity: String) -> float:
	match rarity:
		"rare":
			return 0.15 # Baseline rare chance is even lower now (15%)
		_:
			return 1.0
