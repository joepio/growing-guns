class_name RoundModifiers
extends RefCounted

# Server picks one ID per round; Game.current_round_modifier holds the active
# choice on every peer (synced via _set_round_modifier.rpc).

const IDS: PackedStringArray = [
	"low_gravity",
	"fog",
	"supply_storm",
	"sudden_death",
	"headshots_only",
	"boom_boom",
	"brrrrt",
	"gun_swap",
]

const GRAVITY_MULT := 0.6          # −40% gravity
const BULLET_DROP_MULT := 0.6      # −40% bullet drop
const BODY_DAMAGE_MULT := 0.25     # headshots_only body hits
const PICKUP_SPAWN_MULT := 3.0     # supply_storm
const MODIFIER_CHANCE := 0.3       # fraction of rounds that roll a modifier


static func pick_for_round() -> String:
	if randf() >= MODIFIER_CHANCE:
		return ""
	return IDS[randi() % IDS.size()]


static func pick_random() -> String:
	return IDS[randi() % IDS.size()]


static func display_info(mod_id: String) -> Dictionary:
	match mod_id:
		"low_gravity":
			return {
				"title": "LOW GRAVITY",
				"subtitle": "Floatier jumps & bullets",
				"color": Color(0.55, 0.85, 1.0),
			}
		"fog":
			return {
				"title": "FOG",
				"subtitle": "Short view distance",
				"color": Color(0.72, 0.78, 0.88),
			}
		"supply_storm":
			return {
				"title": "SUPPLY STORM",
				"subtitle": "Sky drops spawn 3× faster",
				"color": Color(0.45, 1.0, 0.65),
			}
		"sudden_death":
			return {
				"title": "SUDDEN DEATH",
				"subtitle": "Lava rises immediately",
				"color": Color(1.0, 0.42, 0.18),
			}
		"headshots_only":
			return {
				"title": "HEADSHOTS ONLY",
				"subtitle": "Body damage ×¼",
				"color": Color(1.0, 0.55, 0.55),
			}
		"boom_boom":
			return {
				"title": "BOOM BOOM",
				"subtitle": "Explosive rounds for everyone",
				"color": Color(1.0, 0.62, 0.15),
			}
		"brrrrt":
			return {
				"title": "BRRRRT",
				"subtitle": "10× fire rate & ammo for everyone",
				"color": Color(1.0, 0.78, 0.35),
			}
		"gun_swap":
			return {
				"title": "GUN SWAP",
				"subtitle": "You spawn with someone else's loadout",
				"color": Color(0.82, 0.48, 1.0),
			}
		_:
			return {"title": "", "subtitle": "", "color": Color.WHITE}


static func announce(mod_id: String) -> String:
	var info: Dictionary = display_info(mod_id)
	return str(info.title)


static func gravity_mult(mod_id: String) -> float:
	return GRAVITY_MULT if mod_id == "low_gravity" else 1.0


static func bullet_drop_mult(mod_id: String) -> float:
	return BULLET_DROP_MULT if mod_id == "low_gravity" else 1.0


static func body_damage_mult(mod_id: String) -> float:
	return BODY_DAMAGE_MULT if mod_id == "headshots_only" else 1.0


static func pickup_spawn_mult(mod_id: String) -> float:
	return PICKUP_SPAWN_MULT if mod_id == "supply_storm" else 1.0


static func lava_immediate(mod_id: String) -> bool:
	return mod_id == "sudden_death"


static func applies_weapon(mod_id: String) -> bool:
	return mod_id == "boom_boom" or mod_id == "brrrrt"


static func needs_gun_swap(mod_id: String) -> bool:
	return mod_id == "gun_swap"


static func apply_weapon(w: Weapon, mod_id: String) -> void:
	match mod_id:
		"boom_boom":
			if w.explosive_radius <= 0.0:
				w.explosive_radius += 4.0
			else:
				w.explosive_radius += 2.5
			w.explosive_damage += 25.0
			w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.45, 0.08), 0.45)
		"brrrrt":
			var mag_before: int = w.get_mag_size()
			w.fire_rate_mult *= 10.0
			w.mag_size_bonus += max(0, mag_before * 9)
		_:
			pass
