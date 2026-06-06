class_name WeaponName
extends RefCounted

# Procedural loadout title from stacked cards + standout stats.
# Deterministic — same Weapon state → same name on every peer.

const _NOUNS := {
	"dmg_up": "Slayer",
	"explosive": "Boomstick",
	"ricochet": "Pinball",
	"shotgun": "Blaster",
	"uzi": "Spray",
	"sniper": "Longrifle",
	"bazooka": "Launcher",
	"lifesteal": "Leech",
	"phoenix": "Phoenix",
	"silencer": "Whisper",
	"bouncy_castle": "Bouncehouse",
	"last_bullet": "Finalist",
	"precision": "Needle",
	"rapid_fire": "Stutter",
	"big_mag": "Drum",
	"headhunter": "Skullcracker",
	"chilling_rounds": "Frost",
	"landmine_rounds": "Trapper",
}

const _ADJECTIVES := [
	"Cursed", "Chaotic", "Overgrown", "Unstable", "Golden", "Wretched", "Mega", "Turbo",
]


static func generate(w: Weapon) -> String:
	if w == null or w.applied_cards.is_empty():
		return "Stock Rifle"

	var counts := {}
	for cid in w.applied_cards:
		var key := str(cid)
		counts[key] = int(counts.get(key, 0)) + 1

	var parts: PackedStringArray = []

	# Dominant archetype from stats (before card names).
	if w.fire_rate_mult >= 4.0:
		parts.append("Minigun")
	elif w.explosive_radius >= 6.0:
		parts.append("Demolisher")
	elif w.get_shots_per_trigger() >= 6:
		parts.append("Shotstorm")
	elif w.damage_mult >= 3.5:
		parts.append("Haymaker")
	elif w.silencer_stacks >= 1:
		parts.append("Ghost")

	# Rare / flashy cards first.
	var sorted_ids: Array = counts.keys()
	sorted_ids.sort_custom(func(a: String, b: String) -> bool:
		var ca := CardLibrary.by_id(a)
		var cb := CardLibrary.by_id(b)
		var ra: int = 0 if str(ca.get("rarity", "common")) == "rare" else 1
		var rb: int = 0 if str(cb.get("rarity", "common")) == "rare" else 1
		if ra != rb:
			return ra < rb
		return int(counts[b]) < int(counts[a]))

	for cid in sorted_ids:
		var n: int = int(counts[cid])
		var noun: String = str(_NOUNS.get(cid, ""))
		if noun.is_empty():
			var card := CardLibrary.by_id(cid)
			if card.is_empty():
				continue
			noun = str(card.get("name", cid)).split(" ")[0].capitalize()
		if n >= 2:
			parts.append("%dx %s" % [n, noun])
		else:
			parts.append(noun)
		if parts.size() >= 3:
			break

	if parts.is_empty():
		return "Custom Rig"

	if parts.size() == 1 and w.applied_cards.size() >= 3:
		return "%s %s" % [_ADJECTIVES[_stable_hash(w.applied_cards) % _ADJECTIVES.size()], parts[0]]

	return " ".join(parts)


static func _stable_hash(cards: Array) -> int:
	var h := 0
	for cid in cards:
		h = (h * 31 + str(cid).hash()) & 0x7fffffff
	return h
