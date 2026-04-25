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
# Two-bus architecture so distant sounds keep their reverb tail:
#   dry copy → Master, fast 3D attenuation (unit_size = `unit_size`)
#   wet copy → REVERB_BUS (pure reverb), slow 3D attenuation (reverb_unit_size)
# Result: as a sound recedes its dry signal fades fast but the wet send only
# fades slowly, so the wet/dry ratio rises with distance — like real space.
const BUS_3D := "SFX3D"           # back-compat name (kept for any external refs)
const REVERB_BUS := "SFXReverb"   # pure-wet send bus
const NO_POS := Vector3.INF
const DRY_RADIUS := 4.0  # legacy constant — unused now, kept for compat

var _sample_cache: Dictionary = {}
var _hurt_sounds: Array[AudioStreamWAV] = []
var _death_sounds: Array[AudioStreamWAV] = []
var _gun_sounds: Array[AudioStreamWAV] = []
var _step_sounds: Array[AudioStream] = []
var _card_pick_sound: AudioStreamWAV = null

# Tunable mix knobs — adjust live via scenes/audio_lab.tscn.
var shot_self_db: float = -8.5
var shot_world_db: float = -2.5
var shot_dmg_per_double_db: float = 6.0
var shot_pitch_per_double: float = 0.20  # 0..1; pitch drop per damage doubling
var explosion_bang_db: float = 12.0
var explosion_rumble_db: float = 10.0
var footstep_db: float = -30.0
var jump_db: float = -10.5
var landing_max_db: float = 5.0
var hurt_self_db: float = -28.0
var hurt_world_db: float = -20.5
var death_self_db: float = -24.0
var death_world_db: float = -18.5
var hit_received_db: float = -12.0
var bullet_zip_close_db: float = -22.0
var bullet_zip_far_db: float = -44.0
var unit_size: float = 12.0
# Reverb send tuning. Wet attenuates slower than dry so distant sounds keep a
# tail, but if the gap is too big the wet drowns the direct signal at range.
var reverb_unit_size: float = 16.0   # how slowly the wet attenuates (only modestly > unit_size)
var reverb_send_db: float = -9.0     # dB shaved off wet copies vs dry

# Live-tunable reverb params — setters push to the actual AudioEffectReverb so
# they take effect immediately. Null-guarded for default-value init order.
var _reverb_effect: AudioEffectReverb = null
var reverb_room_size: float = 0.85:
	set(v):
		reverb_room_size = v
		if _reverb_effect: _reverb_effect.room_size = v
var reverb_damping: float = 0.45:
	set(v):
		reverb_damping = v
		if _reverb_effect: _reverb_effect.damping = v
var reverb_wet: float = 1.0:
	set(v):
		reverb_wet = v
		if _reverb_effect: _reverb_effect.wet = v
var reverb_predelay_msec: float = 35.0:
	set(v):
		reverb_predelay_msec = v
		if _reverb_effect: _reverb_effect.predelay_msec = v
var reverb_predelay_feedback: float = 0.4:
	set(v):
		reverb_predelay_feedback = v
		if _reverb_effect: _reverb_effect.predelay_feedback = v
var reverb_spread: float = 0.95:
	set(v):
		reverb_spread = v
		if _reverb_effect: _reverb_effect.spread = v
var reverb_hipass: float = 0.35:
	set(v):
		reverb_hipass = v
		if _reverb_effect: _reverb_effect.hipass = v


func _ready() -> void:
	_ensure_reverb_bus()
	_load_assets()

func _load_assets() -> void:
	for i in range(1, 15):
		var path := "res://assets/audio/hurt%d.wav" % i
		if ResourceLoader.exists(path):
			_hurt_sounds.append(load(path))
	for i in range(1, 10):
		var path := "res://assets/audio/death%d.wav" % i
		if ResourceLoader.exists(path):
			_death_sounds.append(load(path))
	if ResourceLoader.exists("res://assets/audio/gun1.wav"):
		_gun_sounds.append(load("res://assets/audio/gun1.wav"))

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

func _ensure_reverb_bus() -> void:
	# Set up once. The wet send is a dedicated bus carrying ONLY reverb tail
	# (dry=0, wet=1). Sources emit a parallel "wet send" copy here whose 3D
	# attenuation is much gentler than the dry copy on Master — so distant
	# sounds keep their tail while the direct signal fades.
	_ensure_master_chain()
	if AudioServer.get_bus_index(REVERB_BUS) >= 0:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, REVERB_BUS)
	AudioServer.set_bus_send(idx, "Master")
	var reverb := AudioEffectReverb.new()
	reverb.predelay_msec = reverb_predelay_msec
	reverb.predelay_feedback = reverb_predelay_feedback
	reverb.room_size = reverb_room_size
	reverb.damping = reverb_damping
	reverb.spread = reverb_spread
	reverb.hipass = reverb_hipass
	reverb.dry = 0.0   # bus output is *only* reverb tail
	reverb.wet = reverb_wet
	AudioServer.add_bus_effect(idx, reverb)
	_reverb_effect = reverb

# Master chain: ear-style compressor first, then a brick-wall limiter as
# final safety. Compressor catches every transient immediately (zero attack)
# and releases over 200 ms, so a burst of fire ducks the whole burst — like
# how real ears adapt to continuous loud noise.
func _ensure_master_chain() -> void:
	var master_idx := AudioServer.get_bus_index("Master")
	if master_idx < 0:
		return
	# Idempotent — bail if our compressor is already installed.
	for i in AudioServer.get_bus_effect_count(master_idx):
		if AudioServer.get_bus_effect(master_idx, i) is AudioEffectCompressor:
			return
	var comp := AudioEffectCompressor.new()
	comp.threshold = -8.0     # start compressing at -8 dB
	comp.ratio = 4.0          # 4:1 — clearly audible ducking on loud bursts
	comp.attack_us = 1.0      # ~instant catching (no transient boost)
	comp.release_ms = 200.0   # ear-like adaptation curve
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

func _listener_position() -> Vector3:
	var vp := get_viewport()
	if vp == null:
		return NO_POS
	var cam := vp.get_camera_3d()
	return cam.global_position if cam else NO_POS

# -------------------- dispatch --------------------

func _configure_dry_player(p: AudioStreamPlayer3D) -> void:
	# Direct/dry signal — sharp distance falloff so close sources dominate.
	p.bus = "Master"
	p.unit_size = unit_size
	p.max_db = 24.0
	p.max_distance = 0.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.attenuation_filter_cutoff_hz = 3200.0
	p.attenuation_filter_db = -12.0

func _configure_wet_player(p: AudioStreamPlayer3D) -> void:
	# Reverb send — gentle distance falloff so the wet tail persists at range.
	# Lowpass set lower since long-distance reflections are already darkened.
	p.bus = REVERB_BUS
	p.unit_size = reverb_unit_size
	p.max_db = 12.0
	p.max_distance = 0.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.attenuation_filter_cutoff_hz = 2200.0
	p.attenuation_filter_db = -8.0

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
	# AudioStream resource can drive two AudioStreamPlayer3Ds (dry + wet).
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

func _play(samples: PackedVector2Array, volume_db: float = -6.0, at: Vector3 = NO_POS, debug_label: String = "") -> Node:
	_log_sfx(debug_label, volume_db, at)
	if samples.is_empty():
		return null
	# Bake samples to WAV and route through _play_stream so the dry+wet
	# dispatch is shared between sample-based and stream-based callers.
	# Empty label avoids a second log line.
	return _play_stream(_samples_to_wav(samples), volume_db, at, 1.0, "")

func _play_stream(stream: AudioStream, volume_db: float = -6.0, at: Vector3 = NO_POS, pitch_scale: float = 1.0, debug_label: String = "") -> Node:
	_log_sfx(debug_label, volume_db, at)
	if stream == null:
		return null
	var life: float = stream.get_length() / maxf(0.1, pitch_scale) + 0.15
	if at == NO_POS:
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = volume_db
		p.pitch_scale = pitch_scale
		add_child(p)
		p.play()
		get_tree().create_timer(life).timeout.connect(p.queue_free)
		return p
	# 3D — emit a dry copy on Master and a wet send copy on REVERB_BUS so
	# the wet/dry ratio rises naturally with distance.
	var p_dry := AudioStreamPlayer3D.new()
	p_dry.stream = stream
	p_dry.volume_db = volume_db
	p_dry.pitch_scale = pitch_scale
	_configure_dry_player(p_dry)
	add_child(p_dry)
	p_dry.global_position = at
	p_dry.play()
	get_tree().create_timer(life).timeout.connect(p_dry.queue_free)
	var p_wet := AudioStreamPlayer3D.new()
	p_wet.stream = stream
	p_wet.volume_db = volume_db + reverb_send_db
	p_wet.pitch_scale = pitch_scale
	_configure_wet_player(p_wet)
	add_child(p_wet)
	p_wet.global_position = at
	p_wet.play()
	get_tree().create_timer(life).timeout.connect(p_wet.queue_free)
	return p_dry

func _cached_samples(key: String, generator: Callable) -> PackedVector2Array:
	if not _sample_cache.has(key):
		_sample_cache[key] = generator.call()
	return _sample_cache[key]

func _shot_cache_key(w: Weapon = null) -> String:
	if w == null:
		return "shot:default"
	var damage_bucket := int(round(w.get_damage() / 5.0))
	var spread_bucket := int(round(w.spread * 1000.0))
	var fire_bucket := int(round(w.fire_rate_mult * 10.0))
	return "shot:%d:%d:%d" % [damage_bucket, spread_bucket, fire_bucket]

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
	if not _gun_sounds.is_empty():
		if is_self:
			_play_stream(_gun_sounds.pick_random(), self_base + dmg_db, NO_POS, pitch, "shot_self")
		else:
			_play_stream(_gun_sounds.pick_random(), world_base + dmg_db, at, pitch, "shot")
		return
	if is_self:
		_play(_cached_samples(_shot_cache_key(w), Callable(self, "_synth_shot").bind(w)), self_base + dmg_db, NO_POS, "shot_self")
	else:
		_play(_cached_samples(_shot_cache_key(w), Callable(self, "_synth_shot").bind(w)), world_base + dmg_db, at, "shot")
func grenade_launch(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("grenade_launch", Callable(self, "_synth_grenade_launch")), -6.0, at, "grenade_launch")

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
	_play(samples, vol_db, at, "bullet_zip")
func explosion(at: Vector3 = NO_POS, radius: float = 6.0) -> void:
	# Layered: punchy transient bang + a deep brown-noise rumble that
	# decays longer for larger blasts. The rumble samples are bucketed
	# by radius so we don't synth a fresh one per call.
	_play(_cached_samples("explosion", Callable(self, "_synth_explosion")), explosion_bang_db, at, "explosion_bang")
	var r_bucket: int = int(round(clampf(radius, 2.0, 24.0)))
	var rumble_key := "explosion_rumble:%d" % r_bucket
	_play(_cached_samples(rumble_key, Callable(self, "_synth_explosion_rumble").bind(float(r_bucket))), explosion_rumble_db, at, "explosion_rumble")
func melee(at: Vector3 = NO_POS, damage: int = 50) -> void:
	var pitch_ratio: float = clampf(50.0 / float(damage), 0.5, 1.2)
	var key := "melee_%d" % int(round(pitch_ratio * 100.0))
	_play(_cached_samples(key, Callable(self, "_synth_melee").bind(pitch_ratio)), -6.0, at, "melee")
func jump(at: Vector3 = NO_POS) -> void:
	# Jump = a thick "oof" built from two step samples layered an octave apart.
	# Significantly louder than a footstep (~20 dB over) so the takeoff reads.
	if _step_sounds.is_empty():
		return
	_play_stream(_step_sounds.pick_random(), jump_db + randf_range(-1.5, 1.5), at, randf_range(1.02, 1.12), "jump")
	_play_stream(_step_sounds.pick_random(), jump_db - 3.0 + randf_range(-1.5, 1.5), at, randf_range(0.55, 0.65), "jump_low")
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
	_play_stream(_step_sounds.pick_random(), vol, at, pitch, "landing")
	# Sub-octave layer for extra thud on hard landings only.
	if t > 0.25:
		_play_stream(_step_sounds.pick_random(), vol - 4.0, at, pitch * 0.5, "landing_low")
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
	_play_stream(
		_step_sounds.pick_random(),
		footstep_db + randf_range(-2.0, 2.0) + size_db,
		at,
		size_pitch * randf_range(0.92, 1.08),
		"footstep",
	)
func dash(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("dash", Callable(self, "_synth_dash")), -24.0, at, "dash")
func hurt(at: Vector3 = NO_POS, is_self: bool = false) -> void:
	if _hurt_sounds.is_empty(): return
	if is_self:
		_play_stream(_hurt_sounds.pick_random(), hurt_self_db, NO_POS, 1.0, "hurt_self")
	else:
		_play_stream(_hurt_sounds.pick_random(), hurt_world_db + randf_range(-1.5, 1.5), at, 1.0, "hurt")
func death(at: Vector3 = NO_POS, is_self: bool = false) -> void:
	if _death_sounds.is_empty(): return
	if is_self:
		_play_stream(_death_sounds.pick_random(), death_self_db, NO_POS, 1.0, "death_self")
	else:
		_play_stream(_death_sounds.pick_random(), death_world_db + randf_range(-1.5, 1.5), at, 1.0, "death")
func hit_received() -> void:
	_play(_cached_samples("hit_received", Callable(self, "_synth_hit_received")), hit_received_db, NO_POS, "hit_received")
func kill_confirm() -> void:
	_play(_cached_samples("kill_confirm", Callable(self, "_synth_kill_confirm")), -6.0, NO_POS, "kill_confirm")
func pling(pitch_ratio: float = 1.0) -> void:
	var key := "pling_%d" % int(round(pitch_ratio * 100.0))
	_play(_cached_samples(key, Callable(self, "_synth_pling").bind(pitch_ratio)), -10.0, NO_POS, "pling")
func card_flip(pitch_ratio: float = 1.0) -> void:
	if _card_pick_sound:
		_play_stream(_card_pick_sound, -4.0, NO_POS, pitch_ratio, "card_flip")
		return
	var key := "card_flip_%d" % int(round(pitch_ratio * 100.0))
	_play(_cached_samples(key, Callable(self, "_synth_card_flip").bind(pitch_ratio)), -6.0, NO_POS, "card_flip")
func reload(duration: float, at: Vector3 = NO_POS) -> Node:
	# Continuous rattle for the full reload duration. Returns the player node
	# so the caller can stop it early (e.g. on respawn / round end).
	return _play(_synth_reload(duration), -14.0, at, "reload")

func hitmarker(kind: String = "body", dmg: int = 0) -> void:
	# Scale pitch down and volume up with damage — heavy guns land with a
	# bassy thunk, baseline pistol keeps the sharp "tink".
	var dmg_ratio: float = 1.0
	if dmg > 0:
		dmg_ratio = clampf(float(dmg) / Weapon.BASE_DAMAGE, 0.5, 5.0)
	var vol_bonus: float = clampf(log(dmg_ratio) / log(2.0) * 2.0, 0.0, 4.0)
	_play(_cached_samples(_hitmarker_cache_key(kind, dmg), Callable(self, "_synth_hitmarker").bind(kind, dmg_ratio)), -5.0 + vol_bonus, NO_POS, "hitmarker_" + kind)

# -------------------- synthesis --------------------

func _synth_shot(w: Weapon = null) -> PackedVector2Array:
	# Shape the rifle sound around weapon stats:
	#   damage   → longer tail, deeper + louder bass thump
	#   accuracy → brighter noise transient + a high-freq click ("crack")
	#   fire-rate-mult mildly opens up the noise (snappier)
	var dmg_ratio := 1.0
	var accuracy := 1.0  # 1.0 = perfectly accurate, 0.0 = fully sprayed
	if w:
		dmg_ratio = maxf(1.0, w.get_damage() / Weapon.BASE_DAMAGE)
		accuracy = clampf(1.0 - w.spread / 0.06, 0.0, 1.0)

	# Per-shot micro-variations — same stats, unique waveform.
	var pitch_jit := randf_range(0.92, 1.09)
	var decay_jit := randf_range(0.82, 1.20)
	var bright_jit := randf_range(0.85, 1.15)
	var click_freq_jit := randf_range(0.80, 1.25)
	var click_gain_jit := randf_range(0.55, 1.45)
	var dur_jit := randf_range(0.90, 1.12)
	var bass_phase := randf() * TAU
	var click_offset := randf_range(0.0, 0.004)  # 0–4 ms phase-shift trick

	var dur: float = clampf((0.08 + 0.08 * log(dmg_ratio) / log(2.0)) * dur_jit, 0.08, 0.35)
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)

	var bass_freq: float = clampf((90.0 / sqrt(dmg_ratio)) * pitch_jit, 32.0, 130.0)
	var bass_decay: float = clampf((30.0 / dmg_ratio) * decay_jit, 6.0, 45.0)
	var bass_gain: float = lerpf(0.45, 0.95, clampf((dmg_ratio - 1.0) / 3.0, 0.0, 1.0))
	var noise_brightness: float = clampf(lerpf(0.18, 0.55, accuracy) * bright_jit, 0.05, 0.95)
	var click_gain := accuracy * 0.3 * click_gain_jit
	var click_freq := 2400.0 * click_freq_jit

	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(clampf(1.0 - t / dur, 0.0, 1.0), 2.5)
		var noise := randf_range(-1.0, 1.0)
		lp = lerpf(lp, noise, noise_brightness)
		# Phase noise on the bass gives the "gritty" gunpowder quality.
		var low := sin(2.0 * PI * bass_freq * t + bass_phase + randf_range(-0.04, 0.04)) * exp(-t * bass_decay)
		var ct := maxf(t - click_offset, 0.0)
		var click := sin(2.0 * PI * click_freq * ct) * exp(-ct * 280.0) * click_gain
		# tanh soft-clips so loud/layered components stay under ±1.
		var s := tanh((lp * 0.55 + low * bass_gain + click) * env * 0.85)
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

func _synth_explosion() -> PackedVector2Array:
	# Sub-bass thump + lowpass-swept noise tail.
	var dur := 0.70
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(1.0 - t / dur, 1.4)
		var noise := randf_range(-1.0, 1.0)
		var cutoff_k := lerpf(0.5, 0.03, sqrt(t / dur))
		lp = lerpf(lp, noise, cutoff_k)
		var sub := sin(2.0 * PI * 42.0 * t) * exp(-t * 3.5)
		var s := (lp * 0.65 + sub * 0.75) * env * 0.9
		out[i] = Vector2(s, s)
	return out

# Deep rumble layer that pairs with the transient explosion bang. Brown-noise
# generated by integrating white noise, then aggressively low-passed. Bigger
# radius → longer duration AND lower-frequency rumble.
func _synth_explosion_rumble(radius: float) -> PackedVector2Array:
	# Short audio rumble — the long-decay reverb on BUS_3D carries the tail
	# from there, so we don't need to bake a multi-second sample.
	var dur: float = clampf(0.35 + radius * 0.06, 0.35, 1.4)
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	# Bigger blast = lower cutoff = deeper rumble. Range ~60 Hz → 180 Hz.
	var cutoff: float = clampf(220.0 - radius * 7.0, 55.0, 200.0)
	var lp_k: float = clampf(TAU * cutoff / MIX_RATE, 0.005, 0.4)
	var brown: float = 0.0
	var lp: float = 0.0
	# Slow attack so the rumble swells in rather than slapping at t=0.
	var attack_dur: float = 0.08
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var attack: float = clampf(t / attack_dur, 0.0, 1.0)
		# Long exponential decay tied to total duration.
		var decay: float = exp(-t * (3.0 / dur))
		var env: float = attack * decay
		# Brown noise: integrated white noise with a tiny leak so it can't
		# drift into DC offset territory.
		brown = brown * 0.998 + randf_range(-1.0, 1.0) * 0.03
		lp = lerpf(lp, brown, lp_k)
		var s: float = lp * env * 1.5
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
