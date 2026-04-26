@tool
extends Node3D

# Builds a stylized first-person rifle from primitive meshes. Every @export
# below has a setter that rebuilds the gun, so tweaking values in the editor
# inspector updates the viewport in real time.
#
# Usage:
#   • Open scenes/gun_preview.tscn in the editor to iterate visually.
#   • Or attach this script to a Node3D in any scene to use the gun in-game.

@export_group("Receiver")
@export var receiver_size: Vector3 = Vector3(0.075, 0.10, 0.26) : set = _set_receiver_size
@export var receiver_color: Color = Color(0.13, 0.14, 0.17) : set = _set_receiver_color
@export var receiver_metallic: float = 0.85 : set = _set_receiver_metallic
@export var receiver_roughness: float = 0.32 : set = _set_receiver_roughness

@export_group("Barrel")
@export var barrel_count: int = 1 : set = _set_barrel_count
@export var barrel_length: float = 0.42 : set = _set_barrel_length
@export var barrel_radius: float = 0.022 : set = _set_barrel_radius
@export var muzzle_flare: float = 1.55 : set = _set_muzzle_flare  # muzzle radius = barrel_radius × this
@export var muzzle_length: float = 0.05 : set = _set_muzzle_length
@export var wide_muzzle: bool = false : set = _set_wide_muzzle  # Havoc-style wide rectangular muzzle

@export_group("Magazine")
@export var mag_size: Vector3 = Vector3(0.08, 0.16, 0.06) : set = _set_mag_size
@export var mag_offset_z: float = 0.04 : set = _set_mag_offset_z
@export var mag_tilt_deg: float = 0.0 : set = _set_mag_tilt_deg
@export var mag_drum: bool = false : set = _set_mag_drum  # circular drum magazine (Tommy-gun style)

@export_group("Furniture")
@export var foregrip_length: float = 0.12 : set = _set_foregrip_length
@export var foregrip_radius: float = 0.022 : set = _set_foregrip_radius
@export var foregrip_offset_z: float = 0.26 : set = _set_foregrip_offset_z
@export var handguard_height: float = 0.025 : set = _set_handguard_height
@export var sight_rail_height: float = 0.02 : set = _set_sight_rail_height
@export var sight_post_height: float = 0.04 : set = _set_sight_post_height
@export var rear_sight_radius: float = 0.022 : set = _set_rear_sight_radius
@export var has_scope: bool = false : set = _set_has_scope
@export var scope_length: float = 0.18 : set = _set_scope_length
@export var pistol_grip_length: float = 0.13 : set = _set_pistol_grip_length
@export var pistol_grip_radius: float = 0.024 : set = _set_pistol_grip_radius
@export var pistol_grip_tilt_deg: float = -36.0 : set = _set_pistol_grip_tilt_deg
@export var trigger_guard_radius: float = 0.028 : set = _set_trigger_guard_radius
@export var stock_size: Vector3 = Vector3(0.05, 0.07, 0.16) : set = _set_stock_size
@export var stock_taper: float = 0.45 : set = _set_stock_taper  # front height as fraction of back
@export var has_stock: bool = true : set = _set_has_stock
@export var has_foregrip: bool = true : set = _set_has_foregrip

@export_group("Charging Handle")
# Bolt / charging handle: a small cylinder sitting in a slot on top of the
# receiver. Snaps fully back the instant the gun fires, then slides forward
# to rest over bolt_cycle_time. Visible as the gun "cycling" between shots.
@export var bolt_travel: float = 0.035    # how far back it slides (metres)
@export var bolt_cycle_time: float = 0.08 # seconds to slide back to rest
@export var bolt_radius: float = 0.009
@export var bolt_length: float = 0.055

@export_group("Heat")
# Barrels glow when fired a lot. add_heat() pumps in per-shot heat (Player
# scales it by damage_mult); we decay exponentially each frame and map the
# resulting 0..1+ value through a blackbody-like emission curve.
@export var heat_glow_threshold: float = 0.15      # below this, barrel stays cold (subtle floor)
@export var heat_decay_per_sec: float = 0.3        # exponential decay rate
@export var heat_max_emission_energy: float = 6.0  # emission_energy_multiplier at heat=1
@export var heat_emits_light: bool = true          # OmniLight at muzzle, runtime only
@export var heat_add_factor: float = 0.01           # The amount of heat added per shot (depends on damage)
const RECEIVER_HEAT_FRACTION := 0.1  # receiver glows at 40% of barrel intensity

@export_group("Indicator (Emissive)")
@export var indicator_color: Color = Color(0.4, 1.0, 0.95) : set = _set_indicator_color
@export var indicator_size: Vector3 = Vector3(0.012, 0.012, 0.05) : set = _set_indicator_size
@export var indicator_energy: float = 4.0 : set = _set_indicator_energy
# Default off — the OmniLight gizmo clutters the preview. Flip on for game.
@export var indicator_emits_light: bool = false : set = _set_indicator_emits_light

@export_group("Preview From Weapon Stats")
# Flip this on, then tweak the stats below — they'll drive every gun part
# via apply_weapon_stats(), letting you preview how a card-modified weapon
# looks. Flip off to manually tweak individual exports above.
@export var preview_apply_stats: bool = false : set = _set_preview_apply_stats
@export var preview_spread_deg: float = 0.46 : set = _set_preview_spread_deg
@export var preview_bullet_scale: float = 1.0 : set = _set_preview_bullet_scale
@export var preview_damage_mult: float = 1.0 : set = _set_preview_damage_mult
@export var preview_mag_size: int = 5 : set = _set_preview_mag_size
@export var preview_fire_rate_mult: float = 1.0 : set = _set_preview_fire_rate_mult
@export var preview_shots_per_trigger: int = 1 : set = _set_preview_shots_per_trigger

# ---- Setters: each export rebuilds when changed ----
func _set_receiver_size(v: Vector3) -> void:        receiver_size = v;        _rebuild()
func _set_receiver_color(v: Color) -> void:         receiver_color = v;       _rebuild()
func _set_receiver_metallic(v: float) -> void:      receiver_metallic = v;    _rebuild()
func _set_receiver_roughness(v: float) -> void:     receiver_roughness = v;   _rebuild()
func _set_barrel_count(v: int) -> void:             barrel_count = max(1, v); _rebuild()
func _set_barrel_length(v: float) -> void:          barrel_length = v;        _rebuild()
func _set_barrel_radius(v: float) -> void:          barrel_radius = v;        _rebuild()
func _set_muzzle_flare(v: float) -> void:           muzzle_flare = v;         _rebuild()
func _set_muzzle_length(v: float) -> void:          muzzle_length = v;        _rebuild()
func _set_wide_muzzle(v: bool) -> void:             wide_muzzle = v;          _rebuild()
func _set_mag_size(v: Vector3) -> void:             mag_size = v;             _rebuild()
func _set_mag_offset_z(v: float) -> void:           mag_offset_z = v;         _rebuild()
func _set_mag_tilt_deg(v: float) -> void:           mag_tilt_deg = v;         _rebuild()
func _set_mag_drum(v: bool) -> void:                mag_drum = v;             _rebuild()
func _set_foregrip_length(v: float) -> void:        foregrip_length = v;      _rebuild()
func _set_foregrip_radius(v: float) -> void:        foregrip_radius = v;      _rebuild()
func _set_foregrip_offset_z(v: float) -> void:      foregrip_offset_z = v;    _rebuild()
func _set_handguard_height(v: float) -> void:       handguard_height = v;     _rebuild()
func _set_sight_rail_height(v: float) -> void:      sight_rail_height = v;    _rebuild()
func _set_sight_post_height(v: float) -> void:      sight_post_height = v;    _rebuild()
func _set_rear_sight_radius(v: float) -> void:      rear_sight_radius = v;    _rebuild()
func _set_has_scope(v: bool) -> void:               has_scope = v;            _rebuild()
func _set_scope_length(v: float) -> void:           scope_length = v;         _rebuild()
func _set_pistol_grip_length(v: float) -> void:     pistol_grip_length = v;   _rebuild()
func _set_pistol_grip_radius(v: float) -> void:     pistol_grip_radius = v;   _rebuild()
func _set_pistol_grip_tilt_deg(v: float) -> void:   pistol_grip_tilt_deg = v; _rebuild()
func _set_trigger_guard_radius(v: float) -> void:   trigger_guard_radius = v; _rebuild()
func _set_stock_size(v: Vector3) -> void:           stock_size = v;           _rebuild()
func _set_stock_taper(v: float) -> void:            stock_taper = v;          _rebuild()
func _set_has_stock(v: bool) -> void:               has_stock = v;            _rebuild()
func _set_has_foregrip(v: bool) -> void:            has_foregrip = v;         _rebuild()
func _set_indicator_color(v: Color) -> void:        indicator_color = v;      _rebuild()
func _set_indicator_size(v: Vector3) -> void:       indicator_size = v;       _rebuild()
func _set_indicator_energy(v: float) -> void:       indicator_energy = v;     _rebuild()
func _set_indicator_emits_light(v: bool) -> void:   indicator_emits_light = v; _rebuild()

func _set_preview_apply_stats(v: bool) -> void:     preview_apply_stats = v;     _request_preview()
func _set_preview_spread_deg(v: float) -> void:     preview_spread_deg = v;      _request_preview()
func _set_preview_bullet_scale(v: float) -> void:   preview_bullet_scale = v;    _request_preview()
func _set_preview_damage_mult(v: float) -> void:    preview_damage_mult = v;     _request_preview()
func _set_preview_mag_size(v: int) -> void:         preview_mag_size = v;        _request_preview()
func _set_preview_fire_rate_mult(v: float) -> void: preview_fire_rate_mult = v;  _request_preview()
func _set_preview_shots_per_trigger(v: int) -> void: preview_shots_per_trigger = max(1, v); _request_preview()

# Setters can fire during scene-load before sibling properties settle, which
# briefly leaves them as Nil. Coalesce calls with a deferred apply so we
# only run once everything is initialised.
var _preview_pending: bool = false
func _request_preview() -> void:
	if _preview_pending:
		return
	_preview_pending = true
	_apply_preview.call_deferred()

# Build a temporary Weapon from the preview exports and pump it through the
# normal mapping. No-op when the toggle is off, so manual tweaks to the
# part exports above keep working.
func _apply_preview() -> void:
	_preview_pending = false
	if not preview_apply_stats:
		return
	var w := Weapon.new()
	if w == null:
		return
	w.spread = deg_to_rad(float(preview_spread_deg))
	w.bullet_scale = float(preview_bullet_scale)
	w.damage_mult = float(preview_damage_mult)
	w.mag_size_bonus = int(preview_mag_size) - Weapon.BASE_MAG_SIZE
	w.fire_rate_mult = float(preview_fire_rate_mult)
	w.extra_projectiles = max(0, int(preview_shots_per_trigger) - 1)
	apply_weapon_stats(w)

var _suppress_rebuild: bool = false

# --- Heat state ---
# Barrel material is rebuilt with the rest of the gun, but heat persists
# across rebuilds so swapping cards mid-spam doesn't cool the gun instantly.
var heat: float = 0.0
var _barrel_material: StandardMaterial3D = null
var _receiver_material: StandardMaterial3D = null
var _heat_light: OmniLight3D = null

# --- Bolt / charging handle state ---
# `_bolt_back` is the current backward offset (0 = rest, bolt_travel = max).
# Snaps to bolt_travel on cycle_bolt(), decays linearly back to zero over
# `_bolt_cycle_seconds` (Player passes the current fire interval, so the
# bolt arrives at rest exactly as the next shot snaps it back again).
# Two bolts (left + right) cycle in lock-step, so a single offset drives both.
var _bolts: Array[MeshInstance3D] = []
var _bolt_rest_z: float = 0.0
var _bolt_back: float = 0.0
var _bolt_cycle_seconds: float = 0.08

func _ready() -> void:
	_rebuild()
	_request_preview()

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Heat — exponential decay. Snappier than linear and matches how a hot
	# object actually radiates away energy.
	if heat > 0.0:
		heat *= exp(-heat_decay_per_sec * delta)
		if heat < 0.001:
			heat = 0.0
		_update_heat_visual()
	# Bolt — linear return from full back to rest. Snap-back is instant on
	# cycle_bolt(); only the forward stroke needs to be animated here.
	if _bolts.size() > 0 and _bolt_back > 0.0:
		var return_speed: float = bolt_travel / maxf(0.001, _bolt_cycle_seconds)
		_bolt_back = maxf(0.0, _bolt_back - return_speed * delta)
		var z: float = _bolt_rest_z + _bolt_back
		for b in _bolts:
			b.position = Vector3(b.position.x, b.position.y, z)

# Called by Player on every shot — slams the bolt to its rear stop. The
# forward return happens in _process so rapid fire keeps it pinned back.
# `cycle_seconds` is the time the bolt should take to return to rest;
# pass the weapon's current fire interval so it arrives just as the next
# shot snaps it back again. <= 0 falls back to the bolt_cycle_time export.
func cycle_bolt(cycle_seconds: float = -1.0) -> void:
	if _bolts.size() == 0:
		return
	_bolt_back = bolt_travel
	_bolt_cycle_seconds = cycle_seconds if cycle_seconds > 0.0 else bolt_cycle_time
	var z: float = _bolt_rest_z + _bolt_back
	for b in _bolts:
		b.position = Vector3(b.position.x, b.position.y, z)

# Called by Player on every shot. amount is typically a small base value
# scaled by damage_mult so heavy-hitting builds heat up faster.
func add_heat(amount: float) -> void:
	amount *= heat_add_factor
	if amount <= 0.0:
		return
	heat = clampf(heat + amount, 0.0, 1.5)
	_update_heat_visual()

func _update_heat_visual() -> void:
	if _barrel_material == null:
		return
	# Below the threshold, barrel reads as cold steel (no emission). Above it,
	# colour walks from dull red → bright red → orange → yellow-white,
	# roughly tracking how heated iron actually looks.
	var glow_t: float = clampf(smoothstep(heat_glow_threshold, 1.0, heat), 0.0, 1.0)
	if glow_t <= 0.0:
		_barrel_material.emission_enabled = false
		_barrel_material.emission_energy_multiplier = 0.0
		if _receiver_material:
			_receiver_material.emission_enabled = false
			_receiver_material.emission_energy_multiplier = 0.0
		if _heat_light:
			_heat_light.visible = false
		return
	var r: float = 1.0
	var g: float = lerpf(0.0, 0.7, pow(glow_t, 1.4))
	var b: float = lerpf(0.0, 0.3, pow(glow_t, 3.0))
	var emission := Color(r, g, b)
	var barrel_energy: float = lerpf(0.0, heat_max_emission_energy, glow_t)
	_barrel_material.emission_enabled = true
	_barrel_material.emission = emission
	_barrel_material.emission_energy_multiplier = barrel_energy
	# Receiver heats up too (it's bolted to the barrel) but only partially —
	# the chamber/breech area is hot while the grip end stays cool. Mid-body
	# emissive at 40% sells the conduction without overpowering the barrel.
	if _receiver_material:
		_receiver_material.emission_enabled = true
		_receiver_material.emission = emission
		_receiver_material.emission_energy_multiplier = barrel_energy * RECEIVER_HEAT_FRACTION
	if _heat_light:
		_heat_light.visible = true
		_heat_light.light_color = emission
		_heat_light.light_energy = lerpf(0.0, 1.2, glow_t)

# Map a Weapon's gameplay stats onto the gun's visual parameters. Bulk-set
# everything inside _suppress_rebuild so we only rebuild meshes once.
#   Accuracy (low spread)   → longer barrel
#   Bullet size             → fatter barrel + flare
#   Damage                  → bigger receiver + deeper magazine
#   Mag size                → taller magazine
#   Fire rate > 1.5×        → stock + foregrip appear (bracing for full-auto)
func apply_weapon_stats(w: Weapon) -> void:
	if w == null:
		return
	_suppress_rebuild = true

	# Barrel length curve: a steep power so the default gun stays modest and
	# only very tight-spread builds (SNIPER, stacked accuracy) earn the long
	# barrel. Max ~1.4 m at spread 0; ~0.42 m at default spread.
	var spread_factor: float = clampf(1.0 - w.spread / 0.05, 0.0, 1.0)
	barrel_length = lerpf(0.20, 1.4, pow(spread_factor, 10.0))

	# Damage and bullet size both fatten the barrel — heavier rounds need a
	# beefier barrel; the muzzle flare scales with it automatically.
	var dmg_factor: float = clampf((w.damage_mult - 1.0) / 4.0, 0.0, 1.0)
	var dmg_barrel_scale: float = lerpf(1.0, 1.7, dmg_factor)
	barrel_radius = clampf(0.022 * w.bullet_scale * dmg_barrel_scale, 0.012, 0.10)
	barrel_count = w.get_shots_per_trigger()

	# Receiver stays at its authored base size — damage drives the barrel now.
	receiver_size = Vector3(0.075, 0.10, 0.26)
	var rounds: int = w.get_mag_size()
	mag_drum = rounds > 30
	if mag_drum:
		# For drums: mag_size.y becomes the drum diameter, mag_size.x the thickness.
		var drum_d: float = clampf(0.18 + 0.006 * float(rounds - 30), 0.18, 0.36)
		mag_size = Vector3(0.07, drum_d, lerpf(0.06, 0.11, dmg_factor))
	else:
		var mag_h: float = clampf(0.04 + 0.024 * float(rounds), 0.06, 0.6)
		var mag_z: float = lerpf(0.06, 0.11, dmg_factor)
		mag_size = Vector3(0.08, mag_h, mag_z)

	# Long-barrelled guns need a shoulder stock + foregrip to brace.
	# Threshold is roughly mid-range — short SMG / pistol stays bare,
	# rifle-length barrels gain the bracing furniture.
	has_stock = barrel_length > 0.55
	has_foregrip = barrel_length > 0.55
	# Pin-point accuracy gets a scope. Default base spread is ~0.008 rad (~0.46°);
	# SNIPER drops it to 0. Threshold 0.003 rad (~0.17°) fires for any sniper-
	# class build but not casual accuracy buffs.
	has_scope = w.spread < 0.003
	# Very heavy hitters get a Havoc-style wide rectangular muzzle.
	wide_muzzle = w.damage_mult >= 3.0

	_suppress_rebuild = false
	_rebuild()

# ---- Build ----
# Forward is local -Z (Godot convention); +Y up; +X right.
# Receiver is centred at origin, barrel pokes forward (-Z), magazine drops
# below (+Y down), sights sit on top.
func _rebuild() -> void:
	if _suppress_rebuild:
		return
	# remove_child is synchronous; queue_free is deferred. Detach first so
	# new children added below don't collide with old names (which would
	# auto-rename them to @MeshInstance3D@N and break get_node lookups).
	for c in get_children():
		remove_child(c)
		c.queue_free()

	var metal := _make_material(receiver_color, receiver_metallic, receiver_roughness)
	var darker_metal := _make_material(receiver_color * 0.6, 0.95, 0.22)
	# Barrels + muzzles get their own material so heat-driven emission
	# doesn't bleed onto the stock / sights that share darker_metal.
	_barrel_material = _make_material(receiver_color * 0.6, 0.95, 0.22)
	# Receiver tracks barrel heat at a reduced fraction (see _update_heat_visual).
	# `metal` is only used by the Receiver mesh, so we can mutate it freely.
	_receiver_material = metal

	# Multi-barrel layout: barrels spread horizontally with a small gap. The
	# receiver widens to wrap them all so it doesn't look detached.
	var n_barrels: int = max(1, barrel_count)
	var barrel_pitch: float = barrel_radius * 2.4    # centre-to-centre spacing
	var barrel_span: float = barrel_pitch * float(n_barrels - 1)
	var min_receiver_w: float = barrel_span + barrel_radius * 3.0
	var effective_receiver_size := Vector3(maxf(receiver_size.x, min_receiver_w), receiver_size.y, receiver_size.z)

	# Receiver body
	_add_box("Receiver", effective_receiver_size, Vector3.ZERO, metal)

	# Sight rail (thin slab on top of receiver)
	var rail_y: float = effective_receiver_size.y * 0.5 + sight_rail_height * 0.5
	_add_box("SightRail", Vector3(effective_receiver_size.x * 0.8, sight_rail_height, effective_receiver_size.z * 0.85), Vector3(0, rail_y, 0), darker_metal)

	# Charging handle (bolt) — recessed slot on each side of the receiver,
	# axis parallel to the barrel, mirrored. Both bolts cycle together via
	# cycle_bolt + _process. Slot is a thin near-black box sunk into the
	# side; bolt is a bright-steel cylinder protruding from it.
	var slot_x_abs: float = effective_receiver_size.x * 0.5
	var slot_depth_z: float = effective_receiver_size.z * 0.55
	var slot_h: float = effective_receiver_size.y * 0.35
	var slot_thickness: float = 0.012
	var slot_z: float = effective_receiver_size.z * 0.05
	var slot_mat := _make_material(receiver_color * 0.25, 0.4, 0.85)  # dark recess
	var bolt_mat := _make_material(Color(0.55, 0.57, 0.62), 0.95, 0.18)  # bright steel
	# Rest position: forward end of the slot so backward travel stays inside it.
	_bolt_rest_z = slot_z - slot_depth_z * 0.5 + bolt_length * 0.5
	_bolts.clear()
	for side in [-1.0, 1.0]:
		var sign_str: String = "L" if side < 0.0 else "R"
		_add_box("BoltSlot" + sign_str,
			Vector3(slot_thickness, slot_h, slot_depth_z),
			Vector3(side * (slot_x_abs + slot_thickness * 0.5), 0, slot_z),
			slot_mat)
		var bolt := _add_cylinder("ChargingHandle" + sign_str,
			bolt_radius, bolt_radius, bolt_length,
			Vector3(side * (slot_x_abs + slot_thickness + bolt_radius), 0, _bolt_rest_z),
			bolt_mat)
		# Re-apply current back-offset so a rebuild mid-cycle doesn't pop the bolt.
		bolt.position.z = _bolt_rest_z + _bolt_back
		_bolts.append(bolt)

	# Barrels + muzzles — laid out side by side, centred on x = 0.
	var receiver_front_z: float = -effective_receiver_size.z * 0.5
	var barrel_centre_z: float = receiver_front_z - barrel_length * 0.5
	var muzzle_centre_z: float = receiver_front_z - barrel_length - muzzle_length * 0.5
	var muzzle_r: float = barrel_radius * muzzle_flare
	for i in n_barrels:
		var bx: float = (float(i) - float(n_barrels - 1) * 0.5) * barrel_pitch
		_add_cylinder("Barrel%d" % i, barrel_radius, barrel_radius, barrel_length, Vector3(bx, 0, barrel_centre_z), _barrel_material)
		if wide_muzzle:
			# Havoc-style: a wide horizontal slab in place of the cone muzzle.
			var slab_size := Vector3(barrel_radius * 4.5, barrel_radius * 1.6, muzzle_length)
			_add_box("Muzzle%d" % i, slab_size, Vector3(bx, 0, muzzle_centre_z), _barrel_material)
		else:
			_add_cylinder("Muzzle%d" % i, muzzle_r, muzzle_r * 0.85, muzzle_length, Vector3(bx, 0, muzzle_centre_z), _barrel_material)

	# Magazine — box (default) or drum (Tommy-gun style cylinder, axis along X)
	# when mag_drum is on.
	if mag_drum:
		# Drum diameter = mag_size.y; thickness = mag_size.x. Centred just
		# below the receiver so the top of the drum touches the receiver bottom.
		var drum_radius: float = mag_size.y * 0.5
		var drum_thickness: float = mag_size.x
		var drum_y: float = -effective_receiver_size.y * 0.5 - drum_radius
		var drum := MeshInstance3D.new()
		drum.name = "Magazine"
		var dm := CylinderMesh.new()
		dm.top_radius = drum_radius
		dm.bottom_radius = drum_radius
		dm.height = drum_thickness
		dm.radial_segments = 24
		drum.mesh = dm
		drum.material_override = darker_metal
		# Cylinder default axis = Y; rotate 90° around X so the axis lies along Z
		# (drum face visible from the front, thin edge from the side).
		drum.rotation = Vector3(PI * 0.5, 0, 0)
		drum.position = Vector3(0, drum_y, mag_offset_z)
		add_child(drum)
		_finalize_owner(drum)
	else:
		var mag_y: float = -effective_receiver_size.y * 0.5 - mag_size.y * 0.5
		var mag := _add_box("Magazine", mag_size, Vector3(0, mag_y, mag_offset_z), darker_metal)
		mag.rotation = Vector3(deg_to_rad(mag_tilt_deg), 0, 0)
		mag.position = Vector3(0, mag_y, mag_offset_z)

	# Handguard + foregrip (only when the gun bracing is "on" — full-auto)
	if has_foregrip:
		var foregrip_z: float = receiver_front_z - foregrip_offset_z
		var hg_z: float = (receiver_front_z + foregrip_z) * 0.5
		var hg_length: float = receiver_front_z - foregrip_z
		var hg_y: float = -barrel_radius - handguard_height * 0.5
		_add_box("Handguard", Vector3(barrel_radius * 2.4, handguard_height, hg_length), Vector3(0, hg_y, hg_z), darker_metal)

		var foregrip_y: float = hg_y - handguard_height * 0.5 - foregrip_length * 0.5
		var grip := _add_cylinder("Foregrip", foregrip_radius, foregrip_radius * 0.85, foregrip_length, Vector3(0, foregrip_y, foregrip_z), darker_metal)
		grip.rotation = Vector3(deg_to_rad(-8.0), 0, 0)

	# Pistol grip — angled cylinder at back-bottom of the receiver
	var pgrip_z: float = effective_receiver_size.z * 0.32
	var pgrip_y: float = -effective_receiver_size.y * 0.5 - pistol_grip_length * 0.5
	var pgrip := _add_cylinder("PistolGrip", pistol_grip_radius, pistol_grip_radius * 1.05, pistol_grip_length, Vector3(0, pgrip_y, pgrip_z), darker_metal)
	# Tilt grip backwards (toward shooter) for ergonomic feel
	pgrip.rotation = Vector3(deg_to_rad(pistol_grip_tilt_deg), 0, 0)

	# Trigger guard — torus between magazine and pistol grip
	var tg_z: float = (mag_offset_z + pgrip_z) * 0.5
	var tg_y: float = -effective_receiver_size.y * 0.5 - trigger_guard_radius * 0.5
	var tg := _add_torus("TriggerGuard", trigger_guard_radius, trigger_guard_radius * 0.18, Vector3(0, tg_y, tg_z), darker_metal)
	# Rotate so the loop opens downward (axis along X) instead of forward.
	tg.rotation = Vector3(0, 0, PI * 0.5)

	# Stock (only when bracing is "on")
	if has_stock:
		var back_h: float = stock_size.y
		var front_h: float = stock_size.y * clampf(stock_taper, 0.05, 1.0)
		var half_z: float = stock_size.z * 0.5
		var bottom_y: float = -effective_receiver_size.y * 0.5
		var back_z: float = effective_receiver_size.z * 0.5 + half_z * 1.5   # rear half of total depth
		var front_z: float = effective_receiver_size.z * 0.5 + half_z * 0.5  # front half (closer to receiver)
		_add_box("StockBack", Vector3(stock_size.x, back_h, half_z), Vector3(0, bottom_y + back_h * 0.5, back_z), darker_metal)
		_add_box("StockFront", Vector3(stock_size.x * 0.95, front_h, half_z), Vector3(0, bottom_y + front_h * 0.5, front_z), darker_metal)

	# Iron sights — only when no scope is mounted (otherwise they overlap).
	if not has_scope:
		# Front sight post — thin vertical box near the muzzle
		var front_sight_y: float = barrel_radius + sight_post_height * 0.5
		var front_sight_z: float = receiver_front_z - barrel_length * 0.85
		_add_box("FrontSight", Vector3(0.005, sight_post_height, 0.012), Vector3(0, front_sight_y, front_sight_z), darker_metal)
		# Rear sight — torus on the back of the rail
		var rear_sight_y: float = rail_y + sight_rail_height * 0.5 + rear_sight_radius * 0.4
		var rear_sight_z: float = effective_receiver_size.z * 0.32
		_add_torus("RearSight", rear_sight_radius, rear_sight_radius * 0.25, Vector3(0, rear_sight_y, rear_sight_z), darker_metal)
	else:
		# Scope: main tube + objective / eyepiece bells + glowing front lens.
		var tube_r: float = 0.018
		var bell_r: float = 0.028
		var bell_len: float = 0.04
		var scope_y: float = rail_y + sight_rail_height * 0.5 + 0.025
		var scope_z: float = 0.0
		_add_cylinder("ScopeTube", tube_r, tube_r, scope_length, Vector3(0, scope_y, scope_z), darker_metal)
		_add_cylinder("ScopeFrontBell", bell_r, bell_r, bell_len, Vector3(0, scope_y, scope_z - scope_length * 0.5 - bell_len * 0.5), darker_metal)
		_add_cylinder("ScopeBackBell", bell_r, bell_r, bell_len, Vector3(0, scope_y, scope_z + scope_length * 0.5 + bell_len * 0.5), darker_metal)
		# Front lens — emissive disc inside the objective bell.
		var lens_mat := StandardMaterial3D.new()
		lens_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lens_mat.albedo_color = Color(0.45, 0.75, 1.0)
		lens_mat.emission_enabled = true
		lens_mat.emission = Color(0.35, 0.7, 1.0)
		lens_mat.emission_energy_multiplier = 1.8
		_add_cylinder("ScopeLens", bell_r * 0.85, bell_r * 0.85, 0.005, Vector3(0, scope_y, scope_z - scope_length * 0.5 - bell_len - 0.004), lens_mat)

	# Charge indicator — tiny emissive panel on the side of the receiver
	var ind_mat := StandardMaterial3D.new()
	ind_mat.albedo_color = indicator_color
	ind_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ind_mat.emission_enabled = true
	ind_mat.emission = indicator_color
	ind_mat.emission_energy_multiplier = indicator_energy
	var ind_x: float = receiver_size.x * 0.5 + indicator_size.x * 0.5
	_add_box("Indicator", indicator_size, Vector3(ind_x, 0, 0), ind_mat)

	if indicator_emits_light:
		var light := OmniLight3D.new()
		light.name = "IndicatorLight"
		light.light_color = indicator_color
		light.light_energy = 0.6
		light.omni_range = 0.6
		light.position = Vector3(ind_x + 0.04, 0, 0)
		add_child(light)
		_finalize_owner(light)

	# Heat light — sits at the muzzle, off until heat builds. Skip in editor
	# so the OmniLight gizmo doesn't clutter the gun preview.
	_heat_light = null
	if heat_emits_light and not Engine.is_editor_hint():
		var hl := OmniLight3D.new()
		hl.name = "HeatLight"
		hl.position = Vector3(0, 0, muzzle_centre_z)
		hl.omni_range = 0.8
		hl.visible = false
		add_child(hl)
		_heat_light = hl

	# Re-apply current heat to the freshly-built barrel material so swapping
	# weapons mid-burst doesn't visually reset the temperature.
	_update_heat_visual()

# ---- Helpers ----
func _make_material(col: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = clampf(metallic, 0.0, 1.0)
	m.roughness = clampf(roughness, 0.0, 1.0)
	return m

func _add_box(part_name: String, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	_finalize_owner(mi)
	return mi

func _add_cylinder(part_name: String, top_r: float, bottom_r: float, height: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	var cm := CylinderMesh.new()
	cm.top_radius = top_r
	cm.bottom_radius = bottom_r
	cm.height = height
	cm.radial_segments = 16
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	# Cylinder height is along local Y. Rotate 90° around X so it lies along Z.
	mi.rotation = Vector3(PI * 0.5, 0, 0)
	add_child(mi)
	_finalize_owner(mi)
	return mi

func _add_torus(part_name: String, outer_r: float, ring_r: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	var tm := TorusMesh.new()
	tm.outer_radius = outer_r
	tm.inner_radius = maxf(0.001, outer_r - ring_r)
	tm.rings = 16
	tm.ring_segments = 8
	mi.mesh = tm
	mi.material_override = mat
	mi.position = pos
	# Torus default sits in XZ plane (axis = Y). Rotate 90° around X so the
	# hole faces forward along Z.
	mi.rotation = Vector3(PI * 0.5, 0, 0)
	add_child(mi)
	_finalize_owner(mi)
	return mi

# In-editor preview: ensure rebuilt children show in the scene tree dock and
# get cleaned up next rebuild. At runtime owner doesn't matter.
func _finalize_owner(node: Node) -> void:
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		node.owner = get_tree().edited_scene_root
