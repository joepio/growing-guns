class_name Weapon
extends Resource

# Single source of truth for rifle stats. Every card mutates fields on this
# resource; Player reads the getters at fire time. Adding a new mechanic
# means: add a field here, add a getter if derived, add a card that sets it.

# --- Immutable base (the "unmodified" gun) ---
# Default mid-damage pistol with a small non-zero spread — you can't snap
# headshots at range for free, but holding fire keeps shooting at the weapon's
# fire interval.
const BASE_DAMAGE := 22.0
const MIN_DAMAGE := 1.0
const BASE_FIRE_INTERVAL := 0.22
const BASE_MAG_SIZE := 5
const BASE_RELOAD_TIME := 1.2
const BASE_HEADSHOT_MULT := 2.0
const BASE_SPREAD := 0.008                # radians — ~0.46°, noticeable at range
const BASE_BULLET_COLOR := Color(1.0, 0.9, 0.3)
const MAX_SHOTS_PER_TRIGGER := 16
const MAX_PROJECTILES_PER_SECOND := 240.0

# --- Special ability (RMB). Cards swap which one is equipped. ---
const SPECIAL_GRENADE := "grenade"
const SPECIAL_TELEPORT := "teleport"
const SPECIAL_ZOOM := "zoom"
const SPECIAL_SWORD := "sword"
const SPECIAL_AIR_STRIKE := "air_strike"
const SPECIAL_ION_CANNON := "ion_cannon"
const SPECIAL_CLUSTER_GRENADE := "cluster_grenade"

# --- Multiplicative modifiers (cards multiply) ---
@export var damage_mult: float = 1.0
@export var fire_rate_mult: float = 1.0        # >1 = faster
@export var reload_mult: float = 1.0           # >1 = faster
@export var headshot_mult: float = 1.0         # stacks on top of BASE_HEADSHOT_MULT

# --- Additive modifiers ---
@export var mag_size_bonus: int = 0
@export var extra_projectiles: int = 0         # bullets per trigger beyond the first
@export var ricochet_count: int = 0            # wall bounces
@export var body_ricochet_count: int = 0       # enemy bullets that bounce off your body
@export var last_shot_damage_mult: float = 1.0 # multiplier on the final round in mag
@export var silencer_stacks: int = 0           # hides shot visuals; −10% dmg per stack in apply

# --- Behaviour knobs ---
@export var spread: float = BASE_SPREAD        # radians; random yaw+pitch offset per shot
const BASE_RECOIL := 0.018                      # radians of shot-to-shot bloom; decays in Player
@export var recoil_per_shot: float = BASE_RECOIL
@export var lifesteal: float = 0.0             # fraction of damage dealt returned as heal
@export var explosive_radius: float = 0.0      # per-bullet splash radius (m)
@export var explosive_damage: float = 0.0      # max damage at epicenter
@export var move_speed_mult: float = 1.0       # scales walk/air movement
const BASE_KNOCKBACK := 3.0            # every shot gives a light nudge
@export var knockback: float = BASE_KNOCKBACK   # impulse applied on bullet hit
@export var special_cooldown_mult: float = 1.0 # <1 = special recharges faster
@export var melee_damage_mult: float = 1.0     # scales melee damage
@export var melee_scale: float = 1.0           # scales melee animation and range
@export var homing: float = 0.0                # degrees-per-second steering toward closest forward target
@export var damage_over_time: float = 0.0      # bonus fraction for bullet damage converted to DOT
@export var dot_duration: float = 3.0
@export var slow_on_hit: float = 1.0           # <1 = target movement multiplier
@export var slow_duration: float = 0.0
@export var grow_damage_per_meter: float = 0.0 # bullet damage gained per meter flown
@export var ricochet_damage_mult: float = 1.0  # extra damage per completed bounce
@export var reload_on_hit: int = 0             # bullets restored when dealing damage
@export var phoenix_revives: int = 0           # revives available each spawn/round
@export var world_pierce_count: int = 0        # world surfaces a bullet can drill through
@export var impact_mines: int = 0              # mines planted on bullet impact

# --- Visuals ---
@export var bullet_color: Color = BASE_BULLET_COLOR
@export var bullet_speed_mult: float = 1.0       # scales projectile travel speed
@export var bullet_scale: float = 1.0          # scales tracer brightness + muzzle flash
const BASE_BULLET_DROP := 30.0                  # matches Player.GRAVITY so bullets fall like everything else
@export var bullet_drop: float = BASE_BULLET_DROP  # m/s² downward acceleration on bullets (0 = laser-flat)

# --- Player-body modifiers (cards can grow head/torso for tradeoff builds) ---
@export var head_scale: float = 1.0            # visual + head hitbox
@export var body_scale: float = 1.0            # visual + torso/legs hitbox (uniform)
@export var body_scale_axes: Vector3 = Vector3.ONE  # per-axis warp on top of body_scale
@export var max_hp_bonus: int = 0              # flat HP added on top of Player.MAX_HEALTH
@export var extra_jumps: int = 0               # additional air-jumps beyond the default double-jump

# --- Special / RMB slot ---
@export var special: String = SPECIAL_GRENADE
@export var special_echo_count: int = 0        # extra delayed special activations
@export var special_reload_amount: int = 0     # ammo restored when special is used
@export var special_cooldown_refund_on_hit: float = 0.0
@export var teleport_blast_radius: float = 0.0

# --- Tracking ---
@export var applied_cards: Array[String] = []

# --- Derived getters --- (never read the raw fields in gameplay code)
func get_damage() -> float:
		return maxf(MIN_DAMAGE, BASE_DAMAGE * damage_mult)

func get_fire_interval() -> float:
		var raw_interval: float = BASE_FIRE_INTERVAL / maxf(0.01, fire_rate_mult)
		var projectile_budget_interval: float = float(get_shots_per_trigger()) / MAX_PROJECTILES_PER_SECOND
		return maxf(raw_interval, projectile_budget_interval)

func get_mag_size() -> int:
		return max(1, BASE_MAG_SIZE + mag_size_bonus)

func get_reload_time() -> float:
		return BASE_RELOAD_TIME / max(0.01, reload_mult)

func get_headshot_mult() -> float:
		return BASE_HEADSHOT_MULT * headshot_mult

func get_spread() -> float:
		return maxf(0.0, spread)

func get_recoil_per_shot() -> float:
		var precision_ratio := get_spread() / BASE_SPREAD
		var precision_recoil_mult := clampf(sqrt(maxf(precision_ratio, 0.0)), 0.15, 1.0)
		return maxf(0.0, recoil_per_shot * precision_recoil_mult)

func get_shots_per_trigger() -> int:
		return mini(MAX_SHOTS_PER_TRIGGER, 1 + extra_projectiles)

func get_projectiles_per_second() -> float:
		return float(get_shots_per_trigger()) / maxf(0.001, get_fire_interval())

func get_bullet_speed() -> float:
		return 165.0 * bullet_speed_mult

func get_bullet_scale() -> float:
		# Visual size of the projectile + tracer + muzzle flash + impact decal.
		# Derived from damage so a heavier round LOOKS heavier without every
		# card having to bump bullet_scale by hand. Square-root keeps the curve
		# from going cartoonish (5× damage → ~2.24× scale, not 5×). The
		# bullet_scale field is left as a manual override for gun-lab previews.
		return bullet_scale * sqrt(maxf(damage_mult, 0.1))

func get_melee_damage() -> int:
	return int(70.0 * melee_damage_mult)

func reset() -> void:
		damage_mult = 1.0
		fire_rate_mult = 1.0
		reload_mult = 1.0
		headshot_mult = 1.0
		mag_size_bonus = 0
		extra_projectiles = 0
		ricochet_count = 0
		body_ricochet_count = 0
		last_shot_damage_mult = 1.0
		silencer_stacks = 0
		spread = BASE_SPREAD
		recoil_per_shot = BASE_RECOIL
		lifesteal = 0.0
		explosive_radius = 0.0
		explosive_damage = 0.0
		move_speed_mult = 1.0
		bullet_speed_mult = 1.0
		bullet_drop = BASE_BULLET_DROP
		knockback = BASE_KNOCKBACK
		special_cooldown_mult = 1.0
		melee_damage_mult = 1.0
		melee_scale = 1.0
		homing = 0.0
		damage_over_time = 0.0
		dot_duration = 3.0
		slow_on_hit = 1.0
		slow_duration = 0.0
		grow_damage_per_meter = 0.0
		ricochet_damage_mult = 1.0
		reload_on_hit = 0
		phoenix_revives = 0
		world_pierce_count = 0
		impact_mines = 0
		bullet_color = BASE_BULLET_COLOR
		bullet_scale = 1.0
		head_scale = 1.0
		body_scale = 1.0
		body_scale_axes = Vector3.ONE
		max_hp_bonus = 0
		extra_jumps = 0
		special = SPECIAL_GRENADE
		special_echo_count = 0
		special_reload_amount = 0
		special_cooldown_refund_on_hit = 0.0
		teleport_blast_radius = 0.0
		applied_cards.clear()
