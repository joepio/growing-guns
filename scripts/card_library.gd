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
			"desc": "+50% damage",
			"color": Color(1.0, 0.25, 0.25),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 1.5
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.2, 0.1), 0.35)
				w.bullet_scale *= 1.1,
		},
		{
			"id": "healthy",
			"name": "HEALTHY",
			"desc": "+35 max HP",
			"color": Color(0.45, 1.0, 0.55),
			"apply": func(w: Weapon) -> void:
				w.max_hp_bonus += 35,
		},
		{
			"id": "steady_hands",
			"name": "STEADY HANDS",
			"desc": "+35% accuracy",
			"color": Color(0.65, 0.9, 1.0),
			"apply": func(w: Weapon) -> void:
				w.spread *= 0.65,
		},
		{
			"id": "sneakers",
			"name": "SNEAKERS",
			"desc": "+15% movement speed",
			"color": Color(0.65, 1.0, 0.85),
			"apply": func(w: Weapon) -> void:
				w.move_speed_mult *= 1.15,
		},
		{
			"id": "rapid_fire",
			"name": "RAPID FIRE",
			"desc": "+60% fire rate",
			"color": Color(1.0, 0.8, 0.2),
			"apply": func(w: Weapon) -> void:
				w.fire_rate_mult *= 1.6,
		},
		{
			"id": "big_mag",
			"name": "BIG MAG",
			"desc": "+20 ammo",
			"color": Color(0.3, 0.8, 1.0),
			"apply": func(w: Weapon) -> void:
				w.mag_size_bonus += 20,
		},
		{
			"id": "quick_reload",
			"name": "QUICK RELOAD",
			"desc": "2× reload speed",
			"color": Color(0.3, 1.0, 0.6),
			"apply": func(w: Weapon) -> void:
				w.reload_mult *= 2.0,
		},
		{
			"id": "piercing",
			"name": "PIERCING",
			"desc": "Bullets pierce +1 target",
			"color": Color(0.5, 0.85, 1.0),
			"apply": func(w: Weapon) -> void:
				w.pierce_count += 1
				w.bullet_color = w.bullet_color.lerp(Color(0.4, 0.8, 1.0), 0.5),
		},
		{
			"id": "ricochet",
			"name": "RICOCHET",
			"desc": "Bullets bounce +2 times",
			"color": Color(1.0, 0.65, 0.25),
			"apply": func(w: Weapon) -> void:
				w.ricochet_count += 2,
		},
		{
			"id": "shotgun",
			"name": "SHOTGUN",
			"desc": "+2 extra projectiles, adds spread",
			"color": Color(1.0, 0.5, 0.75),
			"apply": func(w: Weapon) -> void:
				w.extra_projectiles += 2
				w.spread = max(w.spread, deg_to_rad(2.0)) + deg_to_rad(2.0),
		},
		{
			"id": "lifesteal",
			"name": "LIFESTEAL",
			"desc": "Heal 25% of damage dealt",
			"color": Color(0.8, 0.2, 0.85),
			"apply": func(w: Weapon) -> void:
				w.lifesteal += 0.25
				w.bullet_color = w.bullet_color.lerp(Color(0.85, 0.15, 0.8), 0.4),
		},
		{
			"id": "explosive",
			"name": "EXPLOSIVE ROUNDS",
			"desc": "Bullets explode. Stacks: bigger radius + more damage",
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
			"id": "precision",
			"name": "PRECISION",
			"desc": "2× headshot multiplier",
			"color": Color(0.9, 0.9, 1.0),
			"apply": func(w: Weapon) -> void:
				w.headshot_mult *= 2.0,
		},
		{
			"id": "heavy_rounds",
			"name": "HEAVY ROUNDS",
			"desc": "+100% damage, -30% fire rate",
			"color": Color(0.7, 0.4, 0.2),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 2.0
				w.fire_rate_mult *= 0.7
				w.bullet_scale *= 1.4
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.55, 0.2), 0.3),
		},
		{
			"id": "sniper",
			"name": "SNIPER",
			"desc": "×3 damage, slower, 3-round mag, pin-point accurate",
			"color": Color(0.55, 0.85, 1.0),
			"apply": func(w: Weapon) -> void:
				w.damage_mult *= 3.0
				w.fire_rate_mult *= 0.4
				w.mag_size_bonus -= 7
				w.spread = 0.0
				w.headshot_mult *= 1.5
				w.bullet_scale *= 0.8
				w.bullet_color = w.bullet_color.lerp(Color(0.55, 0.85, 1.0), 0.6),
		},
		{
			"id": "uzi",
			"name": "UZI",
			"desc": "Full-auto, ×3 fire rate, +20 ammo, more spread",
			"rarity": "rare",
			"color": Color(1.0, 0.65, 0.25),
			"apply": func(w: Weapon) -> void:
				w.full_auto = true
				w.fire_rate_mult *= 3.0
				w.mag_size_bonus += 20
				w.spread += deg_to_rad(2.5)
				w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.55, 0.15), 0.5),
		},
		{
			"id": "knockback",
			"name": "KNOCKBACK",
			"desc": "Bullet hits shove enemies away",
			"color": Color(0.8, 0.95, 1.0),
			"apply": func(w: Weapon) -> void:
				w.knockback += 10.0
				w.bullet_scale *= 1.08
				w.bullet_color = w.bullet_color.lerp(Color(0.72, 0.95, 1.0), 0.4),
		},
		{
			"id": "big_head",
			"name": "BIG HEAD",
			"desc": "+80% damage, but your head is huge — easier to headshot",
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
			"desc": "+75 max HP, but your body is bigger and easier to hit",
			"color": Color(0.55, 0.9, 0.55),
			"apply": func(w: Weapon) -> void:
				w.max_hp_bonus += 75
				w.body_scale *= 1.5,
		},
		{
			"id": "acrobat",
			"name": "ACROBAT",
			"desc": "+2 extra air-jumps",
			"color": Color(0.5, 0.9, 1.0),
			"apply": func(w: Weapon) -> void:
				w.extra_jumps += 2,
		},
		{
			"id": "teleport",
			"name": "TELEPORT",
			"desc": "RMB: teleport where you aim (2s cooldown)",
			"color": Color(0.75, 0.35, 1.0),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_TELEPORT,
		},
		{
			"id": "shield",
			"name": "SHIELD",
			"desc": "RMB: 2s invulnerability bubble (8s cooldown)",
			"color": Color(0.4, 0.8, 1.0),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_SHIELD,
		},
		{
			"id": "invisible",
			"name": "INVISIBLE",
			"desc": "RMB: vanish for 4s (10s cooldown)",
			"color": Color(0.55, 1.0, 0.9),
			"apply": func(w: Weapon) -> void:
				w.special = Weapon.SPECIAL_INVISIBLE,
		},
	]

static func by_id(id: String) -> Dictionary:
	for c in all():
		if c.id == id:
			return c
	return {}

# Pick `count` unique random card ids. If count > pool size, returns the full pool.
static func random_ids(count: int) -> Array[String]:
	var out: Array[String] = []
	var pool: Array = all()
	while out.size() < count and not pool.is_empty():
		var total_weight := 0.0
		for card in pool:
			total_weight += _rarity_weight(str(card.get("rarity", "common")))
		var pick := randf() * total_weight
		var chosen_index := 0
		for i in pool.size():
			pick -= _rarity_weight(str(pool[i].get("rarity", "common")))
			if pick <= 0.0:
				chosen_index = i
				break
		out.append(str(pool[chosen_index].id))
		pool.remove_at(chosen_index)
	return out

static func _rarity_weight(rarity: String) -> float:
	match rarity:
		"rare":
			return 0.35
		_:
			return 1.0
