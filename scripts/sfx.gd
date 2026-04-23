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
# SFX.grenade_launch(at?), SFX.jump(at?), SFX.dash(at?),
# SFX.hit_received(), SFX.kill_confirm(), SFX.hitmarker(kind, dmg).

const MIX_RATE := 44100.0
const BUS_3D := "SFX3D"
const NO_POS := Vector3.INF
# Sounds within this distance of the listener play dry on Master, so your own
# gun and footsteps don't drown in room tail. Farther sounds go through the
# reverb-colored 3D bus so distant fights get the "outdoors" echo.
const DRY_RADIUS := 4.0

func _ready() -> void:
	_ensure_reverb_bus()

func _ensure_reverb_bus() -> void:
	# Set up once. Project file has no bus layout, so create a dedicated
	# reverb-colored bus for 3D sounds; UI sounds keep the dry Master bus.
	if AudioServer.get_bus_index(BUS_3D) >= 0:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, BUS_3D)
	AudioServer.set_bus_send(idx, "Master")
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.45
	reverb.damping = 0.55
	reverb.spread = 0.8
	reverb.wet = 0.10
	reverb.dry = 1.0
	AudioServer.add_bus_effect(idx, reverb)

func _listener_position() -> Vector3:
	var vp := get_viewport()
	if vp == null:
		return NO_POS
	var cam := vp.get_camera_3d()
	return cam.global_position if cam else NO_POS

# -------------------- dispatch --------------------

func _play(samples: PackedVector2Array, volume_db: float = -6.0, at: Vector3 = NO_POS) -> void:
	if samples.is_empty():
		return
	var duration := float(samples.size()) / MIX_RATE
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = MIX_RATE
	stream.buffer_length = duration + 0.05
	var pb: AudioStreamGeneratorPlayback
	var freer: Node
	if at == NO_POS:
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = volume_db
		add_child(p)
		p.play()
		pb = p.get_stream_playback() as AudioStreamGeneratorPlayback
		freer = p
	else:
		var p := AudioStreamPlayer3D.new()
		p.stream = stream
		p.volume_db = volume_db
		# Close-up sounds (your own gun, your own steps) stay dry on Master;
		# farther sounds pick up the room tail on the reverb bus.
		var listener := _listener_position()
		var is_close := listener != NO_POS and listener.distance_to(at) < DRY_RADIUS
		p.bus = "Master" if is_close else BUS_3D
		p.unit_size = 10.0
		p.max_db = 0.0                  # point-blank matches authored volume
		p.max_distance = 120.0          # hard-clip to silence beyond this
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		p.global_position = at
		p.play()
		pb = p.get_stream_playback() as AudioStreamGeneratorPlayback
		freer = p
	if pb:
		pb.push_buffer(samples)
	get_tree().create_timer(duration + 0.15).timeout.connect(freer.queue_free)

# -------------------- sounds --------------------

func shot(w: Weapon = null, at: Vector3 = NO_POS) -> void:
	_play(_synth_shot(w), randf_range(-5.5, -2.5), at)
func grenade_launch(at: Vector3 = NO_POS) -> void: _play(_synth_grenade_launch(), -6.0, at)
func explosion(at: Vector3 = NO_POS) -> void: _play(_synth_explosion(), -2.0, at)
func melee(at: Vector3 = NO_POS) -> void: _play(_synth_melee(), -6.0, at)
func jump(at: Vector3 = NO_POS) -> void: _play(_synth_jump(), -12.0, at)
func dash(at: Vector3 = NO_POS) -> void: _play(_synth_dash(), -10.0, at)
func hit_received() -> void: _play(_synth_hit_received(), -4.0)
func kill_confirm() -> void: _play(_synth_kill_confirm(), -6.0)
func hitmarker(kind: String = "body", dmg: int = 0) -> void:
	# Scale pitch down and volume up with damage — heavy guns land with a
	# bassy thunk, baseline pistol keeps the sharp "tink".
	var dmg_ratio: float = 1.0
	if dmg > 0:
		dmg_ratio = clampf(float(dmg) / Weapon.BASE_DAMAGE, 0.5, 5.0)
	var vol_bonus: float = clampf(log(dmg_ratio) / log(2.0) * 2.0, 0.0, 4.0)
	_play(_synth_hitmarker(kind, dmg_ratio), -5.0 + vol_bonus)

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

func _synth_melee() -> PackedVector2Array:
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
		var cutoff_k := lerpf(0.7, 0.18, t / dur)
		lp = lerpf(lp, noise, cutoff_k)
		var s := lp * env * 0.45
		out[i] = Vector2(s, s)
	return out

func _synth_jump() -> PackedVector2Array:
	# Upward pitch sweep — soft, sine-based.
	var dur := 0.10
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(1.0 - t / dur, 1.5)
		var pitch := lerpf(280.0, 520.0, t / dur)
		var tone := sin(2.0 * PI * pitch * t)
		var s := tone * env * 0.25
		out[i] = Vector2(s, s)
	return out

func _synth_dash() -> PackedVector2Array:
	# Short whoosh — opposite sweep direction from melee so they don't blend.
	var dur := 0.18
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := sin(PI * clampf(t / dur, 0.0, 1.0))
		var noise := randf_range(-1.0, 1.0)
		var cutoff_k := lerpf(0.25, 0.7, t / dur)
		lp = lerpf(lp, noise, cutoff_k)
		var s := lp * env * 0.4
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
