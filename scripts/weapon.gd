class_name Weapon
extends Resource

# Single source of truth for rifle stats. Every card mutates fields on this
# resource; Player reads the getters at fire time. Adding a new mechanic
# means: add a field here, add a getter if derived, add a card that sets it.

# --- Immutable base (the "unmodified" gun) ---
const BASE_DAMAGE := 12.0
const BASE_FIRE_INTERVAL := 0.07
const BASE_MAG_SIZE := 30
const BASE_RELOAD_TIME := 1.2
const BASE_HEADSHOT_MULT := 2.0
const BASE_BULLET_COLOR := Color(1.0, 0.9, 0.3)

# --- Multiplicative modifiers (cards multiply) ---
var damage_mult: float = 1.0
var fire_rate_mult: float = 1.0        # >1 = faster
var reload_mult: float = 1.0           # >1 = faster
var headshot_mult: float = 1.0         # stacks on top of BASE_HEADSHOT_MULT

# --- Additive modifiers ---
var mag_size_bonus: int = 0
var extra_projectiles: int = 0         # bullets per trigger beyond the first
var pierce_count: int = 0              # extra players a ray can pass through
var ricochet_count: int = 0            # wall bounces

# --- Behaviour knobs ---
var spread: float = 0.0                # radians; random yaw+pitch offset per shot
var lifesteal: float = 0.0             # fraction of damage dealt returned as heal
var explosive_radius: float = 0.0      # per-bullet splash radius (m)
var explosive_damage: float = 0.0      # max damage at epicenter

# --- Visuals ---
var bullet_color: Color = BASE_BULLET_COLOR
var bullet_scale: float = 1.0          # scales tracer brightness + muzzle flash

# --- Tracking ---
var applied_cards: Array[String] = []

# --- Derived getters --- (never read the raw fields in gameplay code)
func get_damage() -> float:
	return BASE_DAMAGE * damage_mult

func get_fire_interval() -> float:
	return BASE_FIRE_INTERVAL / max(0.01, fire_rate_mult)

func get_mag_size() -> int:
	return max(1, BASE_MAG_SIZE + mag_size_bonus)

func get_reload_time() -> float:
	return BASE_RELOAD_TIME / max(0.01, reload_mult)

func get_headshot_mult() -> float:
	return BASE_HEADSHOT_MULT * headshot_mult

func get_shots_per_trigger() -> int:
	return 1 + extra_projectiles

func reset() -> void:
	damage_mult = 1.0
	fire_rate_mult = 1.0
	reload_mult = 1.0
	headshot_mult = 1.0
	mag_size_bonus = 0
	extra_projectiles = 0
	pierce_count = 0
	ricochet_count = 0
	spread = 0.0
	lifesteal = 0.0
	explosive_radius = 0.0
	explosive_damage = 0.0
	bullet_color = BASE_BULLET_COLOR
	bullet_scale = 1.0
	applied_cards.clear()
