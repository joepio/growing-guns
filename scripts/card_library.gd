class_name CardLibrary
extends RefCounted

# ROUNDS-style card pool. Each card is a dict:
#   id    : stable identifier (used by apply_card RPC)
#   name  : display name
#   desc  : one-line description
#   rarity: common | rare
#   color : tint used in the menu + lerped into bullet_color when applicable
#   apply : Callable(Weapon) -> void. Mutates the weapon in place. Must be
#           deterministic (no randomness) so every peer arrives at the same
#           state when applied via RPC.

static func all() -> Array:
	return [
		{
			"id": "dmg_up",
			"name": "DAMAGE",
			"desc": "",
			"color": Color(1.0, 0.25, 0.25),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 1.5
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.2, 0.1), 0.35)
				w.bullet_scale *= 1.1,
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
			"name": "STEADY HANDS",
			"desc": "",
			"color": Color(0.65, 0.9, 1.0),
			"apply": func(w: Weapon) -> void:
				w.spread *= 0.65,
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
			"name": "RAPID FIRE",
			"desc": "",
			"color": Color(1.0, 0.8, 0.2),
			"apply": func(w: Weapon) -> void:
				w.fire_rate_mult *= 1.6,
		},
		{
			"id": "big_mag",
			"name": "BIG MAG",
			"desc": "",
			"color": Color(0.3, 0.8, 1.0),
			"apply": func(w: Weapon) -> void:
				w.mag_size_bonus += 20,
		},
		{
			"id": "quick_reload",
			"name": "QUICK RELOAD",
			"desc": "",
			"color": Color(0.3, 1.0, 0.6),
			"apply": func(w: Weapon) -> void:
				w.reload_mult *= 2.0,
		},
		{
			"id": "piercing",
			"name": "PIERCING",
			"desc": "Bullets pass through targets",
			"color": Color(0.5, 0.85, 1.0),
			"apply": func(w: Weapon) -> void:
				w.pierce_count += 1
				w.bullet_color = w.bullet_color.lerp(Color(0.4, 0.8, 1.0), 0.5),
		},
		{
			"id": "ricochet",
			"name": "RICOCHET",
			"desc": "Bullets bounce off walls",
			"color": Color(1.0, 0.65, 0.25),
			"apply": func(w: Weapon) -> void:
				w.ricochet_count += 2,
		},
		{
				"id": "shotgun",
				"name": "SHOTGUN",
				"desc": "Multi-projectile burst",
				"color": Color(1.0, 0.5, 0.75),
				"apply": func(w: Weapon) -> void:
						w.extra_projectiles += 2
						w.reload_mult *= 1.5
						w.bullet_speed_mult *= 0.75
						w.spread = max(w.spread, deg_to_rad(2.0)) + deg_to_rad(2.0),
		},		{
			"id": "lifesteal",
			"name": "LIFESTEAL",
			"desc": "",
			"color": Color(0.8, 0.2, 0.85),
			"apply": func(w: Weapon) -> void:
				w.lifesteal += 0.25
				w.bullet_color = w.bullet_color.lerp(Color(0.85, 0.15, 0.8), 0.4),
		},
		{
			"id": "explosive",
			"name": "EXPLOSIVE ROUNDS",
			"desc": "Bullets explode on impact",
			"rarity": "rare",
			"color": Color(1.0, 0.4, 0.1),
			"apply": func(w: Weapon) -> void:
				# First stack establishes a sizable baseline; each extra one
				# grows the blast. Three stacks → ~9m one-shot zone.
				if w.explosive_radius <= 0.0:
					w.explosive_radius = 4.0
				else:
					w.explosive_radius += 2.5
				w.explosive_damage += 35.0
				w.bullet_scale *= 1.35
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.45, 0.08), 0.45),
		},
			{
				"id": "headhunter",
				"name": "HEADHUNTER",
				"desc": "Deadly headshots",
				"color": Color(0.9, 0.9, 1.0),
				"apply": func(w: Weapon) -> void:
					w.headshot_mult *= 2.0,
			},
			{
				"id": "hitscan",
				"name": "HITSCAN",
				"desc": "Extreme muzzle velocity and near-perfect accuracy",
				"rarity": "rare",
				"color": Color(0.7, 0.95, 1.0),
				"apply": func(w: Weapon) -> void:
					w.bullet_speed_mult *= 4.0
					w.spread *= 0.1
					w.bullet_scale *= 0.9
					w.bullet_color = w.bullet_color.lerp(Color(0.72, 0.96, 1.0), 0.55),
			},
			{
					"id": "heavy_rounds",
					"name": "HEAVY ROUNDS",
					"desc": "Powerful but slow projectiles",
				"rarity": "rare",
				"color": Color(0.7, 0.4, 0.2),
				"apply": func(w: Weapon) -> void:
						w.damage_mult *= 2.0
						w.bullet_speed_mult *= 0.65
						w.fire_rate_mult *= 0.7
						w.bullet_scale *= 1.4
						w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.55, 0.2), 0.3),
		},
		{
				"id": "sniper",
				"name": "SNIPER",
				"desc": "Railgun-like shots with RMB Zoom",
				"rarity": "rare",
				"color": Color(0.55, 0.85, 1.0),
				"apply": func(w: Weapon) -> void:
						w.damage_mult *= 3.0
						w.bullet_speed_mult *= 2.5
						w.fire_rate_mult *= 0.4
						w.mag_size_bonus -= 7
						w.spread = 0.0
						w.headshot_mult *= 1.5
						w.bullet_scale *= 0.8
						w.special = Weapon.SPECIAL_ZOOM
						w.bullet_color = w.bullet_color.lerp(Color(0.55, 0.85, 1.0), 0.6),
		},		{
				"id": "uzi",
				"name": "UZI",
				"desc": "High-volume automatic fire",
				"rarity": "rare",
				"color": Color(1.0, 0.65, 0.25),
				"apply": func(w: Weapon) -> void:
						w.full_auto = true
						w.fire_rate_mult *= 3.0
						w.mag_size_bonus += 20
						w.spread += deg_to_rad(2.5)
						w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.55, 0.15), 0.5),
		},		{
			"id": "homing",
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
			"name": "HAYMAKER",
			"desc": "Enormous bullets with massive kick",
			"rarity": "rare",
			"color": Color(0.65, 0.85, 1.0),
			"apply": func(w: Weapon) -> void:
				w.knockback += 30.0
				w.bullet_scale *= 2
				w.damage_mult *= 1.5
				w.bullet_color = w.bullet_color.lerp(Color(0.6, 0.9, 1.0), 0.45),
		},
		{
			"id": "big_head",
			"name": "BIG HEAD",
			"desc": "Easier to land headshots, but easier to be headshotted",
			"color": Color(0.95, 0.55, 0.9),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 1.8
				w.head_scale *= 1.8
				w.bullet_scale *= 1.15
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
			"id": "acrobat",
			"name": "ACROBAT",
			"desc": "Jump like a ninja",
			"color": Color(0.5, 0.9, 1.0),
			"apply": func(w: Weapon) -> void:
				w.extra_jumps += 2,
		},
		{
			"id": "quick_recharge",
			"name": "QUICK RECHARGE",
			"desc": "",
			"color": Color(0.85, 0.55, 1.0),
			"apply": func(w: Weapon) -> void:
				w.special_cooldown_mult *= 0.85,
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
			"id": "shield",
			"name": "SHIELD",
			"desc": "RMB: 2s invulnerability bubble",
			"rarity": "rare",
			"color": Color(0.4, 0.8, 1.0),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_SHIELD,
		},
		{
			"id": "invisible",
			"name": "INVISIBLE",
			"desc": "RMB: vanish for 4 seconds",
			"rarity": "rare",
			"color": Color(0.55, 1.0, 0.9),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_INVISIBLE,
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
			"id": "cleaver",
			"name": "CLEAVER",
			"desc": "RMB: massive slash radius",
			"rarity": "rare",
			"color": Color(0.8, 0.4, 0.9),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_SWORD
				w.melee_damage_mult *= 3.0
				w.melee_scale *= 1.8,
		},
		{
			"id": "bazooka",
			"name": "BAZOOKA",
			"desc": "RMB: Single-shot massive explosion",
			"rarity": "rare",
			"color": Color(1.0, 0.25, 0.0),
			"apply": func(w: Weapon) -> void:
				w.damage_mult = 5.0
				w.mag_size_bonus = 1 - int(Weapon.BASE_MAG_SIZE) # Force to 1
				w.reload_mult = 0.3
				w.bullet_speed_mult = 0.1
				w.bullet_scale = 2.5
				w.explosive_radius = 16.0
				w.explosive_damage = 200.0
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
static func random_ids(count: int, score_factor: float = 1.0) -> Array[String]:
	var out: Array[String] = []
	var pool: Array = all()
	while out.size() < count and not pool.is_empty():
		var total_weight := 0.0
		for card in pool:
			var base_weight := _rarity_weight(str(card.get("rarity", "common")))
			if str(card.get("rarity", "common")) == "rare":
				base_weight *= score_factor
			total_weight += base_weight

		var pick := randf() * total_weight
		var chosen_index := 0
		for i in pool.size():
			var w := _rarity_weight(str(pool[i].get("rarity", "common")))
			if str(pool[i].get("rarity", "common")) == "rare":
				w *= score_factor
			pick -= w
			if pick <= 0.0:
				chosen_index = i
				break
		out.append(str(pool[chosen_index].id))
		pool.remove_at(chosen_index)
	return out

static func _rarity_weight(rarity: String) -> float:
	match rarity:
		"rare":
			return 0.15 # Baseline rare chance is even lower now (15%)
		_:
			return 1.0
