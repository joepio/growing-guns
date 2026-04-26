extends Node

# Procedural SFX. Every sound is generated fresh into a short
# AudioStreamGenerator buffer and played one-shot. No samples on disk.
#
# World sounds take an optional `at: Vector3` — when supplied, the sound
# plays through an AudioStreamPlayer3D on a reverb bus, so distance,
# stereo panning, and environment tail come "for free" from Godot's 3D
# audio pipeline. Pass Vector3.INF (or omit) for a plain 2D/UI sound.
#
# Public API: SFX.shot(w, at?), SFX.explosion(at?), SFX.melee(at?),
# SFX.grenade_launch(at?), SFX.jump(at?), SFX.landing(impact_vel, at?),
# SFX.dash(at?), SFX.footstep(at?),
# SFX.hit_received(), SFX.kill_confirm(), SFX.hitmarker(kind, dmg).

const MIX_RATE := 44100.0
# 3D sounds run through RaytracedAudioPlayer3D (raytraced-audio addon): a
# pure-GDScript wrapper over AudioStreamPlayer3D that adds a per-source
# AudioEffectLowPassFilter animated by occlusion raycasts (the "muffled
# behind walls" effect). The plugin auto-creates RaytracedReverb +
# RaytracedAmbient buses on enable; players default to RaytracedReverb.
const NO_POS := Vector3.INF
# Number of distinct sample variations per radius bucket. A random variant is
# picked per explosion call so 10 rockets/sec don't sound like the same sample
# fired 10×. Each variant is lazily synthed + cached on first request.
const EXPLOSION_VARIANTS := 5
# Same idea for gun shots — uzi-rate fire stays varied per pull.
const SHOT_VARIANTS := 5
# m/s — used to delay 3D sound playback by distance/SPEED_OF_SOUND so far
# explosions arrive late, like real physics.
const SPEED_OF_SOUND := 343.0

var _sample_cache: Dictionary = {}
var _hurt_sounds: Array[AudioStreamWAV] = []
var _death_sounds: Array[AudioStreamWAV] = []
var _gun_sounds: Array[AudioStreamWAV] = []
var _step_sounds: Array[AudioStream] = []
var _card_pick_sound: AudioStreamWAV = null

# Tunable mix knobs — adjust live via scenes/audio_lab.tscn.
var shot_self_db: float = -10.0
var shot_world_db: float = 5.0
var shot_dmg_per_double_db: float = 6.0
var shot_pitch_per_double: float = 0.20  # 0..1; pitch drop per damage doubling
var explosion_bang_db: float = 12.0
var explosion_rumble_db: float = 4.0
var footstep_db: float = -30.0
var jump_db: float = -10.5
var landing_max_db: float = 5.0
var hurt_self_db: float = -28.0
var hurt_world_db: float = -20.5
var death_self_db: float = -24.0
var death_world_db: float = -18.5
var hit_received_db: float = -12.0
var bullet_zip_close_db: float = -28.0
var bullet_zip_far_db: float = -50.0
# Subsonic rumble layered under big-damage shots — same piping as the
# explosion bang+rumble pair. Default -12 dB so it sits under the gun bang.
var shot_rumble_db: float = -12.0
# Wet send for shots — a quieter copy of the bang routed through the reverb
# bus so the environmental tail is audible without smearing the dry transient.
var shot_wet_db: float = -10.0
# Same idea for explosion bang + click — adds a wet companion so the sharp
# transient picks up the room reverb (otherwise dry-only bypasses it).
var explosion_wet_db: float = -8.0
# HDR sliding-window mixing. Each sound declares a `priority_db_spl` (real-
# world Sound Pressure Level approximation). SFX tracks the rolling loudest
# active SPL; any new sound below `max_spl - HDR_WINDOW_DB` is CULLED
# entirely instead of being passed to the comp. After max_spl decays back
# toward the floor, the window slides down and quiet sounds return.
const HDR_WINDOW_DB := 35.0           # below max_spl - this many dB → culled
const HDR_RELEASE_DB_PER_SEC := 110.0 # how fast the window slides back down
const HDR_FLOOR_DB := 60.0            # ambient floor — typical room
var hdr_enabled: bool = true
var _hdr_max_spl: float = HDR_FLOOR_DB

# "Big tail" reverb — second, longer-tailed reverb bus that ALL 3D sounds
# send a copy to. The bus's output volume is driven by a dedicated combat-
# intensity tracker that decays SLOWER than _hdr_max_spl, so a one-off
# grenade explosion holds the bus open long enough for the rumble tail to
# actually build. During calm the bus is all-but-muted; during heavy fire
# (or just after a single loud event) the hall is open.
var big_tail_send_db: float = -24.0  # per-source send level into the bus
var big_tail_min_db: float = -50.0   # bus output during silence
var big_tail_max_db: float = -10.0   # bus output at peak intensity (~165 SPL)
# Intensity ramps to 1.0 on a peak event (165+ SPL), decays back to 0 over
# ~3 s. Slow enough that a grenade's tail has time to develop.
const BIG_TAIL_DECAY := 0.33
var _big_tail_intensity: float = 0.0
# AudioStreamPlayer3D unit_size — distance at which the inverse-distance
# attenuation curve starts falling off. Sounds want different values:
# footsteps are intimate (small unit_size), explosions carry far (large).
# The per-call attenuation_dist override lets each public function pick.
var unit_size: float = 12.0
# Audio-lab solo: when non-empty, only sounds whose debug_label starts with
# this string are played. "" = play all. Compared in _play / _play_stream;
# inner forwarded calls have empty label, so the gate ignores them.
var solo_kind: String = ""


func _ready() -> void:
	_ensure_master_chain()
	_load_assets()
	set_process(true)

func _process(delta: float) -> void:
	# Slide the HDR window back down toward the ambient floor at a fixed
	# release rate. New plays push the max back up via _hdr_blocks().
	if _hdr_max_spl > HDR_FLOOR_DB:
		_hdr_max_spl = maxf(HDR_FLOOR_DB, _hdr_max_spl - HDR_RELEASE_DB_PER_SEC * delta)
	# Slow-release big-tail intensity (separate from HDR so single events
	# hold the bus open long enough for a tail to form).
	_big_tail_intensity = maxf(0.0, _big_tail_intensity - BIG_TAIL_DECAY * delta)
	var idx := AudioServer.get_bus_index("BigTailReverb")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, lerpf(big_tail_min_db, big_tail_max_db, _big_tail_intensity))

# HDR gate: returns true if the sound should be CULLED entirely because it
# falls below the sliding window. Otherwise lifts max_spl and lets it play.
# Inner forwarded calls (debug_label == "") skip the gate so the recursion
# from _play() -> _play_stream() doesn't double-count.
func _hdr_blocks(priority_db_spl: float, debug_label: String) -> bool:
	if not hdr_enabled or debug_label == "":
		return false
	if priority_db_spl < _hdr_max_spl - HDR_WINDOW_DB:
		return true
	_hdr_max_spl = maxf(_hdr_max_spl, priority_db_spl)
	return false

func _load_assets() -> void:
	for i in range(1, 15):
		var path := "res://assets/audio/hurt%d.wav" % i
		if ResourceLoader.exists(path):
			_hurt_sounds.append(load(path))
	for i in range(1, 10):
		var path := "res://assets/audio/death%d.wav" % i
		if ResourceLoader.exists(path):
			_death_sounds.append(load(path))
	# Procedural gun synth handles all weapons now — gun1.wav was a single
	# fixed-character sample that didn't differentiate weapon types.

	if ResourceLoader.exists("res://assets/audio/Card Pick.wav"):
		_card_pick_sound = load("res://assets/audio/Card Pick.wav")
	for i in range(1, 14):
		var path := "res://assets/audio/Step-%d.wav" % i
		if ResourceLoader.exists(path):
			_step_sounds.append(load(path))
	print("[SFX] loaded hurt=%d death=%d step=%d gun=%d card=%s" % [
		_hurt_sounds.size(), _death_sounds.size(),
		_step_sounds.size(), _gun_sounds.size(),
		"YES" if _card_pick_sound != null else "NO"])

# Master chain (two stacked compressors + limiter):
#   1. Fast transient comp — instant attack, ~60 ms release. Catches sharp
#      peaks (gun clicks, explosion bangs) and ducks the rest of the mix
#      briefly so each transient PUNCHES through, recovering quickly.
#   2. Slow loudness comp — instant attack, 500 ms release. Handles sustained
#      loudness (stacked rumble) so the comp follows natural decay.
#   3. Brick-wall limiter — absolute peak safety.
func _ensure_master_chain() -> void:
	var master_idx := AudioServer.get_bus_index("Master")
	if master_idx < 0:
		return
	# Idempotent — bail if our chain is already installed.
	for i in AudioServer.get_bus_effect_count(master_idx):
		if AudioServer.get_bus_effect(master_idx, i) is AudioEffectCompressor:
			return
	# HDR sliding-window mixing now handles "loud sound dominates" by culling
	# quiet sounds at spawn time, so the master comps only need gentle peak
	# safety. Both stages are softer than pre-HDR.
	var transient_comp := AudioEffectCompressor.new()
	transient_comp.threshold = -3.0   # only catches truly hot peaks
	transient_comp.ratio = 3.0        # gentle — HDR already removed the hierarchy issues
	transient_comp.attack_us = 1.0    # instant
	transient_comp.release_ms = 80.0
	transient_comp.gain = 0.0
	transient_comp.mix = 1.0
	AudioServer.add_bus_effect(master_idx, transient_comp)
	var comp := AudioEffectCompressor.new()
	comp.threshold = -1.0     # near-ceiling, just to keep stacks under the limiter
	comp.ratio = 2.0          # gentle 2:1
	comp.attack_us = 1.0
	comp.release_ms = 400.0
	comp.gain = 0.0
	comp.mix = 1.0
	AudioServer.add_bus_effect(master_idx, comp)
	# Brick-wall as final safety — only fires if multiple loud sounds stack
	# above the ceiling despite the compressor.
	var lim := AudioEffectLimiter.new()
	lim.ceiling_db = -0.3
	lim.threshold_db = -1.0
	lim.soft_clip_db = 4.0
	AudioServer.add_bus_effect(master_idx, lim)
	_ensure_big_tail_bus()
	_tame_raytraced_reverb()

# The raytraced-audio plugin creates RaytracedReverb with default
# AudioEffectReverb params (predelay_feedback ~0.4, room_size ~0.8) which
# rings like a spring at runtime. We zero the feedback and tighten the room
# size so the bus reverb sounds like a room, not a metal coil.
func _tame_raytraced_reverb() -> void:
	var idx := AudioServer.get_bus_index("RaytracedReverb")
	if idx < 0:
		return
	var count := AudioServer.get_bus_effect_count(idx)
	for i in count:
		var fx := AudioServer.get_bus_effect(idx, i)
		if fx is AudioEffectReverb:
			var r := fx as AudioEffectReverb
			r.predelay_feedback = 0.0  # kill spring-flutter
			r.room_size = 0.55         # small-medium room
			r.damping = 0.55
			r.spread = 0.7
			r.wet = 0.35               # subtle send so dry stays dominant
			break

# Lush, long-tail reverb bus. Only loud sounds get a send (see _play_stream),
# so the room-sized "hall" only swells during combat bursts.
func _ensure_big_tail_bus() -> void:
	if AudioServer.get_bus_index("BigTailReverb") >= 0:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "BigTailReverb")
	AudioServer.set_bus_send(idx, "Master")
	# Bus output volume is driven dynamically in _process from _hdr_max_spl
	# (combat intensity) — see big_tail_min_db / big_tail_max_db.
	var rev := AudioEffectReverb.new()
	# predelay_feedback = 0 kills the "spring reverb" metallic flutter that
	# Godot's reverb gets at high room_size with non-zero feedback.
	rev.predelay_msec = 60.0
	rev.predelay_feedback = 0.0
	rev.room_size = 0.92     # big hall, but pulled back from 0.96 ring
	# damping high → high frequencies decay FAST, lows linger. Mimics how
	# distant boom reverb sounds in real life (air absorbs treble first).
	rev.damping = 0.90
	rev.spread = 0.85
	# hipass at 0 → keep the low end intact, since that's what we want to tail.
	rev.hipass = 0.0
	rev.dry = 0.0            # bus output is wet only
	rev.wet = 0.55           # softer wet so it sums more gracefully under stacks
	AudioServer.add_bus_effect(idx, rev)

func _listener_position() -> Vector3:
	var vp := get_viewport()
	if vp == null:
		return NO_POS
	var cam := vp.get_camera_3d()
	return cam.global_position if cam else NO_POS

# -------------------- dispatch --------------------

func _configure_3d_player(p: AudioStreamPlayer3D) -> void:
	p.unit_size = unit_size
	p.max_db = 24.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	# Distance-based air absorption — distant sounds lose treble, like reality.
	# Cutoff = 8 kHz, max -12 dB at far range; subtle but audible.
	p.attenuation_filter_cutoff_hz = 8000.0
	p.attenuation_filter_db = -12.0
	# The plugin sets `bus` to RaytracedReverb itself on _enter_tree.

func _log_sfx(label: String, vol_db: float, at: Vector3) -> void:
	if label == "":
		return
	if at == NO_POS:
		print("[SFX] %s vol=%+.1fdB (2D)" % [label, vol_db])
		return
	var listener := _listener_position()
	var dist: float = listener.distance_to(at) if listener != NO_POS else -1.0
	print("[SFX] %s vol=%+.1fdB dist=%.1fm" % [label, vol_db, dist])

func _samples_to_wav(samples: PackedVector2Array) -> AudioStreamWAV:
	# Convert in-memory PackedVector2Array → 16-bit stereo WAV so the same
	# AudioStream resource can be fed to a RaytracedAudioPlayer3D's stream.
	var n := samples.size()
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in n:
		var v: Vector2 = samples[i]
		var l: int = int(clampf(v.x, -1.0, 1.0) * 32767.0)
		var r: int = int(clampf(v.y, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 4, l)
		data.encode_s16(i * 4 + 2, r)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = true
	wav.mix_rate = int(MIX_RATE)
	wav.data = data
	return wav

func _play(samples: PackedVector2Array, volume_db: float = -6.0, at: Vector3 = NO_POS, debug_label: String = "", attenuation_dist: float = -1.0, dry: bool = false, priority_db_spl: float = 80.0) -> Node:
	if _solo_blocks(debug_label):
		return null
	if _hdr_blocks(priority_db_spl, debug_label):
		return null
	_log_sfx(debug_label, volume_db, at)
	if samples.is_empty():
		return null
	# Empty label avoids a second log line via _play_stream's own logger.
	# The empty label also skips the HDR gate inside _play_stream — already
	# admitted here, don't double-count.
	return _play_stream(_samples_to_wav(samples), volume_db, at, 1.0, "", attenuation_dist, dry, priority_db_spl)

# Empty `label` is treated as a forwarded inner call (already gated upstream).
func _solo_blocks(label: String) -> bool:
	return solo_kind != "" and label != "" and not label.begins_with(solo_kind)

# `attenuation_dist`: per-call unit_size for 3D sounds. <= 0 means use the
# global SFX.unit_size. Sounds that should "carry" (explosions) pass a much
# larger value than incidentals (footsteps).
# `dry`: if true, plays through plain AudioStreamPlayer3D on Master (no muffle
# filter, no reverb). Use for sharp transients that should hit clean.
# `priority_db_spl`: real-world SPL approximation for HDR gating. See
# _hdr_blocks() — sounds below `max_spl - HDR_WINDOW_DB` are culled.
func _play_stream(stream: AudioStream, volume_db: float = -6.0, at: Vector3 = NO_POS, pitch_scale: float = 1.0, debug_label: String = "", attenuation_dist: float = -1.0, dry: bool = false, priority_db_spl: float = 80.0) -> Node:
	if _solo_blocks(debug_label):
		return null
	if _hdr_blocks(priority_db_spl, debug_label):
		return null
	_log_sfx(debug_label, volume_db, at)
	if stream == null:
		return null
	# All 3D sounds send a copy to the BigTailReverb bus. The bus's output
	# volume is driven by `_big_tail_intensity` in _process — and we lift
	# that intensity HERE (synchronously, before the speed-of-sound delay)
	# so the bus is already open by the time the sound and its tail land.
	if at != NO_POS:
		var contribution: float = clampf((priority_db_spl - HDR_FLOOR_DB) / 100.0, 0.0, 1.0)
		_big_tail_intensity = maxf(_big_tail_intensity, contribution)
	if at == NO_POS:
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = volume_db
		p.pitch_scale = pitch_scale
		add_child(p)
		p.play()
		var life_2d: float = stream.get_length() / maxf(0.1, pitch_scale) + 0.15
		get_tree().create_timer(life_2d).timeout.connect(p.queue_free)
		return p
	# 3D — delay playback by distance/SPEED_OF_SOUND so far sounds arrive late.
	# Listener position is captured at call time; if the listener moves during
	# the delay, attenuation still re-resolves at play time on the live position.
	var listener_pos := _listener_position()
	var delay: float = 0.0
	if listener_pos != NO_POS:
		delay = listener_pos.distance_to(at) / SPEED_OF_SOUND
	if delay < 0.01:
		var p2 := _spawn_3d_player(stream, volume_db, at, pitch_scale, attenuation_dist, dry)
		_spawn_big_tail_send(stream, volume_db + big_tail_send_db, at, pitch_scale)
		return p2
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		_spawn_3d_player(stream, volume_db, at, pitch_scale, attenuation_dist, dry)
		_spawn_big_tail_send(stream, volume_db + big_tail_send_db, at, pitch_scale))
	return null

# Spawns a quieter copy of a stream that plays into the BigTailReverb bus,
# producing the long-tail hall sound for loud events. The player auto-frees
# after the stream finishes; the bus continues to render the reverb tail.
func _spawn_big_tail_send(stream: AudioStream, volume_db: float, at: Vector3, pitch_scale: float) -> void:
	if at == NO_POS:
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = volume_db
		p.pitch_scale = pitch_scale
		p.bus = "BigTailReverb"
		add_child(p)
		p.play()
		var life: float = stream.get_length() / maxf(0.1, pitch_scale) + 0.2
		get_tree().create_timer(life).timeout.connect(p.queue_free)
		return
	var p3 := AudioStreamPlayer3D.new()
	_configure_3d_player(p3)
	p3.bus = "BigTailReverb"
	# Bigger unit_size so the send doesn't fall off rapidly — the tail should
	# carry across the arena even if the dry signal attenuates.
	p3.unit_size = 25.0
	p3.stream = stream
	p3.volume_db = volume_db
	p3.pitch_scale = pitch_scale
	add_child(p3)
	p3.global_position = at
	p3.play()
	var life: float = stream.get_length() / maxf(0.1, pitch_scale) + 0.3
	get_tree().create_timer(life).timeout.connect(p3.queue_free)

func _spawn_3d_player(stream: AudioStream, volume_db: float, at: Vector3, pitch_scale: float, attenuation_dist: float, dry: bool = false) -> Node:
	# Dry path uses plain AudioStreamPlayer3D on Master so it bypasses both
	# the per-source muffle filter AND the RaytracedReverb bus.
	var p: AudioStreamPlayer3D = AudioStreamPlayer3D.new() if dry else RaytracedAudioPlayer3D.new()
	_configure_3d_player(p)
	if dry:
		p.bus = "Master"
	if attenuation_dist > 0.0:
		p.unit_size = attenuation_dist
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = pitch_scale
	add_child(p)
	p.global_position = at
	p.play()
	# +1.5 s buffer so the shared reverb bus's tail can play out before the
	# player is freed (and its bus removed, which would silence in-flight tail).
	var life: float = stream.get_length() / maxf(0.1, pitch_scale) + 1.5
	get_tree().create_timer(life).timeout.connect(p.queue_free)
	return p

func _cached_samples(key: String, generator: Callable) -> PackedVector2Array:
	if not _sample_cache.has(key):
		_sample_cache[key] = generator.call()
	return _sample_cache[key]

func _shot_cache_key(w: Weapon, variant: int) -> String:
	if w == null:
		return "shot:default:%d" % variant
	var damage_bucket := int(round(w.get_damage() / 5.0))
	var spread_bucket := int(round(w.spread * 1000.0))
	var fire_bucket := int(round(w.fire_rate_mult * 10.0))
	return "shot:%d:%d:%d:%d" % [damage_bucket, spread_bucket, fire_bucket, variant]

func _hitmarker_cache_key(kind: String, dmg: int) -> String:
	var dmg_bucket := 0
	if dmg > 0:
		dmg_bucket = int(round(clampf(float(dmg) / Weapon.BASE_DAMAGE, 0.5, 5.0) * 4.0))
	return "hitmarker:%s:%d" % [kind, dmg_bucket]

# -------------------- sounds --------------------

func shot(w: Weapon = null, at: Vector3 = NO_POS, is_self: bool = false) -> void:
	# Use a random real-gun sample when available; fall back to the synth.
	# Higher-damage weapons pitch down (heavier report) AND get louder.
	# Self-shots play 2D at their own volume so the local BANG can be tuned
	# independently of distance attenuation / world reverb.
	var dmg_db: float = 0.0
	if w != null:
		var dmg_ratio: float = maxf(0.5, w.get_damage() / Weapon.BASE_DAMAGE)
		dmg_db = clampf(log(dmg_ratio) / log(2.0) * shot_dmg_per_double_db, -4.0, 14.0)
	var pitch := 1.0
	if w != null:
		var dmg_ratio_p: float = maxf(1.0, w.get_damage() / Weapon.BASE_DAMAGE)
		pitch = clampf(1.0 - (log(dmg_ratio_p) / log(2.0)) * shot_pitch_per_double, 0.35, 1.15)
		pitch *= randf_range(0.97, 1.03)
	# Self vs world base levels (knobs let the audio lab tune them live).
	var self_base: float = shot_self_db + randf_range(-1.5, 1.5)
	var world_base: float = shot_world_db + randf_range(-1.5, 1.5)
	# unit_size for shots — past this, treble rolls off and volume drops with
	# inverse-distance. 6 m gives noticeable close/mid/far distinction in a
	# typical arena while still carrying audibly to the far walls.
	var shot_dist: float = 6.0
	# Self shots play 3D at the muzzle (1 m from listener -> within unit_size,
	# full volume) so they route through RaytracedReverb and pick up the
	# environment tail. Pure 2D self-shots sounded thin / dry.
	var shot_variant: int = randi() % SHOT_VARIANTS
	# Two spawns: dry primary on Master (preserves the sharp transient) +
	# quieter wet copy through RaytracedReverb (adds environmental tail).
	# `shot_wet_db` is the offset from the dry level for the wet copy.
	var dry_vol: float = (self_base if is_self else world_base) + dmg_db
	var wet_vol: float = dry_vol + shot_wet_db
	var label := "shot_self" if is_self else "shot"
	# Real-world rifle SPL is ~150-165 dB at the muzzle. Scale with damage so
	# bigger guns push the HDR window higher, ducking weaker sounds harder.
	var dmg_log: float = 0.0 if w == null else log(maxf(1.0, w.get_damage() / Weapon.BASE_DAMAGE)) / log(2.0)
	var spl: float = 148.0 + dmg_log * 6.0
	if not _gun_sounds.is_empty():
		var stream: AudioStream = _gun_sounds.pick_random()
		_play_stream(stream, dry_vol, at, pitch, label, shot_dist, true, spl)
		_play_stream(stream, wet_vol, at, pitch, "", shot_dist, false, spl)
	else:
		var key := _shot_cache_key(w, shot_variant)
		var samples := _cached_samples(key, Callable(self, "_synth_shot").bind(w, shot_variant))
		_play(samples, dry_vol, at, label, shot_dist, true, spl)
		_play(samples, wet_vol, at, "", shot_dist, false, spl)
	# Rumble layer — only for hard-hitting weapons (>1.4× base damage). Reuses
	# the explosion rumble synth + cache (same brown-noise body) but at a much
	# lower dB so it sits under the bang. Snipers, bazookas, etc. get a real
	# subsonic punch; default rifles stay clean.
	if w != null:
		var dmg_ratio_r: float = w.get_damage() / Weapon.BASE_DAMAGE
		if dmg_ratio_r > 1.4:
			var rumble_radius: int = int(round(clampf(dmg_ratio_r * 1.5, 2.0, 12.0)))
			var rumble_variant: int = randi() % EXPLOSION_VARIANTS
			var rumble_key := "explosion_rumble:%d:%d" % [rumble_radius, rumble_variant]
			var rumble_dist: float = clampf(float(rumble_radius) * 0.8, 4.0, 12.0)
			_play(_cached_samples(rumble_key, Callable(self, "_synth_explosion_rumble").bind(float(rumble_radius), rumble_variant)),
				shot_rumble_db, at, "shot_rumble", rumble_dist, false, spl)
func grenade_launch(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("grenade_launch", Callable(self, "_synth_grenade_launch")), -6.0, at, "grenade_launch", -1.0, false, 110.0)

# Brief metallic click — bolt cycling / next round chambering between shots.
# dry=true so the click stays crisp instead of washing through reverb.
func next_round(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("next_round", Callable(self, "_synth_next_round")), -16.0, at, "next_round", 5.0, true, 65.0)

# Tiny dry click — "nothing happens" when trigger pulled but gun isn't ready.
func empty_chamber(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("empty_chamber", Callable(self, "_synth_empty_chamber")), -10.0, at, "empty_chamber", 5.0, true, 55.0)

# Zip-by sound for a bullet passing the listener. Synthesised fresh each
# time so per-call jitter (pitch wobble, doppler sweep) varies naturally;
# the synth itself is cheap (≤4k samples, mono) and fires at most once per
# bullet. Out-of-range bullets bail before any allocation.
func bullet_zip(speed: float, scale: float, at: Vector3) -> void:
	var listener := _listener_position()
	if listener == NO_POS:
		return
	var dist_sq: float = listener.distance_squared_to(at)
	# Quick reject: anything beyond ~6 m wouldn't be heard as a near-miss.
	if dist_sq > 36.0:
		return
	var speed_factor: float = clampf(speed / 165.0, 0.2, 5.0)
	var scale_factor: float = clampf(scale, 0.5, 4.0)
	# Range-driven volume: close pass = audible whip; just inside the bubble
	# = barely there. Stay well below gunshot level.
	var dist: float = sqrt(dist_sq)
	var prox: float = clampf(1.0 - dist / 6.0, 0.0, 1.0)  # 1 at 0 m, 0 at 6 m
	var vol_db: float = lerpf(bullet_zip_far_db, bullet_zip_close_db, prox)
	var samples := _synth_bullet_zip(speed_factor, scale_factor)
	# Bullet zips are deliberately low priority — should be culled when a
	# gunshot (148+ SPL) fires within HDR_WINDOW_DB. Real near-miss zips
	# read ~95 dB.
	_play(samples, vol_db, at, "bullet_zip", -1.0, false, 95.0)
func explosion(at: Vector3 = NO_POS, radius: float = 6.0) -> void:
	# Layered: punchy transient bang + a deep brown-noise rumble that
	# decays longer for larger blasts. The rumble samples are bucketed
	# by radius so we don't synth a fresh one per call.
	# unit_size is the distance at which attenuation BEGINS — anything closer
	# plays at full volume_db. So we want it relatively small (a grenade at
	# 5 m and 30 m should sound very different) but scaled with radius so a
	# bazooka still carries far before falling off.
	# Bang and rumble use DIFFERENT unit_sizes so the body of the explosion
	# carries far further than the transient. Bang at radius*0.8 attenuates
	# normally with distance (sharp at close range, dimmer far away). Rumble
	# at radius*2.5 stays bass-heavy at distance — that's what gives a
	# bazooka 30 m out its weight instead of sounding "thin".
	var bang_dist: float = clampf(radius * 0.8, 4.0, 24.0)
	var rumble_dist: float = clampf(radius * 2.5, 12.0, 60.0)
	var r_bucket: int = int(round(clampf(radius, 2.0, 24.0)))
	var variant: int = randi() % EXPLOSION_VARIANTS
	var bang_key := "explosion_bang:%d:%d" % [r_bucket, variant]
	# Real explosion SPL is 165-180 dB at the source — scales with radius so
	# bigger blasts push the HDR window highest, ducking everything else
	# hardest.
	var ex_spl: float = 165.0 + log(maxf(1.0, radius / 6.0)) / log(2.0) * 5.0
	# Bang plays dry primary (crisp transient) PLUS a wet companion through
	# RaytracedReverb — same pattern as gun shots. The wet companion is what
	# gives a sharp transient an audible reverb tail; without it the dry
	# bang bypasses the reverb bus entirely and the explosion sounds tail-less.
	var bang_samples := _cached_samples(bang_key, Callable(self, "_synth_explosion").bind(float(r_bucket), variant))
	_play(bang_samples, explosion_bang_db, at, "explosion_bang", bang_dist, true, ex_spl)
	_play(bang_samples, explosion_bang_db + explosion_wet_db, at, "", bang_dist, false, ex_spl)
	var rumble_key := "explosion_rumble:%d:%d" % [r_bucket, variant]
	_play(_cached_samples(rumble_key, Callable(self, "_synth_explosion_rumble").bind(float(r_bucket), variant)), explosion_rumble_db, at, "explosion_rumble", rumble_dist, false, ex_spl)
	# Distance-bucketed bandpass click. Picks one of 5 frequency buckets based
	# on listener distance — close pops bright, far pops bass — modelling the
	# air-absorption shift in perceived peak frequency.
	var listener := _listener_position()
	if listener != NO_POS:
		var listener_dist: float = listener.distance_to(at)
		# Buckets: 0..5m=0, 5..15m=1, 15..30m=2, 30..60m=3, 60+m=4.
		var click_bucket: int = 0
		if listener_dist > 60.0: click_bucket = 4
		elif listener_dist > 30.0: click_bucket = 3
		elif listener_dist > 15.0: click_bucket = 2
		elif listener_dist > 5.0: click_bucket = 1
		var click_variant: int = randi() % EXPLOSION_VARIANTS
		var click_key := "ex_click:%d:%d" % [click_bucket, click_variant]
		var click_samples := _cached_samples(click_key, Callable(self, "_synth_distance_click").bind(click_bucket, click_variant))
		_play(click_samples, explosion_bang_db - 4.0, at, "explosion_click", bang_dist, true, ex_spl)
		_play(click_samples, explosion_bang_db - 4.0 + explosion_wet_db, at, "", bang_dist, false, ex_spl)
func melee(at: Vector3 = NO_POS, damage: int = 50) -> void:
	var pitch_ratio: float = clampf(50.0 / float(damage), 0.5, 1.2)
	var key := "melee_%d" % int(round(pitch_ratio * 100.0))
	_play(_cached_samples(key, Callable(self, "_synth_melee").bind(pitch_ratio)), -6.0, at, "melee", -1.0, false, 90.0)
func jump(at: Vector3 = NO_POS) -> void:
	# Jump = a thick "oof" built from two step samples layered an octave apart.
	# Significantly louder than a footstep (~20 dB over) so the takeoff reads.
	if _step_sounds.is_empty():
		return
	_play_stream(_step_sounds.pick_random(), jump_db + randf_range(-1.5, 1.5), at, randf_range(1.02, 1.12), "jump", -1.0, false, 75.0)
	_play_stream(_step_sounds.pick_random(), jump_db - 3.0 + randf_range(-1.5, 1.5), at, randf_range(0.55, 0.65), "jump_low", -1.0, false, 75.0)
func landing(impact_vel: float, at: Vector3 = NO_POS) -> void:
	# Landing thump: scaled by impact velocity. Tiny drops (<~2 m/s, e.g. a
	# 5 cm step-off) are silent; jump-land is moderate; big falls slam.
	if _step_sounds.is_empty():
		return
	if impact_vel < 2.0:
		return
	var t: float = clampf((impact_vel - 2.0) / 23.0, 0.0, 1.0)
	var vol: float = lerpf(-22.0, landing_max_db, t)
	var pitch: float = lerpf(1.05, 0.55, t)
	# SPL 75 (light land) → 95 (slam) so big drops carry through other sounds.
	var spl: float = lerpf(75.0, 95.0, t)
	_play_stream(_step_sounds.pick_random(), vol, at, pitch, "landing", -1.0, false, spl)
	# Sub-octave layer for extra thud on hard landings only.
	if t > 0.25:
		_play_stream(_step_sounds.pick_random(), vol - 4.0, at, pitch * 0.5, "landing_low", -1.0, false, spl)
func footstep(at: Vector3 = NO_POS, size: float = 1.0) -> void:
	# `size` is the player's effective body size (1.0 = default). Bigger
	# bodies thump deeper and louder; smaller ones tap softer and higher.
	if _step_sounds.is_empty():
		return
	var s: float = clampf(size, 0.4, 3.0)
	# log2(size) shifts symmetrically: 2× size → −6 dB pitch + same dB louder.
	var size_db: float = clampf(log(s) / log(2.0) * 6.0, -6.0, 10.0)
	# Pitch: 1.0 at size 1, ~0.5 at size 2, ~1.4 at size 0.5.
	var size_pitch: float = clampf(1.0 / sqrt(s), 0.5, 1.6)
	# Footsteps deliberately low priority — they should disappear during
	# combat (gunshots / explosions) and re-emerge in calm moments.
	_play_stream(
		_step_sounds.pick_random(),
		footstep_db + randf_range(-2.0, 2.0) + size_db,
		at,
		size_pitch * randf_range(0.92, 1.08),
		"footstep",
		-1.0,
		false,
		70.0,
	)
func dash(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("dash", Callable(self, "_synth_dash")), -24.0, at, "dash", -1.0, false, 75.0)
func hurt(at: Vector3 = NO_POS, is_self: bool = false) -> void:
	if _hurt_sounds.is_empty(): return
	if is_self:
		_play_stream(_hurt_sounds.pick_random(), hurt_self_db, NO_POS, 1.0, "hurt_self", -1.0, false, 100.0)
	else:
		_play_stream(_hurt_sounds.pick_random(), hurt_world_db + randf_range(-1.5, 1.5), at, 1.0, "hurt", -1.0, false, 80.0)
func death(at: Vector3 = NO_POS, is_self: bool = false) -> void:
	if _death_sounds.is_empty(): return
	if is_self:
		_play_stream(_death_sounds.pick_random(), death_self_db, NO_POS, 1.0, "death_self", -1.0, false, 110.0)
	else:
		_play_stream(_death_sounds.pick_random(), death_world_db + randf_range(-1.5, 1.5), at, 1.0, "death", -1.0, false, 85.0)
func hit_received() -> void:
	# Critical UI feedback — high SPL so it always plays through combat noise.
	_play(_cached_samples("hit_received", Callable(self, "_synth_hit_received")), hit_received_db, NO_POS, "hit_received", -1.0, false, 130.0)
func kill_confirm() -> void:
	# Critical UI feedback — same priority tier as hit_received.
	_play(_cached_samples("kill_confirm", Callable(self, "_synth_kill_confirm")), -6.0, NO_POS, "kill_confirm", -1.0, false, 130.0)
func pling(pitch_ratio: float = 1.0) -> void:
	var key := "pling_%d" % int(round(pitch_ratio * 100.0))
	_play(_cached_samples(key, Callable(self, "_synth_pling").bind(pitch_ratio)), -10.0, NO_POS, "pling", -1.0, false, 70.0)
func card_flip(pitch_ratio: float = 1.0) -> void:
	if _card_pick_sound:
		_play_stream(_card_pick_sound, -4.0, NO_POS, pitch_ratio, "card_flip", -1.0, false, 60.0)
		return
	var key := "card_flip_%d" % int(round(pitch_ratio * 100.0))
	_play(_cached_samples(key, Callable(self, "_synth_card_flip").bind(pitch_ratio)), -6.0, NO_POS, "card_flip", -1.0, false, 60.0)
func reload(duration: float, at: Vector3 = NO_POS) -> Node:
	# Continuous rattle for the full reload duration. Returns the player node
	# so the caller can stop it early (e.g. on respawn / round end).
	return _play(_synth_reload(duration), -14.0, at, "reload", -1.0, false, 70.0)

func hitmarker(kind: String = "body", dmg: int = 0) -> void:
	# Scale pitch down and volume up with damage — heavy guns land with a
	# bassy thunk, baseline pistol keeps the sharp "tink".
	var dmg_ratio: float = 1.0
	if dmg > 0:
		dmg_ratio = clampf(float(dmg) / Weapon.BASE_DAMAGE, 0.5, 5.0)
	var vol_bonus: float = clampf(log(dmg_ratio) / log(2.0) * 2.0, 0.0, 4.0)
	# Critical UI feedback — high SPL so the hitmarker always plays through
	# combat noise (you need to know you landed a hit even mid-explosion).
	_play(_cached_samples(_hitmarker_cache_key(kind, dmg), Callable(self, "_synth_hitmarker").bind(kind, dmg_ratio)), -5.0 + vol_bonus, NO_POS, "hitmarker_" + kind, -1.0, false, 130.0)

# -------------------- synthesis --------------------

func _synth_shot(w: Weapon, variant: int) -> PackedVector2Array:
	# Layered like the explosion bang: thwack (broadband impulse, the muzzle
	# blast attack) + bass thump + lowpass-swept noise tail + brief crack
	# (lowpass-filtered noise impulse) for accurate rifles. Per-variant RNG
	# seeding gives 5 distinct samples per weapon config — caches share
	# (damage, spread, fire) bucket but variant differentiates them.
	var dmg_ratio := 1.0
	var accuracy := 1.0  # 1.0 = perfectly accurate, 0.0 = fully sprayed
	if w:
		dmg_ratio = maxf(1.0, w.get_damage() / Weapon.BASE_DAMAGE)
		accuracy = clampf(1.0 - w.spread / 0.06, 0.0, 1.0)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([dmg_ratio, accuracy, variant, "shot"])

	# Per-variant param jitter (deterministic per variant for stable cache).
	var bright_jit: float = lerpf(0.85, 1.15, rng.randf())
	var click_freq_jit: float = lerpf(0.80, 1.25, rng.randf())
	var thwack_decay: float = lerpf(180.0, 280.0, rng.randf())
	var thwack_drive: float = lerpf(4.0, 8.0, rng.randf())
	var dur_jit: float = lerpf(0.90, 1.12, rng.randf())
	# Kick-drum bass: sine with rapid pitch sweep from f0 (click pitch) down
	# to f1 (body pitch) over ~12 ms. f1 scales with damage so big guns thump
	# lower. f0 stays in the click range regardless. Lowpassed to smooth the
	# sweep into a punchy "boom" instead of a chirp.
	var kick_f0: float = 220.0 * lerpf(0.88, 1.12, rng.randf())
	var kick_f1: float = clampf(55.0 / sqrt(dmg_ratio), 28.0, 80.0) * lerpf(0.92, 1.10, rng.randf())
	var kick_sweep_rate: float = lerpf(70.0, 95.0, rng.randf())
	var kick_decay: float = clampf(35.0 / sqrt(dmg_ratio), 10.0, 40.0)
	var kick_gain: float = lerpf(0.55, 0.95, clampf((dmg_ratio - 1.0) / 3.0, 0.0, 1.0))

	var dur: float = clampf((0.08 + 0.08 * log(dmg_ratio) / log(2.0)) * dur_jit, 0.08, 0.35)
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)

	var noise_brightness: float = clampf(lerpf(0.18, 0.55, accuracy) * bright_jit, 0.05, 0.95)
	var click_gain := accuracy * 0.3
	var click_freq := 2400.0 * click_freq_jit

	var lp := 0.0
	var thwack_low_acc := 0.0
	var kick_phase: float = 0.0
	var kick_lp: float = 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(clampf(1.0 - t / dur, 0.0, 1.0), 1.6)
		var noise := rng.randf_range(-1.0, 1.0)
		# WIDE distorted transient — broadband impulse, sub-bass roll-off,
		# tanh-saturated for harmonic crack character.
		var raw_thwack := rng.randf_range(-1.0, 1.0)
		thwack_low_acc = lerpf(thwack_low_acc, raw_thwack, 0.06)
		var hp := raw_thwack - thwack_low_acc
		var thwack := tanh(hp * thwack_drive) * 1.5 * exp(-t * thwack_decay)
		# Kick: phase-accumulated swept sine. Phase integration handles the
		# time-varying frequency correctly (a plain sin(2πft) would mis-track
		# the sweep).
		var kick_freq: float = kick_f1 + (kick_f0 - kick_f1) * exp(-t * kick_sweep_rate)
		kick_phase += 2.0 * PI * kick_freq / float(MIX_RATE)
		var kick_raw: float = sin(kick_phase)
		# Lowpass smooths the sweep edges so it reads as a thump, not a chirp.
		kick_lp = lerpf(kick_lp, kick_raw, 0.30)
		var kick: float = kick_lp * exp(-t * kick_decay)
		# Lowpass-swept noise tail.
		lp = lerpf(lp, noise, noise_brightness)
		var click := sin(2.0 * PI * click_freq * t) * exp(-t * 280.0) * click_gain
		var s := tanh((thwack + lp * 0.5 + kick * kick_gain + click) * env * 1.4)
		out[i] = Vector2(s, s)
	return out

func _synth_grenade_launch() -> PackedVector2Array:
	# "Thwip": downward pitch sweep with a little grit.
	var dur := 0.13
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(1.0 - t / dur, 1.5)
		var pitch := lerpf(420.0, 120.0, t / dur)
		var tone := sin(2.0 * PI * pitch * t)
		var noise := randf_range(-1.0, 1.0)
		lp = lerpf(lp, noise, 0.2)
		var s := (tone * 0.6 + lp * 0.25) * env * 0.5
		out[i] = Vector2(s, s)
	return out

func _synth_next_round() -> PackedVector2Array:
	# Real bolt cycling = two broadband metallic clicks ~20 ms apart:
	# (1) bolt unlocks + retracts, (2) bolt returns to battery / locks.
	# Both are pure noise bandpass-filtered to the 2-6 kHz "metal" range —
	# real impacts are inharmonic so any sine content reads as "bell".
	var dur := 0.07
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp_low := 0.0   # accumulator for highpass (subtract slow LP from input)
	var lp_high := 0.0  # accumulator for the bandpass lowpass stage
	var t_back := 0.0
	var t_fwd := 0.022  # second click 22 ms after the first
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env_back: float = exp(-(t - t_back) * 260.0) if t >= t_back else 0.0
		var env_fwd: float = exp(-(t - t_fwd) * 200.0) * 0.75 if t >= t_fwd else 0.0
		var noise: float = randf_range(-1.0, 1.0)
		var burst: float = noise * (env_back + env_fwd)
		# Bandpass via cascaded 1-pole filters:
		#   lp_low ≈ ~280 Hz LP -> subtract from burst -> highpass result
		#   lp_high ≈ ~3.4 kHz LP applied to the highpassed signal
		lp_low = lerpf(lp_low, burst, 0.04)
		var hp: float = burst - lp_low
		lp_high = lerpf(lp_high, hp, 0.48)
		var s: float = lp_high * 0.85
		out[i] = Vector2(s, s)
	return out

func _synth_empty_chamber() -> PackedVector2Array:
	# Single short bandpass noise burst — the firing pin clicking on an empty
	# chamber. No second cycle (nothing was chambered), no ring.
	var dur := 0.025
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp_low := 0.0
	var lp_high := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 280.0)
		var burst := randf_range(-1.0, 1.0) * env
		lp_low = lerpf(lp_low, burst, 0.04)
		var hp := burst - lp_low
		lp_high = lerpf(lp_high, hp, 0.42)
		var s: float = lp_high * 0.9
		out[i] = Vector2(s, s)
	return out

func _synth_explosion(radius: float, variant: int) -> PackedVector2Array:
	# Same layered architecture as `_synth_shot` (thick, saturated, percussive)
	# but scaled to explosion proportions: longer duration, lower kick body,
	# slower envelope. Layers: thwack + LP-swept noise tail + kick drum +
	# lowpassed sub-noise rumble; final tanh wrap drives everything into
	# global saturation.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([radius, variant, "bang"])

	# Per-variant param jitter.
	var bright_jit: float = lerpf(0.85, 1.15, rng.randf())
	var thwack_decay: float = lerpf(180.0, 280.0, rng.randf())
	var thwack_drive: float = lerpf(4.0, 8.0, rng.randf())
	var dur_jit: float = lerpf(0.92, 1.10, rng.randf())

	# Kick drum parameters — same shape as gun's kick but f1 clamped higher
	# (50 Hz min) so big blasts thump in the audible range, not sub-plonk.
	# Body decays in 30-50 ms — pure attack, no sustain.
	var r_norm: float = clampf(radius / 6.0, 0.3, 4.0)
	var kick_f0: float = 220.0 * lerpf(0.85, 1.15, rng.randf())
	var kick_f1: float = clampf(60.0 / sqrt(r_norm), 50.0, 95.0) * lerpf(0.92, 1.10, rng.randf())
	var kick_sweep_rate: float = lerpf(70.0, 95.0, rng.randf())
	var kick_decay: float = clampf(40.0 / sqrt(r_norm), 18.0, 45.0)
	var kick_gain: float = lerpf(0.7, 1.05, clampf((r_norm - 1.0) / 3.0, 0.0, 1.0))

	# Sub-bass rumble: heavily lowpassed noise (~35-65 Hz) for inharmonic
	# body. Bigger blasts get lower cutoffs and slower decay → fatter rumble.
	var sub_cutoff_k: float = lerpf(0.005, 0.010, rng.randf())
	var sub_decay: float = clampf(3.5 / sqrt(r_norm), 1.2, 4.0)

	# Duration scales with radius — bigger = longer body.
	var dur: float = clampf((0.4 + radius * 0.08) * dur_jit, 0.4, 1.6)
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)

	var thwack_cutoff_k: float = lerpf(0.10, 0.16, rng.randf())
	var noise_brightness: float = clampf(0.45 * bright_jit, 0.05, 0.95)
	# Noise-tail decay 8-15 → ~70-125 ms. Without this the LP-swept noise
	# rides the full envelope (up to 1.6 s) and reads as a long hiss sweep.
	var noise_decay: float = lerpf(8.0, 15.0, rng.randf())

	var lp := 0.0
	var thwack_lp := 0.0
	var sub_lp := 0.0
	var kick_phase: float = 0.0
	var kick_lp: float = 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		# Slower decay than gun (gun = pow(1-t/dur, 1.6) only). Explosion adds
		# an exp tail on top so the body sustains longer before the convex
		# fadeout takes over.
		var env := exp(-t * 1.4) * pow(1.0 - t / dur, 0.6)
		var noise := rng.randf_range(-1.0, 1.0)
		# WIDE distorted transient — broadband impulse, sub-bass roll-off,
		# tanh-saturated for harmonic crack.
		var raw_thwack := rng.randf_range(-1.0, 1.0)
		thwack_lp = lerpf(thwack_lp, raw_thwack, thwack_cutoff_k)
		var thwack := tanh(thwack_lp * thwack_drive) * 1.5 * exp(-t * thwack_decay)
		# Lowpass-swept noise tail with its own fast envelope so it dies
		# in ~80-125 ms instead of riding the full bang.
		lp = lerpf(lp, noise, noise_brightness)
		var lp_env: float = exp(-t * noise_decay)
		# Kick: phase-accumulated swept sine, lowpassed.
		var kick_freq: float = kick_f1 + (kick_f0 - kick_f1) * exp(-t * kick_sweep_rate)
		kick_phase += 2.0 * PI * kick_freq / float(MIX_RATE)
		kick_lp = lerpf(kick_lp, sin(kick_phase), 0.30)
		var kick: float = kick_lp * exp(-t * kick_decay)
		# Sub-bass rumble (inharmonic, fills out the body after the kick dies).
		sub_lp = lerpf(sub_lp, rng.randf_range(-1.0, 1.0), sub_cutoff_k)
		var sub: float = sub_lp * 3.5 * exp(-t * sub_decay)
		# Final mix wrapped in tanh — same trick as shot. Drives the layered
		# sum into saturation for a thick, dense character.
		var s := tanh((thwack + lp * 0.5 * lp_env + kick * kick_gain + sub * 0.7) * env * 1.4)
		out[i] = Vector2(s, s)
	return out

# Distance-driven high-Q bandpass click. Real air absorption shifts an
# explosion's perceived peak frequency downward as you move away — close = a
# sharp 3 kHz crack, far = a low 200 Hz thud. Quantised into 5 buckets so
# we cache one synth per (bucket, variant) pair instead of synthesising
# fresh per call.
const EX_CLICK_FREQS: Array = [3200.0, 1500.0, 700.0, 350.0, 220.0]

func _synth_distance_click(bucket: int, variant: int) -> PackedVector2Array:
	var b: int = clampi(bucket, 0, 4)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([b, variant, "ex_click"])
	var freq: float = EX_CLICK_FREQS[b] * lerpf(0.85, 1.15, rng.randf())
	# State-variable filter (Chamberlin) coefficients. Lower q_factor = higher
	# Q, sharper ring. 0.06 is very sharp.
	var f_coef: float = 2.0 * sin(PI * freq / float(MIX_RATE))
	var q_factor: float = 0.06
	var dur: float = 0.045
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp_s: float = 0.0
	var bp_s: float = 0.0
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		# Sharper noise impulse (~2 ms) excites the resonator harder.
		var noise: float = rng.randf_range(-1.0, 1.0) * exp(-t * 480.0)
		var hp: float = noise - lp_s - q_factor * bp_s
		bp_s += f_coef * hp
		lp_s += f_coef * bp_s
		# Heavy tanh saturation (drive 14 vs 6) — much more harmonic content,
		# distorted "pop" / "rip" character instead of a smooth ring. Output
		# gain bumped to 1.1 (was 0.7) for more presence.
		var s: float = tanh(bp_s * 14.0) * 1.1 * exp(-t * 80.0)
		out[i] = Vector2(s, s)
	return out

# Deep rumble layer that pairs with the transient explosion bang. Brown-noise
# generated by integrating white noise, then aggressively low-passed. Bigger
# radius → longer duration AND lower-frequency rumble.
func _synth_explosion_rumble(radius: float, variant: int) -> PackedVector2Array:
	# Quadratic length scaling: tiny pops stay tiny, big bazookas get the
	# full multi-second roar. Per-variant jitter on cutoff, attack, and
	# decay rate so 5 stacked rumbles aren't identical.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([radius, variant, "rumble"])
	var r_norm: float = clampf(radius, 2.0, 24.0) / 24.0
	var dur: float = clampf(0.3 + r_norm * r_norm * 4.7, 0.3, 5.0)
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	# Bigger blast = lower cutoff = deeper rumble. Per-variant ±15 Hz wobble.
	var cutoff_base: float = clampf(220.0 - radius * 7.0, 55.0, 200.0)
	var cutoff: float = cutoff_base + rng.randf_range(-15.0, 15.0)
	var lp_k: float = clampf(TAU * cutoff / MIX_RATE, 0.005, 0.4)
	var brown: float = 0.0
	var lp: float = 0.0
	# Variant jitter: attack and decay rate vary subtly per variant.
	var attack_dur: float = lerpf(0.05, 0.12, rng.randf())
	var decay_rate: float = lerpf(1.5, 2.2, rng.randf())
	# Last 0.4 s linearly tapers the envelope to literal zero so the buffer
	# doesn't end on a non-zero sample (which would click).
	var release_dur: float = 0.4
	# Per-sample gain. Bazooka-class blasts (large radius) have a longer +
	# deeper rumble whose total acoustic energy would otherwise drown the
	# bang. sqrt(6/radius) keeps small blasts at full level (radius=6 -> 1.5)
	# and trims big ones (radius=24 -> ~0.75).
	var gain: float = 1.5 * sqrt(6.0 / maxf(6.0, radius))
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var attack: float = clampf(t / attack_dur, 0.0, 1.0)
		# Slower decay than 3.0/dur so the body of each rumble persists
		# longer; stacked rumbles overlap into a sustained roar.
		var decay: float = exp(-t * (decay_rate / dur))
		var release: float = clampf((dur - t) / release_dur, 0.0, 1.0)
		var env: float = attack * decay * release
		# Brown noise: integrated white noise with a tiny leak so it can't
		# drift into DC offset territory.
		brown = brown * 0.998 + rng.randf_range(-1.0, 1.0) * 0.03
		lp = lerpf(lp, brown, lp_k)
		var s: float = lp * env * gain
		# Soft-clip stray peaks so the integrator can't blow up the buffer.
		s = tanh(s)
		out[i] = Vector2(s, s)
	return out

func _synth_hit_received() -> PackedVector2Array:
	# Low thud: pitch drops from 160 → 70 Hz over the first 80 ms.
	var dur := 0.18
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(1.0 - t / dur, 2.0)
		var pitch := lerpf(160.0, 70.0, clampf(t / 0.08, 0.0, 1.0))
		var tone := sin(2.0 * PI * pitch * t)
		var noise := randf_range(-1.0, 1.0) * exp(-t * 80.0)
		var s := (tone * 0.8 + noise * 0.4) * env * 0.75
		out[i] = Vector2(s, s)
	return out

func _synth_kill_confirm() -> PackedVector2Array:
	# G4 + D5 perfect fifth, bell-like exponential decay.
	var dur := 0.28
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 9.0)
		var tone := sin(2.0 * PI * 392.0 * t) * 0.45 + sin(2.0 * PI * 587.0 * t) * 0.3
		var s := tone * env * 0.5
		out[i] = Vector2(s, s)
	return out

func _synth_melee(pitch_ratio: float = 1.0) -> PackedVector2Array:
	# Hump-enveloped lowpass-swept noise — a short swoosh.
	var dur := 0.20
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := sin(PI * clampf(t / dur, 0.0, 1.0))
		var noise := randf_range(-1.0, 1.0)
		var cutoff_k := lerpf(0.7, 0.18, t / dur) * pitch_ratio
		lp = lerpf(lp, noise, clampf(cutoff_k, 0.01, 0.99))
		var s := lp * env * 0.45
		out[i] = Vector2(s, s)
	return out

func _synth_reload(duration: float) -> PackedVector2Array:
	# Two clusters of metallic clicks with silence between: mag-out clatter
	# at the start, then the magazine is in the air, then the mag slams home
	# + slide racks at the end. Each click = short bandpass-filtered noise
	# burst at a slightly randomized high pitch.
	var n := int(duration * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		out[i] = Vector2.ZERO

	# Cluster boundaries as fractions of duration.
	var c1_start := 0.00
	var c1_end := 0.12 # Faster start
	var c2_start := 0.88 # Later end
	var c2_end := 0.98
	# Mag-out: starts HIGH (release catch / latch) then trails lower as the
	# mag drops down the well. Mag-in is the mirror: starts lower (mag seats)
	# and climbs to HIGH (slide racking at the top of the receiver).
	_reload_cluster(out, duration * c1_start, duration * c1_end, 2.2, 0.4)
	_reload_cluster(out, duration * c2_start, duration * c2_end, 0.4, 2.0)

	# Soft-clip the whole buffer to avoid overlapping-tap clipping.
	for i in n:
		var s: Vector2 = out[i]
		out[i] = Vector2(tanh(s.x), tanh(s.y))
	return out

func _reload_cluster(out: PackedVector2Array, t_start: float, t_end: float, pitch_begin: float, pitch_end: float) -> void:
	# Each cluster progresses from pitch_begin to pitch_end — the iron tapping
	# its way up or down the weapon. A little jitter per tap keeps it organic.
	var span := maxf(t_end - t_start, 0.02)
	var num_taps := randi_range(6, 10) # More taps
	for tap_i in num_taps:
		# Staggered with jitter so clicks don't land on a metronome.
		var frac := (float(tap_i) + randf_range(-0.15, 0.15)) / float(num_taps)
		frac = clampf(frac, 0.0, 1.0)
		var t_tap := t_start + span * frac
		var pitch_ratio := lerpf(pitch_begin, pitch_end, frac) * randf_range(0.95, 1.05)
		var amp := randf_range(0.3, 0.5) # Softer taps
		_reload_tap(out, t_tap, pitch_ratio, amp)

func _reload_tap(out: PackedVector2Array, start_time: float, pitch_ratio: float, amp: float) -> void:
	var tap_dur := 0.025 # Sharper
	var start_idx := int(start_time * MIX_RATE)
	if start_idx < 0:
		start_idx = 0
	if start_idx >= out.size():
		return
	var tap_n := int(tap_dur * MIX_RATE)
	var center := 1700.0 * pitch_ratio
	var fc_hi := center * 1.5
	var fc_lo := maxf(40.0, center * 0.6)
	var k_hi := 1.0 - exp(-TAU * fc_hi / MIX_RATE)
	var k_lo := 1.0 - exp(-TAU * fc_lo / MIX_RATE)

	var lp_hi := 0.0
	var lp_lo := 0.0
	for i in range(tap_n):
		var idx := start_idx + i
		if idx >= out.size(): break
		var t := float(i) / MIX_RATE
		var env := exp(-t * 280.0) # Faster decay, less plucky
		var noise := randf_range(-1.0, 1.0)
		lp_hi += k_hi * (noise - lp_hi)
		lp_lo += k_lo * (noise - lp_lo)
		var s: float = (lp_hi - lp_lo) * env * amp
		var existing: Vector2 = out[idx]
		out[idx] = Vector2(existing.x + s, existing.y + s)

func _synth_bullet_zip(speed_factor: float, scale_factor: float) -> PackedVector2Array:
	# Per-call jitter so consecutive zips never sound identical.
	var pitch_jit: float = randf_range(0.90, 1.10)
	var dur_jit: float = randf_range(0.85, 1.18)
	var bright_jit: float = randf_range(0.80, 1.20)
	# Base pitch — bright, snappy whip. Bazooka ~2.2 kHz; base ~4.8 kHz;
	# hitscan ~8 kHz tick.
	var base_high: float = clampf(3500.0 + 1500.0 * speed_factor, 2800.0, 8000.0) * pitch_jit
	# Doppler sweep: pitch slides from high (incoming) to low (receding).
	# Slower bullets get more pronounced drop; fast ones are too brief to drag.
	var doppler_drop: float = lerpf(0.55, 0.85, clampf(speed_factor / 4.0, 0.0, 1.0))
	var base_low: float = base_high * doppler_drop
	# Faster bullets = shorter sound. Default ~80 ms, bazooka ~200 ms, hitscan ~50 ms.
	var dur: float = clampf((0.06 + 0.06 / speed_factor) * dur_jit, 0.04, 0.22)
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	var hp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var phase: float = t / dur
		# Glide cubic-eased so the doppler curve feels natural.
		var sweep_t: float = phase * phase * (3.0 - 2.0 * phase)
		var center: float = lerpf(base_high, base_low, sweep_t) * bright_jit
		var lp_k: float = clampf(center * 4.0 / MIX_RATE, 0.02, 0.95)
		var hp_k: float = clampf(center * 0.6 / MIX_RATE, 0.005, 0.5)
		var env: float = sin(PI * clampf(phase, 0.0, 1.0))
		var noise := randf_range(-1.0, 1.0)
		lp = lerpf(lp, noise, lp_k)
		hp = lerpf(hp, lp, hp_k)
		var bp: float = lp - hp
		var s: float = bp * env * 0.42 * scale_factor
		out[i] = Vector2(s, s)
	return out

func _synth_dash() -> PackedVector2Array:
	# Soft air whoosh — low cutoff + gentle envelope, generous headroom so
	# the dB setting controls loudness rather than the synth clipping it.
	var dur := 0.16
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		# Slightly slower attack so there's no "pop" at the start.
		var env_phase := clampf(t / dur, 0.0, 1.0)
		var env := pow(sin(PI * env_phase), 1.6)
		var noise := randf_range(-1.0, 1.0)
		# Tighter band around ~200–600 Hz reads as "rush of air" rather than hiss.
		var cutoff_k := lerpf(0.08, 0.22, t / dur)
		lp = lerpf(lp, noise, cutoff_k)
		var s := lp * env * 0.18
		out[i] = Vector2(s, s)
	return out
func _synth_card_flip(pitch_ratio: float = 1.0) -> PackedVector2Array:
	# A quick, airy "woosh" to sound like paper or a digital card flipping.
	var dur := 0.12
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := sin(PI * clampf(t / dur, 0.0, 1.0))
		var noise := randf_range(-1.0, 1.0)
		var cutoff_k := lerpf(0.6, 0.1, t / dur) * pitch_ratio
		lp = lerpf(lp, noise, clampf(cutoff_k, 0.01, 0.99))
		var s := lp * env * 0.5
		out[i] = Vector2(s, s)
	return out

func _synth_pling(pitch_ratio: float = 1.0) -> PackedVector2Array:
	# Simple high-pitched sine pling with exponential decay.
	var dur := 0.25
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var freq := 880.0 * pitch_ratio
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 22.0)
		var s := sin(2.0 * PI * freq * t) * env * 0.5
		out[i] = Vector2(s, s)
	return out

func _synth_hitmarker(kind: String, dmg_ratio: float = 1.0) -> PackedVector2Array:
	# Short metallic "tink" — CoD-style hit confirm. Built from:
	#   • a ~3ms noise transient (the "click" on attack),
	#   • two close harmonics for the tonal ring,
	#   • a fast exponential decay so the whole thing is gone in ~40ms.
	# Heavier hits drop pitch, slow the decay, and extend duration so the
	# low end has room to resonate into a thunk.
	var pitch_factor: float = 1.0 / pow(dmg_ratio, 0.45)
	var decay_factor: float = lerpf(1.0, 0.45, clampf((dmg_ratio - 1.0) / 4.0, 0.0, 1.0))
	var dur: float = clampf(0.05 / decay_factor, 0.05, 0.14)
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var f1 := 2500.0
	var f2 := 1700.0
	if kind == "head":
		f1 = 3400.0
		f2 = 2250.0
	elif kind == "kill":
		f1 = 1800.0
		f2 = 1200.0
	f1 *= pitch_factor
	f2 *= pitch_factor
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 100.0 * decay_factor)
		var attack_env := exp(-t * 600.0 * decay_factor)
		var noise := randf_range(-1.0, 1.0) * attack_env * 0.5
		var tone := sin(2.0 * PI * f1 * t) * 0.55 + sin(2.0 * PI * f2 * t) * 0.35
		var s := tanh((noise + tone * env) * 0.9)
		out[i] = Vector2(s, s)
	return out
