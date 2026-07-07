extends Node

# Procedural colosseum crowd audio. Three seamless stereo loops are
# synthesized once at boot (no samples on disk — same philosophy as sfx.gd)
# and crossfaded by two gameplay-driven state values:
#
#   enthusiasm 0..1 — players trading damage, kills, spectacular explosions.
#   fear       0..1 — the crowd ITSELF getting shot at / caught in blasts.
#
# Layers:
#   murmur — idle "walla": lowpassed noise with ~4 Hz syllabic amplitude
#            flutter per channel (the classic crowd-chatter trick).
#   cheer  — roar: noise through two vocal-formant resonators + applause
#            crackle. Gain follows enthusiasm, suppressed by fear (a
#            frightened crowd doesn't cheer).
#   panic  — screams: higher formants, chaotic flutter, descending sine
#            wails. Gain follows fear; fear also decays slower.
#
# The bowl surrounds the whole arena, so the beds play 2D (diffuse field —
# no meaningful direction; costs 3 stream mixes total). One-shot reactions
# (kill roar, hit "ooh", scream burst when a bullet/blast lands in the
# stands) DO have a direction: they play 3D at the nearest point on the
# crowd ring via SFX._play_stream, inheriting reverb, HDR culling, distance
# delay and splitscreen ghosts.
#
# ColosseumBuilder.build registers the ring geometry + the crowd's
# ShaderMaterial here; the same enthusiasm/fear pair also drives the
# shader's excitement/panic uniforms so the silhouettes jump when they roar
# and cower when they scream.
#
# Perf: all synthesis is boot-time, chunked across frames. Per frame the
# node costs a few float ops + at most 2 set_shader_parameter calls; the
# per-bullet stands test exits on a single Y comparison for any bullet
# below stand height.

const RATE := 22050
const LOOP_SECONDS := 6.0
const SEAM_SECONDS := 0.4  # tail crossfaded into the head for seamless loops
const CHUNK := 4096        # synth samples per frame during boot warmup

# Mix knobs (dB at full layer gain).
var murmur_db: float = -22.0
var cheer_db: float = -10.0
var panic_db: float = -9.0
var reaction_db: float = -8.0

# State — public so the dev panel / labs can poke it.
var enthusiasm: float = 0.0
var fear: float = 0.0
# Exponential decay rates (fraction per second). Fear lingers longer.
const ENTHUSIASM_DECAY := 0.38
const FEAR_DECAY := 0.20
# While a colosseum ring exists, enthusiasm settles here instead of 0 —
# a fight in progress always has a lively (if quiet) crowd under it.
const ENTHUSIASM_FLOOR := 0.2

var ring_active: bool = false

var _ring_id: int = 0
var _ring_node: Node3D = null
var _ring_center := Vector3.ZERO
var _ring_center_ok := false
var _r_inner: float = 0.0
var _r_outer: float = 0.0
var _r_inner_sq: float = 0.0
var _r_outer_sq: float = 0.0
var _y_base: float = 0.0
var _y_top: float = 0.0
var _crowd_mat: ShaderMaterial = null
var _shader_excitement: float = -1.0
var _shader_panic: float = -1.0

var _murmur_player: AudioStreamPlayer
var _cheer_player: AudioStreamPlayer
var _panic_player: AudioStreamPlayer
# Smoothed layer gains (0..1) so state spikes swell in instead of snapping.
var _murmur_gain: float = 0.0
var _cheer_gain: float = 0.0
var _panic_gain: float = 0.0

var _roar_wav: AudioStreamWAV = null
var _surge_wav: AudioStreamWAV = null  # round-start anticipation swell
var _ooh_wav: AudioStreamWAV = null
var _scream_wav: AudioStreamWAV = null
var _roar_cd: float = 0.0
var _ooh_cd: float = 0.0
var _scream_cd: float = 0.0
# While > 0, enthusiasm is pinned at 1.0 and the combat duck is bypassed —
# the round-win celebration owns the mix for a few seconds.
var _celebrate_hold: float = 0.0


func _ready() -> void:
	_murmur_player = _make_loop_player()
	_cheer_player = _make_loop_player()
	_panic_player = _make_loop_player()
	_synth_all()


func _make_loop_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.volume_db = -80.0
	add_child(p)
	return p


# -------------------- ring registration --------------------

# Called by ColosseumBuilder.build once the bowl exists. The ring is the
# torus-ish band the spectators occupy: radii [r_inner, r_outer] between
# heights [y_base, y_top] around the colosseum root's origin.
func register_ring(
	root: Node3D,
	r_inner: float,
	r_outer: float,
	y_base: float,
	y_top: float,
	crowd_mat: ShaderMaterial,
) -> void:
	_ring_id = root.get_instance_id()
	_ring_node = root
	_ring_center_ok = false
	_r_inner = r_inner
	_r_outer = r_outer
	_r_inner_sq = r_inner * r_inner
	_r_outer_sq = r_outer * r_outer
	_y_base = y_base
	_y_top = y_top
	_crowd_mat = crowd_mat
	_shader_excitement = -1.0
	_shader_panic = -1.0
	ring_active = true


func unregister_ring(id: int) -> void:
	if id != _ring_id:
		return  # a newer arena already registered its own ring
	ring_active = false
	_ring_node = null
	_crowd_mat = null
	enthusiasm = 0.0
	fear = 0.0


# Lazy center resolution: the colosseum root may not be inside the tree yet
# when register_ring runs (editor-owner builds), so global_position is read
# on first use and cached.
func _resolve_center() -> bool:
	if _ring_center_ok:
		return true
	if _ring_node == null or not is_instance_valid(_ring_node) or not _ring_node.is_inside_tree():
		return false
	_ring_center = _ring_node.global_position
	_ring_center_ok = true
	return true


# -------------------- geometry queries --------------------

# Hot path: called per bullet per physics tick. Y test first — nearly every
# bullet flies below the stands, so this usually exits on one comparison.
func point_in_crowd(p: Vector3) -> bool:
	if not ring_active:
		return false
	if p.y < _y_base or p.y > _y_top:
		return false
	if not _resolve_center():
		return false
	var dx := p.x - _ring_center.x
	var dz := p.z - _ring_center.z
	var rr := dx * dx + dz * dz
	return rr >= _r_inner_sq and rr <= _r_outer_sq


# Hitscan companion: does the segment cross into the stands band? Solves the
# ray/cylinder crossing for the inner radius analytically — no stepping.
func check_segment(from: Vector3, to: Vector3) -> void:
	if not ring_active or not _resolve_center():
		return
	var p := Vector2(from.x - _ring_center.x, from.z - _ring_center.z)
	var d := Vector2(to.x - from.x, to.z - from.z)
	var a := d.dot(d)
	if a < 0.0001:
		return
	var b := 2.0 * p.dot(d)
	var c := p.dot(p) - _r_inner_sq
	var disc := b * b - 4.0 * a * c
	if disc <= 0.0:
		return
	var sq := sqrt(disc)
	for t: float in [(-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a)]:
		if t < 0.0 or t > 1.0:
			continue
		var y := from.y + (to.y - from.y) * t
		if y >= _y_base and y <= _y_top:
			on_crowd_bullet_hit(from.lerp(to, t))
			return


# Distance from a point to the crowd band (0 when inside it).
func _dist_to_crowd(p: Vector3) -> float:
	var pr := Vector2(p.x - _ring_center.x, p.z - _ring_center.z).length()
	var dr := maxf(maxf(_r_inner - pr, pr - _r_outer), 0.0)
	var dy := maxf(maxf(_y_base - p.y, p.y - _y_top), 0.0)
	return Vector2(dr, dy).length()


# Nearest seat to a world position — where directional reactions play from.
func _ring_point_toward(p: Vector3) -> Vector3:
	var dir := Vector2(p.x - _ring_center.x, p.z - _ring_center.z)
	if dir.length_squared() < 0.01:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var r := _r_inner + 3.0
	var y := _y_base + (_y_top - _y_base) * 0.35
	return Vector3(_ring_center.x + dir.x * r, y, _ring_center.z + dir.y * r)


# -------------------- gameplay events --------------------

# Round opening: the crowd roars in anticipation, fear from last round's
# carnage is forgotten, and enthusiasm starts high before settling to the
# in-fight baseline.
func on_round_start() -> void:
	if not ring_active or (BenchFlags.active):
		return
	fear = 0.0
	enthusiasm = maxf(enthusiasm, 0.85)
	# Pre-lift the cheer bed so the swell hands off into an already-roaring
	# crowd instead of tailing into a dip.
	_cheer_gain = maxf(_cheer_gain, 0.6)
	if _surge_wav != null:
		_roar_cd = 2.0
		SFX._play_stream(_surge_wav, reaction_db, Vector3.INF,
			randf_range(0.96, 1.02), "crowd_roar", -1.0, false, 100.0, true)


# Round won — the loudest the crowd ever gets. Punchy roar on top of the
# slow surge for a sustained eruption, enthusiasm pinned at max for a few
# seconds so the beds stay at full roar instead of instantly decaying.
func on_round_win() -> void:
	if not ring_active or (BenchFlags.active):
		return
	fear = 0.0
	enthusiasm = 1.0
	_cheer_gain = 1.0
	_celebrate_hold = 4.0
	_roar_cd = 2.5
	# SPL 135: a 15k-strong stadium eruption really is that loud — and it has
	# to clear SFX's HDR cull window (max_spl - 35) even when the winning
	# blow was a 165-SPL explosion, or the roar never plays at all.
	if _roar_wav != null:
		SFX._play_stream(_roar_wav, reaction_db + 4.0, Vector3.INF,
			randf_range(0.96, 1.02), "crowd_roar", -1.0, false, 135.0, true)
	if _surge_wav != null:
		SFX._play_stream(_surge_wav, reaction_db + 1.0, Vector3.INF,
			1.0, "crowd_roar", -1.0, false, 135.0, true)


func on_player_hurt(_pos: Vector3) -> void:
	if not ring_active or (BenchFlags.active):
		return
	enthusiasm = clampf(enthusiasm + 0.18, 0.0, 1.0)
	# Occasional collective "ooh" so not every hit gets a vocal reaction.
	if _ooh_cd <= 0.0 and _ooh_wav != null and randf() < 0.4:
		_ooh_cd = 1.6
		SFX._play_stream(_ooh_wav, reaction_db - 6.0 + enthusiasm * 3.0, Vector3.INF,
			randf_range(0.92, 1.1), "crowd_ooh", -1.0, false, 88.0, false)


func on_player_death(_pos: Vector3) -> void:
	if not ring_active or (BenchFlags.active):
		return
	enthusiasm = clampf(enthusiasm + 0.6, 0.0, 1.0)
	if _roar_cd <= 0.0 and _roar_wav != null:
		_roar_cd = 1.4
		# 2D — the kill roar comes from the whole bowl at once.
		SFX._play_stream(_roar_wav, reaction_db + enthusiasm * 3.0, Vector3.INF,
			randf_range(0.94, 1.06), "crowd_roar", -1.0, false, 102.0, true)


func on_explosion(pos: Vector3, radius: float) -> void:
	if not ring_active or (BenchFlags.active) or not _resolve_center():
		return
	var reach := radius * 1.2 + 1.5
	var d := _dist_to_crowd(pos)
	if d <= reach:
		# Blast into (or right next to) the stands — terror, scaled by size
		# and proximity. Cheering collapses: survivors don't applaud that.
		var proximity := 1.0 - 0.5 * (d / reach)
		fear = clampf(fear + (0.3 + radius * 0.03) * proximity, 0.0, 1.0)
		enthusiasm *= 0.45
		_scream_burst(pos, 1.0)
		# ...and the spectators inside the blast don't scream at all. The KILL
		# radius is half the scream reach — a blast should terrify a section
		# but only delete the seats it directly lands on.
		if ColosseumCrowd.active:
			var kills := ColosseumCrowd.active.apply_blast(pos, reach * 0.5)
			fear = clampf(fear + float(kills) * 0.01, 0.0, 1.0)
	else:
		# Fireworks in the arena — the crowd loves it.
		enthusiasm = clampf(enthusiasm + clampf(0.05 + radius * 0.012, 0.0, 0.3), 0.0, 1.0)


func on_crowd_bullet_hit(pos: Vector3) -> void:
	if not ring_active or (BenchFlags.active):
		return
	fear = clampf(fear + 0.09, 0.0, 1.0)
	_scream_burst(pos, 0.55)
	if ColosseumCrowd.active:
		ColosseumCrowd.active.apply_bullet(pos)


# A bullet already resolved a kill inside the stands (analytic body hit —
# spectators have no colliders). Reaction only; kill + gore happened upstream.
func notify_crowd_kill(pos: Vector3) -> void:
	if not ring_active or (BenchFlags.active):
		return
	fear = clampf(fear + 0.12, 0.0, 1.0)
	_scream_burst(pos, 0.7)


func _scream_burst(pos: Vector3, intensity: float) -> void:
	if _scream_cd > 0.0 or _scream_wav == null:
		return
	_scream_cd = 0.55
	var at := _ring_point_toward(pos)
	SFX._play_stream(_scream_wav, reaction_db - 4.0 + intensity * 5.0, at,
		randf_range(0.9, 1.15), "crowd_scream", 35.0, false, 96.0 + intensity * 8.0, true)


# -------------------- per-frame mix --------------------

func _process(delta: float) -> void:
	# Enthusiasm decays toward the baseline floor (0 when no ring exists),
	# so an active arena always keeps a lively undercurrent.
	var e_floor := ENTHUSIASM_FLOOR if ring_active else 0.0
	enthusiasm = maxf(e_floor, enthusiasm - (enthusiasm - e_floor) * ENTHUSIASM_DECAY * delta)
	fear = maxf(0.0, fear - fear * FEAR_DECAY * delta)
	if _celebrate_hold > 0.0:
		_celebrate_hold -= delta
		enthusiasm = 1.0
	_roar_cd = maxf(0.0, _roar_cd - delta)
	_ooh_cd = maxf(0.0, _ooh_cd - delta)
	_scream_cd = maxf(0.0, _scream_cd - delta)

	var murmur_t := 0.0
	var cheer_t := 0.0
	var panic_t := 0.0
	if ring_active:
		murmur_t = clampf(0.55 + 0.3 * enthusiasm - 0.25 * fear, 0.15, 0.9)
		cheer_t = enthusiasm * (1.0 - fear * 0.75)
		panic_t = fear
	# Swell up fast (crowds react quickly), settle down a bit slower.
	var k_up := minf(1.0, delta * 5.0)
	var k_down := minf(1.0, delta * 1.6)
	_murmur_gain += (murmur_t - _murmur_gain) * (k_up if murmur_t > _murmur_gain else k_down)
	_cheer_gain += (cheer_t - _cheer_gain) * (k_up if cheer_t > _cheer_gain else k_down)
	_panic_gain += (panic_t - _panic_gain) * (k_up if panic_t > _panic_gain else k_down)

	# Duck the beds under heavy combat — piggybacks on SFX's HDR loudness
	# tracker so gunfights push the crowd into the background naturally.
	# Bypassed while celebrating a win: the final kill's explosion SPL would
	# otherwise shove the victory roar into the background.
	var duck: float = 0.0
	if _celebrate_hold <= 0.0:
		duck = clampf((SFX._hdr_max_spl - 112.0) * 0.4, 0.0, 10.0)
	_apply_gain(_murmur_player, _murmur_gain, murmur_db - duck)
	_apply_gain(_cheer_player, _cheer_gain, cheer_db - duck)
	_apply_gain(_panic_player, _panic_gain, panic_db - duck * 0.5)

	# Drive the silhouette shader so the crowd's body language matches the
	# sound: excited → higher/faster hops, afraid → cowering tremble.
	if _crowd_mat != null:
		if absf(enthusiasm - _shader_excitement) > 0.01:
			_shader_excitement = enthusiasm
			_crowd_mat.set_shader_parameter("excitement", enthusiasm)
		if absf(fear - _shader_panic) > 0.01:
			_shader_panic = fear
			_crowd_mat.set_shader_parameter("panic", fear)


# Layer gain (0..1) maps to a FIXED, fairly tight dB window below base_db.
# The old squared-linear mapping spanned ~30 dB, so enthusiasm changes read
# as volume jumps instead of crowd-mood changes; dB-linear over 14 dB keeps
# the bed clearly present at baseline while full roar stays where it was.
const LAYER_DYN_RANGE_DB := 14.0

func _apply_gain(p: AudioStreamPlayer, gain: float, base_db: float) -> void:
	if p == null or p.stream == null:
		return
	if gain < 0.005:
		p.volume_db = -80.0
		return
	p.volume_db = base_db - (1.0 - clampf(gain, 0.0, 1.0)) * LAYER_DYN_RANGE_DB


# -------------------- synthesis --------------------
# Everything below runs once at boot, chunked with process_frame awaits so
# no single frame eats a full loop's worth of synth.

func _synth_all() -> void:
	var murmur := await _synth_murmur(LOOP_SECONDS + SEAM_SECONDS)
	_murmur_player.stream = _to_wav(_finish_loop(murmur), true)
	_murmur_player.play()
	var cheer := await _synth_cheer(LOOP_SECONDS + SEAM_SECONDS, true, 0.0)
	_cheer_player.stream = _to_wav(_finish_loop(cheer), true)
	_cheer_player.play()
	var panic := await _synth_panic(LOOP_SECONDS + SEAM_SECONDS, true, 0.0)
	_panic_player.stream = _to_wav(_finish_loop(panic), true)
	_panic_player.play()
	# One-shots reuse the loop engines with an envelope instead of a seam.
	var roar := await _synth_cheer(2.6, false, 1.0)
	_roar_wav = _to_wav(_normalize(roar, 0.75), false)
	var surge := await _synth_cheer(3.5, false, 2.0)
	_surge_wav = _to_wav(_normalize(surge, 0.7), false)
	var scream := await _synth_panic(1.6, false, 1.0)
	_scream_wav = _to_wav(_normalize(scream, 0.75), false)
	var ooh := await _synth_ooh(1.1)
	_ooh_wav = _to_wav(_normalize(ooh, 0.6), false)


func _finish_loop(buf: PackedVector2Array) -> PackedVector2Array:
	_normalize(buf, 0.7)
	# Blend the tail into the head, then drop the tail → seamless loop.
	var fade_n := int(SEAM_SECONDS * RATE)
	var body_n := buf.size() - fade_n
	for k in fade_n:
		var w := float(k) / float(fade_n)
		buf[k] = buf[k] * w + buf[body_n + k] * (1.0 - w)
	buf.resize(body_n)
	return buf


func _normalize(buf: PackedVector2Array, peak_target: float) -> PackedVector2Array:
	var peak := 0.0001
	for v in buf:
		peak = maxf(peak, maxf(absf(v.x), absf(v.y)))
	var g := peak_target / peak
	for i in buf.size():
		buf[i] = buf[i] * g
	return buf


func _to_wav(buf: PackedVector2Array, looped: bool) -> AudioStreamWAV:
	var n := buf.size()
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in n:
		var v := buf[i]
		data.encode_s16(i * 4, int(clampf(v.x, -1.0, 1.0) * 32767.0))
		data.encode_s16(i * 4 + 2, int(clampf(v.y, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = true
	wav.mix_rate = RATE
	wav.data = data
	if looped:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = n
	return wav


# Idle "walla": double one-pole lowpassed noise (≈ distant voice mush) with
# an independent ~4 Hz syllabic amplitude walk per channel and a slow swell.
func _synth_murmur(seconds: float) -> PackedVector2Array:
	var n := int(seconds * RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 51001
	var lp := Vector2.ZERO
	var lp2 := Vector2.ZERO
	var syl := Vector2(0.5, 0.5)
	var syl_target := Vector2(rng.randf(), rng.randf())
	var ph := rng.randf() * TAU
	var i := 0
	while i < n:
		var stop := mini(i + CHUNK, n)
		while i < stop:
			if i % 128 == 0:
				# ~4 Hz chance-driven retarget = chattering syllable rhythm.
				if rng.randf() < 0.35:
					syl_target = Vector2(rng.randf(), rng.randf())
				syl = syl.lerp(syl_target, 0.3)
			var t := float(i) / RATE
			var swell := 0.7 + 0.2 * sin(TAU * 0.11 * t + ph) + 0.1 * sin(TAU * 0.031 * t)
			lp += (Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) - lp) * 0.16
			lp2 += (lp - lp2) * 0.16
			out[i] = Vector2(
				lp2.x * (0.35 + 0.65 * syl.x),
				lp2.y * (0.35 + 0.65 * syl.y)) * swell
			i += 1
		await get_tree().process_frame
	return out


# Roar engine: noise through two vocal-formant resonators (~650 / 1300 Hz,
# slowly wobbling) with a 5–6 Hz flutter — the "thousands yelling" texture —
# plus applause crackle (Poisson-triggered bright noise bursts).
# `one_shot` > 0 wraps it in a fast-attack / decaying kill-roar envelope.
func _synth_cheer(seconds: float, _looped: bool, one_shot: float) -> PackedVector2Array:
	var n := int(seconds * RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 52002 + int(one_shot)
	# Resonator states: [y1, y2] per formant per channel.
	var f1l := Vector2.ZERO
	var f1r := Vector2.ZERO
	var f2l := Vector2.ZERO
	var f2r := Vector2.ZERO
	var c1 := 0.0
	var c2 := 0.0
	var r1 := exp(-PI * 140.0 / RATE)  # ~140 Hz formant bandwidth
	var r1sq := r1 * r1
	var clap_l := 0.0
	var clap_r := 0.0
	# Dense distant applause: ~1300 Poisson claps/sec/side, ACCUMULATED into
	# a leaky integrator (env += amp on trigger, exponential decay). One
	# state var IS the exact sum of every overlapping decaying clap, so a
	# 50x density costs nothing — and it all bakes into the cached loop at
	# boot anyway, so runtime cost is zero regardless. Two lowpass poles
	# (~1.2 kHz, 12 dB/oct) push the wash across the arena.
	var clap_decay := exp(-1.0 / (0.009 * RATE))
	var clap_p := 1300.0 / RATE
	var clap_lp_l := 0.0
	var clap_lp_r := 0.0
	var clap_lp2_l := 0.0
	var clap_lp2_r := 0.0
	var sw_ph := rng.randf() * TAU
	# Formant drift + loudness surge are RANDOM WALKS, not LFOs. A periodic
	# pitch wobble on a resonant filter makes the whole bed read as one siren
	# instead of thousands of voices; real crowd movement is aperiodic.
	var drift := 0.0
	var flut := 0.7
	var flut_target := 0.7
	var i := 0
	while i < n:
		var stop := mini(i + CHUNK, n)
		while i < stop:
			var t := float(i) / RATE
			if i % 64 == 0:
				drift = clampf(drift + rng.randf_range(-0.01, 0.01), -0.05, 0.05)
				var f1 := 640.0 * (1.0 + drift)
				if one_shot >= 2.0:
					# Anticipation swell: pitch climbs through the build and holds.
					f1 *= 1.0 + 0.12 * minf(t / 1.2, 1.0)
				elif one_shot > 0.0:
					# Kill roar rises in pitch as it swells, sags in the tail —
					# an envelope contour, not an oscillation.
					f1 *= 1.0 + 0.12 * minf(t / 0.45, 1.0) - 0.10 * maxf(t - 1.3, 0.0)
				c1 = 2.0 * r1 * cos(TAU * f1 / RATE)
				c2 = 2.0 * r1 * cos(TAU * f1 * 2.1 / RATE)
				# Aperiodic surging: occasionally pick a new loudness target
				# and slew toward it (~3-7 Hz feel, no fixed tremolo rate).
				if rng.randf() < 0.02:
					flut_target = rng.randf_range(0.45, 1.0)
			flut += (flut_target - flut) * 0.0005
			var swell := 0.78 + 0.22 * sin(TAU * 0.17 * t + sw_ph)
			# One-shot macro envelope — shapes voices AND applause below, so
			# the whole event tapers out instead of the claps cutting dead at
			# the end of the buffer.
			var osc_env := 1.0
			if one_shot >= 2.0:
				# Round-start anticipation: slow build, held, long release.
				osc_env = pow(minf(t / 0.6, 1.0), 1.2) * exp(-maxf(t - 1.8, 0.0) * 1.1)
			elif one_shot > 0.0:
				# Kill roar: punchy attack, quicker decay.
				osc_env = pow(minf(t / 0.14, 1.0), 1.5) * exp(-maxf(t - 0.55, 0.0) * 1.7)
			var env := flut * swell * osc_env
			var wl := rng.randf_range(-1.0, 1.0)
			var wr := rng.randf_range(-1.0, 1.0)
			var y1l := wl + c1 * f1l.x - r1sq * f1l.y
			f1l = Vector2(y1l, f1l.x)
			var y1r := wr + c1 * f1r.x - r1sq * f1r.y
			f1r = Vector2(y1r, f1r.x)
			var y2l := wl + c2 * f2l.x - r1sq * f2l.y
			f2l = Vector2(y2l, f2l.x)
			var y2r := wr + c2 * f2r.x - r1sq * f2r.y
			f2r = Vector2(y2r, f2r.x)
			# Applause: one draw decides L / R / neither this sample; claps
			# ADD into the envelope so they pile up instead of retriggering.
			var cr := rng.randf()
			if cr < clap_p:
				clap_l += rng.randf_range(0.2, 0.7)
			elif cr < clap_p * 2.0:
				clap_r += rng.randf_range(0.2, 0.7)
			clap_l *= clap_decay
			clap_r *= clap_decay
			clap_lp_l += (wl * clap_l - clap_lp_l) * 0.28
			clap_lp_r += (wr * clap_r - clap_lp_r) * 0.28
			clap_lp2_l += (clap_lp_l - clap_lp2_l) * 0.28
			clap_lp2_r += (clap_lp_r - clap_lp2_r) * 0.28
			# Applause breathes with the roar's surges instead of idling flat,
			# and follows the one-shot macro envelope (osc_env is 1.0 in loops).
			var clap_mix := 0.07 * (0.5 + 0.5 * flut) * osc_env
			out[i] = Vector2(
				(y1l + y2l * 0.55) * 0.02 * env + clap_lp2_l * clap_mix,
				(y1r + y2r * 0.55) * 0.02 * env + clap_lp2_r * clap_mix)
			i += 1
		await get_tree().process_frame
	return out


# Panic engine: brighter formants (~1050 / 2450 Hz) with fast chaotic
# flutter, plus individual descending sine wails scattered through the
# buffer — the screams that read over the noise bed.
# `one_shot` > 0 packs the wails early and adds a burst envelope.
func _synth_panic(seconds: float, _looped: bool, one_shot: float) -> PackedVector2Array:
	var n := int(seconds * RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 53003 + int(one_shot)
	# Many quiet screams over few loud ones — overlap is what makes it read
	# as a crowd panicking rather than individual performers.
	var wail_count := 18 if one_shot <= 0.0 else 9
	var w_start: Array[float] = []
	var w_dur: Array[float] = []
	var w_f0: Array[float] = []
	var w_pan: Array[float] = []
	var w_ph: Array[float] = []
	# All per-wail parameters are randomized PER SCREAM and UNCORRELATED —
	# variation lives between screams; within one scream the pitch holds.
	# The raw "baby-cry" edge comes from audio-rate AM (roughness modulation,
	# 35-90 Hz — subharmonic sidebands around every harmonic) driven into a
	# tanh saturator, NOT from pitch movement. Pitch swoops read as seagulls.
	var w_vib_hz: Array[float] = []
	var w_vib_ph: Array[float] = []
	var w_jit: Array[float] = []
	var w_rough_hz: Array[float] = []
	var w_rough_ph: Array[float] = []
	var w_rough_depth: Array[float] = []
	var w_drive: Array[float] = []
	var w_fall: Array[float] = []
	# Upper-harmonic gains, trimmed per scream so high-f0 shrieks don't push
	# harmonics past Nyquist (RATE/2 ≈ 11 kHz) and alias through the tanh.
	var w_h3: Array[float] = []
	var w_h4: Array[float] = []
	for k in wail_count:
		var span := seconds - 1.1 if one_shot <= 0.0 else seconds * 0.45
		w_start.append(rng.randf_range(0.0, maxf(span, 0.1)))
		w_dur.append(rng.randf_range(0.5, 1.0))
		w_f0.append(rng.randf_range(700.0, 2500.0))
		w_pan.append(rng.randf_range(0.15, 0.85))
		w_ph.append(rng.randf() * TAU)
		w_vib_hz.append(rng.randf_range(4.5, 7.5))
		w_vib_ph.append(rng.randf() * TAU)
		w_jit.append(0.0)
		w_rough_hz.append(rng.randf_range(35.0, 90.0))
		w_rough_ph.append(rng.randf() * TAU)
		w_rough_depth.append(rng.randf_range(0.35, 0.7))
		w_drive.append(rng.randf_range(1.6, 3.0))
		# Most screams hold dead flat; some sag slightly at the very end.
		w_fall.append(0.0 if rng.randf() < 0.4 else rng.randf_range(0.04, 0.12))
		w_h3.append(0.35 if w_f0[k] * 3.0 < 9500.0 else 0.0)
		w_h4.append(0.2 if w_f0[k] * 4.0 < 9500.0 else 0.0)
	var f1l := Vector2.ZERO
	var f1r := Vector2.ZERO
	var f2l := Vector2.ZERO
	var f2r := Vector2.ZERO
	var c1 := 0.0
	var c2 := 0.0
	var r1 := exp(-PI * 190.0 / RATE)
	var r1sq := r1 * r1
	# Random-walk drift/surge, same reasoning as the cheer engine: no
	# periodic pitch LFO on the formants (instant siren), no fixed-rate
	# tremolo (instant helicopter). Panic just walks faster than cheer.
	var drift := 0.0
	var flut := 0.6
	var flut_target := 0.6
	var out_lp := Vector2.ZERO
	var out_lp2 := Vector2.ZERO
	var i := 0
	while i < n:
		var stop := mini(i + CHUNK, n)
		while i < stop:
			var t := float(i) / RATE
			if i % 64 == 0:
				drift = clampf(drift + rng.randf_range(-0.015, 0.015), -0.07, 0.07)
				var f1 := 1080.0 * (1.0 + drift)
				c1 = 2.0 * r1 * cos(TAU * f1 / RATE)
				c2 = 2.0 * r1 * cos(TAU * f1 * 2.3 / RATE)
				if rng.randf() < 0.035:
					flut_target = rng.randf_range(0.3, 1.0)
				# Tiny per-wail pitch jitter — humanizes the hold without
				# wobbling it; the harshness comes from the AM, not pitch.
				for k in wail_count:
					w_jit[k] = clampf(w_jit[k] + rng.randf_range(-0.008, 0.008), -0.025, 0.025)
			flut += (flut_target - flut) * 0.0007
			var env := flut
			if one_shot > 0.0:
				env *= pow(minf(t / 0.05, 1.0), 0.8) * exp(-maxf(t - 0.25, 0.0) * 2.1)
			var wl := rng.randf_range(-1.0, 1.0)
			var wr := rng.randf_range(-1.0, 1.0)
			var y1l := wl + c1 * f1l.x - r1sq * f1l.y
			f1l = Vector2(y1l, f1l.x)
			var y1r := wr + c1 * f1r.x - r1sq * f1r.y
			f1r = Vector2(y1r, f1r.x)
			var y2l := wl + c2 * f2l.x - r1sq * f2l.y
			f2l = Vector2(y2l, f2l.x)
			var y2r := wr + c2 * f2r.x - r1sq * f2r.y
			f2r = Vector2(y2r, f2r.x)
			var sl := (y1l + y2l * 0.7) * 0.016 * env
			var sr := (y1r + y2r * 0.7) * 0.016 * env
			# Screams: fast onset, then HELD at one pitch (tiny optional end
			# sag). Roughness AM at 35-90 Hz into tanh saturation supplies
			# the raw torn edge — the baby-cry mechanism (subharmonic
			# sidebands), with pitch kept nearly still.
			for k in wail_count:
				var u := (t - w_start[k]) / w_dur[k]
				if u < 0.0 or u >= 1.0:
					continue
				var vib := 1.0 + w_jit[k] + 0.01 * sin(TAU * w_vib_hz[k] * t + w_vib_ph[k])
				var rise := minf(u / 0.05, 1.0)
				var freq := w_f0[k] * (0.85 + 0.15 * rise) * (1.0 - w_fall[k] * pow(u, 2.0)) * vib
				w_ph[k] += TAU * freq / RATE
				var am := 1.0 - w_rough_depth[k] \
					+ w_rough_depth[k] * (0.5 + 0.5 * sin(TAU * w_rough_hz[k] * t + w_rough_ph[k]))
				var stack := sin(w_ph[k]) + 0.6 * sin(2.0 * w_ph[k]) \
					+ w_h3[k] * sin(3.0 * w_ph[k]) + w_h4[k] * sin(4.0 * w_ph[k])
				var body := tanh(stack * am * w_drive[k])
				# Fast attack, full-level hold, release over the last quarter.
				var wenv := minf(u / 0.06, 1.0) * clampf((1.0 - u) / 0.25, 0.0, 1.0)
				var wv := body * wenv * 0.055
				sl += wv * (1.0 - w_pan[k])
				sr += wv * w_pan[k]
			# Overall lowpass (~3 kHz, two poles) — softens the tanh edge and
			# pushes the screams back into the bed, like hearing them across
			# the arena instead of next to the mic.
			out_lp.x += (sl - out_lp.x) * 0.55
			out_lp.y += (sr - out_lp.y) * 0.55
			out_lp2 += (out_lp - out_lp2) * 0.55
			out[i] = out_lp2
			i += 1
		await get_tree().process_frame
	return out


# Collective "ooh" — low soft formant swell for a nasty-looking hit.
func _synth_ooh(seconds: float) -> PackedVector2Array:
	var n := int(seconds * RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 54004
	var f1l := Vector2.ZERO
	var f1r := Vector2.ZERO
	var r1 := exp(-PI * 110.0 / RATE)
	var r1sq := r1 * r1
	var c1 := 0.0
	var i := 0
	while i < n:
		var stop := mini(i + CHUNK, n)
		while i < stop:
			var t := float(i) / RATE
			if i % 64 == 0:
				# "ooh" formant — low, sliding down as the breath runs out.
				var f1 := 380.0 * (1.0 - 0.18 * (t / seconds))
				c1 = 2.0 * r1 * cos(TAU * f1 / RATE)
			var u := t / seconds
			var env := pow(sin(PI * clampf(u, 0.0, 1.0)), 1.4)
			var wl := rng.randf_range(-1.0, 1.0)
			var wr := rng.randf_range(-1.0, 1.0)
			var y1l := wl + c1 * f1l.x - r1sq * f1l.y
			f1l = Vector2(y1l, f1l.x)
			var y1r := wr + c1 * f1r.x - r1sq * f1r.y
			f1r = Vector2(y1r, f1r.x)
			out[i] = Vector2(y1l, y1r) * 0.03 * env
			i += 1
		await get_tree().process_frame
	return out
