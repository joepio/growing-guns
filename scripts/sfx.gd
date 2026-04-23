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

func shot() -> void: _play(_synth_shot(), -4.0)
func grenade_launch() -> void: _play(_synth_grenade_launch(), -6.0)
func explosion() -> void: _play(_synth_explosion(), -2.0)
func hit_received() -> void: _play(_synth_hit_received(), -4.0)
func kill_confirm() -> void: _play(_synth_kill_confirm(), -6.0)
func melee() -> void: _play(_synth_melee(), -6.0)
func jump() -> void: _play(_synth_jump(), -12.0)
func dash() -> void: _play(_synth_dash(), -10.0)
func hitmarker(kind: String = "body") -> void: _play(_synth_hitmarker(kind), -10.0)

# -------------------- synthesis --------------------

func _synth_shot() -> PackedVector2Array:
	# White noise burst + brief low thump. Fast decay envelope.
	var dur := 0.10
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(clampf(1.0 - t / dur, 0.0, 1.0), 2.5)
		var noise := randf_range(-1.0, 1.0)
		lp = lerpf(lp, noise, 0.35)  # simple one-pole lowpass
		var low := sin(2.0 * PI * 90.0 * t) * exp(-t * 30.0)
		var s := (lp * 0.75 + low * 0.4) * env * 0.7
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

func _synth_hitmarker(kind: String) -> PackedVector2Array:
	# High tick — body/head/kill vary by pitch.
	var dur := 0.08
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var freq := 1200.0
	if kind == "head":
		freq = 1800.0
	elif kind == "kill":
		freq = 900.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 55.0)
		var tone := sin(2.0 * PI * freq * t)
		var s := tone * env * 0.4
		out[i] = Vector2(s, s)
	return out
