extends Node

# Procedural SFX. Every sound is generated fresh into a short
# AudioStreamGenerator buffer and played one-shot. No samples on disk.
#
# Public API: SFX.shot(), SFX.explosion(), SFX.hit_received(), SFX.kill_confirm(),
# SFX.hitmarker(kind), SFX.melee(), SFX.jump(), SFX.dash(), SFX.grenade_launch().

const MIX_RATE := 44100.0

# -------------------- dispatch --------------------

func _play(samples: PackedVector2Array, volume_db: float = -6.0) -> void:
	if samples.is_empty():
		return
	var duration := float(samples.size()) / MIX_RATE
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = MIX_RATE
	stream.buffer_length = duration + 0.05
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	add_child(player)
	player.play()
	var pb := player.get_stream_playback() as AudioStreamGeneratorPlayback
	if pb:
		pb.push_buffer(samples)
	get_tree().create_timer(duration + 0.15).timeout.connect(player.queue_free)

# -------------------- sounds --------------------

func shot(w: Weapon = null) -> void: _play(_synth_shot(w), randf_range(-5.5, -2.5))
func grenade_launch() -> void: _play(_synth_grenade_launch(), -6.0)
func explosion() -> void: _play(_synth_explosion(), -2.0)
func hit_received() -> void: _play(_synth_hit_received(), -4.0)
func kill_confirm() -> void: _play(_synth_kill_confirm(), -6.0)
func melee() -> void: _play(_synth_melee(), -6.0)
func jump() -> void: _play(_synth_jump(), -12.0)
func dash() -> void: _play(_synth_dash(), -10.0)
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
