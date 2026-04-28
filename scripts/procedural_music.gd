extends Node

# Realtime procedural music engine: no samples, no generated WAV assets.
# Streams a 4/4, 16th-note acid/synth/percussion loop into an
# AudioStreamGenerator and crossfades four gameplay energy levels.

const MIX_RATE := 44100.0
const TWO_PI := TAU

var enabled: bool = true
var music_db: float = -16.0
var bpm: float = 154.0

var _player: AudioStreamPlayer = null
var _playback: AudioStreamGeneratorPlayback = null
var _target_energy: float = 0.0
var _energy: float = 0.0
var _pending_energy: int = -1
var _song_pos_steps: float = 0.0
var _last_step: int = -1
var _bar: int = 0

var _acid_phase: float = 0.0
var _acid_sub_phase: float = 0.0
var _pad_phase_a: float = 0.0
var _pad_phase_b: float = 0.19
var _pad_phase_c: float = 0.41
var _bass_phase: float = 0.0
var _answer_bass_phase: float = 0.0
var _kick_phase: float = 0.0
var _snare_tone_phase: float = 0.0

var _acid_env: float = 0.0
var _acid_slide: float = 0.0
var _acid_filter: float = 0.0
var _acid_lp_l: float = 0.0
var _acid_lp_r: float = 0.0
var _acid_res_l: float = 0.0
var _acid_res_r: float = 0.0
var _pad_lp_l: float = 0.0
var _pad_lp_r: float = 0.0
var _bass_lp: float = 0.0
var _answer_bass_lp: float = 0.0
var _answer_bass_body: float = 0.0
var _answer_formant_lp1: float = 0.0
var _answer_formant_lp2: float = 0.0
var _answer_formant_lp3: float = 0.0
var _answer_formant_lp4: float = 0.0
var _synth_mud_l: float = 0.0
var _synth_mud_r: float = 0.0
var _master_side_low: float = 0.0
var _glitch_buf: PackedVector2Array = PackedVector2Array()
var _glitch_idx: int = 0
var _noise_buf: PackedFloat32Array = PackedFloat32Array()
var _noise_idx: int = 0
var _tier1_frame: Vector2 = Vector2.ZERO
var _tier3_frame: Vector2 = Vector2.ZERO
var _kick_frame: Vector2 = Vector2.ZERO
var _snare_frame: Vector2 = Vector2.ZERO
var _hat_frame: Vector2 = Vector2.ZERO
var _perc_frame: Vector2 = Vector2.ZERO
var _tier2_width_duck: float = 0.0

var _kick_env: float = 0.0
var _kick_click: float = 0.0
var _snare_env: float = 0.0
var _hat_env: float = 0.0
var _perc_env: float = 0.0
var _fill_env: float = 0.0
var _external_duck: float = 0.0

var _acid_note_hz: float = 110.0
var _acid_target_hz: float = 110.0
var _acid_filter_age: float = 999.0
var _acid_gate_time: float = 0.075
var _acid_note_gate_time: float = 0.075
var _acid_note_decay: float = 0.045
var _acid_note_release: float = 0.075
var _acid_note_q_boost: float = 0.0
var _acid_release_from: float = 0.0
var _acid_releasing: bool = false
var _acid_filter_env: float = 0.0
var _acid_filter_peak: float = 1.0
var _acid_accent_amount: float = 0.0
var _bass_hz: float = 55.0
var _answer_bass_hz: float = 55.0
var _answer_bass_target_hz: float = 55.0
var _answer_bass_env: float = 0.0
var _answer_formant_a: Vector2 = Vector2(400.0, 800.0)
var _answer_formant_b: Vector2 = Vector2(300.0, 2300.0)
var _answer_formant_mix: float = 0.0
var _answer_formant_target: float = 0.0
var _glitch_env: float = 0.0
var _noise_state: int = 0x1234abcd

var _acid_notes: Array[int] = []
var _answer_bass_notes: Array[int] = []
var _accents: Array[float] = []
var _answer_bass_accents: Array[float] = []
var _pad_notes: Array[int] = []
var _call_response: bool = false
var _fourth_bar_variant: bool = false
var _answer_bass_mask: int = 0
var _note_mask_l1: int = 0
var _note_mask_l2: int = 0
var _note_mask_l3: int = 0
var _note_mask_l4: int = 0
var _acid_long_mask: int = 0
var _kick_mask_l3: int = 0
var _kick_mask_l4: int = 0
var _snare_mask_l3: int = 0
var _snare_mask_l4: int = 0
var _slide_mask: int = 0

var _acid_drive: float = 1.8
var _acid_pre_drive: float = 2.2
var _acid_post_drive: float = 1.4
var _acid_asym: float = 0.08
var _acid_square_mix: float = 0.26
var _acid_sub_mix: float = 0.18
var _acid_filter_base: float = 0.035
var _acid_filter_sweep: float = 0.16
var _acid_filter_attack: float = 0.006
var _acid_filter_decay: float = 0.045
var _acid_filter_hold: float = 0.012
var _acid_filter_sustain: float = 0.28
var _acid_filter_release: float = 0.075
var _acid_resonance: float = 0.48
var _acid_long_gate_mult: float = 2.1
var _acid_long_decay_mult: float = 2.4
var _acid_long_release_mult: float = 1.6
var _acid_long_q_boost: float = 0.22
var _acid_long_sweep_boost: float = 0.25
var _variant_filter_lift: float = 0.0
var _acid_pan_offset: float = 0.012
var _pad_cutoff: float = 0.0045
var _pad_spread: float = 0.017
var _bass_drive: float = 1.9
var _answer_bass_drive: float = 2.0
var _answer_bass_cutoff: float = 0.025
var _answer_bass_decay: float = 0.99972
var _answer_bass_square_mix: float = 0.35
var _answer_bass_level: float = 0.42
var _answer_formant_amount: float = 0.38
var _answer_formant_q: float = 0.22
var _tier3_duck_depth: float = 0.74
var _drum_mud_cut_amount: float = 0.78
var _tier2_upward_amount: float = 0.42
var _width_punch_amount: float = 0.82
var _master_saturation: float = 1.25
var _master_clip_drive: float = 1.12
var _glitch_chance: float = 0.32
var _glitch_feedback: float = 0.42
var _kick_base_hz: float = 42.0
var _kick_drop_hz: float = 108.0
var _snare_tone_hz: float = 185.0
var _hat_level: float = 1.0
var _fill_transpose: Array[int] = [12, 7, 19]

var _mute_lead: bool = false
var _mute_answer: bool = false
var _mute_bass: bool = false
var _mute_pad: bool = false
var _mute_kick: bool = false
var _mute_snare: bool = false
var _mute_hats: bool = false
var _mute_perc: bool = false
var _mute_glitch: bool = false
var _solo_lead: bool = false
var _solo_answer: bool = false
var _solo_bass: bool = false
var _solo_pad: bool = false
var _solo_kick: bool = false
var _solo_snare: bool = false
var _solo_hats: bool = false
var _solo_perc: bool = false
var _solo_glitch: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_noise_buffer()
	generate_track(1, 0)
	_ensure_music_bus()
	_start_stream()
	set_process(true)


func _process(delta: float) -> void:
	if _player == null or _playback == null:
		return
	if BenchFlags.active:
		_target_energy = 0.0
		_energy = 0.0
		return
	if not enabled:
		_target_energy = 0.0
	_energy = move_toward(_energy, _target_energy, delta * 0.75)
	_external_duck = maxf(0.0, _external_duck - delta * 2.5)
	_fill_audio()


func set_energy(level: int, immediate: bool = false, next_bar: bool = false) -> void:
	var clamped := clampi(level, 0, 4)
	if next_bar and not immediate:
		_pending_energy = clamped
		return
	_pending_energy = -1
	_target_energy = float(clamped)
	if immediate:
		_energy = _target_energy
		if _player:
			_player.volume_db = music_db


func get_energy() -> int:
	return int(round(_target_energy))


func duck(amount: float = 0.75) -> void:
	_external_duck = maxf(_external_duck, clampf(amount, 0.0, 1.0))


func generate_track(seed: int, round_index: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed)
	var scales: Array = [
		[0, 3, 5, 7, 10, 12],
		[0, 2, 3, 7, 9, 10, 12],
		[0, 1, 3, 5, 7, 10, 12],
		[0, 3, 6, 7, 10, 12],
	]
	var roots: Array[int] = [33, 35, 36, 38, 40, 41, 43]
	var root: int = roots[rng.randi_range(0, roots.size() - 1)]
	var scale: Array = scales[rng.randi_range(0, scales.size() - 1)]
	_call_response = true
	_fourth_bar_variant = rng.randf() < 0.25
	_acid_notes.clear()
	_answer_bass_notes.clear()
	_accents.clear()
	_answer_bass_accents.clear()
	var degree := rng.randi_range(0, scale.size() - 2)
	for step in range(16):
		if step == 0 or step == 8:
			degree = 0
		elif step == 4 or step == 12:
			degree = rng.randi_range(2, scale.size() - 2)
		else:
			degree = clampi(degree + rng.randi_range(-2, 2), 0, scale.size() - 1)
		var octave := 12 if rng.randf() < 0.22 and step % 4 != 0 else 0
		_acid_notes.append(root + int(scale[degree]) + octave)
		var answer_degree := clampi(degree + rng.randi_range(-1, 1), 0, scale.size() - 1)
		var answer_midi := root + int(scale[answer_degree]) - 12
		if answer_midi < 29:
			answer_midi += 12
		_answer_bass_notes.append(answer_midi)
		var downbeat := step == 0 or step == 4 or step == 8 or step == 12
		_accents.append(rng.randf_range(0.65, 1.0) if downbeat else rng.randf_range(0.18, 0.9))
		_answer_bass_accents.append(rng.randf_range(0.7, 1.0) if step % 4 == 2 or step % 4 == 3 else rng.randf_range(0.25, 0.75))
	_pad_notes.clear()
	_pad_notes.append(root)
	_pad_notes.append(root + int(scale[min(2, scale.size() - 1)]))
	_pad_notes.append(root + int(scale[min(4, scale.size() - 1)]))
	_pad_notes.append(root + 12 + int(scale[rng.randi_range(1, scale.size() - 2)]))
	_note_mask_l1 = _mask_from_steps([0, 6, 10, 14])
	_note_mask_l2 = _note_mask_l1 | _mask_from_steps([2, 4, 7, 8, 12, 15])
	_note_mask_l3 = 0xffff & ~_mask_from_steps([rng.randi_range(1, 14), rng.randi_range(1, 14)])
	_note_mask_l4 = 0xffff
	if _call_response:
		var lead_keep := _mask_from_steps([0, 1, 4, 5, 8, 9, 12, 13])
		var lead_extra_choices: Array[int] = [1, 5, 9, 13]
		var lead_extra := _mask_from_steps([
			lead_extra_choices[rng.randi_range(0, lead_extra_choices.size() - 1)],
			lead_extra_choices[rng.randi_range(0, lead_extra_choices.size() - 1)],
		])
		_note_mask_l2 = (_note_mask_l2 & lead_keep) | lead_extra
		_note_mask_l3 = _note_mask_l2
		_note_mask_l4 = (0xffff & lead_keep) | lead_extra | _mask_from_steps([14, 15])
		_answer_bass_mask = 0xffff & ~lead_keep
	else:
		_answer_bass_mask = _mask_from_steps([2, 6, 10, 14])
	_slide_mask = _mask_from_steps([3, 7, 14])
	for i in range(3):
		_slide_mask |= 1 << rng.randi_range(1, 15)
	_acid_long_mask = 0
	var long_candidates: Array[int] = [3, 6, 7, 10, 11, 14]
	var long_count := rng.randi_range(1, 2)
	if rng.randf() < 0.22:
		long_count += 1
	for i in range(long_count):
		_acid_long_mask |= 1 << long_candidates[rng.randi_range(0, long_candidates.size() - 1)]

	_kick_mask_l3 = _mask_from_steps([0, 4, 8, 12])
	var kick_variants: Array = [
		[0, 3, 6, 10, 12, 14],
		[0, 4, 7, 8, 11, 12, 15],
		[0, 3, 4, 8, 10, 12, 14],
		[0, 2, 6, 8, 12, 13],
	]
	_kick_mask_l4 = _mask_from_steps(kick_variants[rng.randi_range(0, kick_variants.size() - 1)])
	_snare_mask_l3 = _mask_from_steps([4, 12])
	_snare_mask_l4 = _mask_from_steps(([5, 12] if rng.randf() < 0.55 else [4, 11, 12]))
	_fill_transpose.clear()
	for interval in [[12, 7, 19], [7, 12, 15], [12, 15, 24], [3, 10, 15]][rng.randi_range(0, 3)]:
		_fill_transpose.append(int(interval))

	_acid_drive = rng.randf_range(1.35, 3.2)
	_acid_pre_drive = rng.randf_range(1.7, 4.2)
	_acid_post_drive = rng.randf_range(1.1, 2.1)
	_acid_asym = rng.randf_range(-0.16, 0.18)
	_acid_square_mix = rng.randf_range(0.12, 0.5)
	_acid_sub_mix = rng.randf_range(0.08, 0.32)
	_acid_filter_base = rng.randf_range(0.010, 0.045)
	_acid_filter_sweep = rng.randf_range(0.16, 0.42)
	_acid_filter_attack = rng.randf_range(0.0015, 0.009)
	_acid_filter_decay = rng.randf_range(0.045, 0.16)
	_acid_filter_hold = rng.randf_range(0.006, 0.035)
	_acid_filter_sustain = rng.randf_range(0.06, 0.32)
	_acid_filter_release = rng.randf_range(0.035, 0.13)
	_acid_gate_time = rng.randf_range(0.055, 0.13)
	_acid_resonance = rng.randf_range(0.52, 0.94)
	_acid_long_gate_mult = rng.randf_range(1.7, 3.0)
	_acid_long_decay_mult = rng.randf_range(1.8, 3.8)
	_acid_long_release_mult = rng.randf_range(1.25, 2.4)
	_acid_long_q_boost = rng.randf_range(0.16, 0.42)
	_acid_long_sweep_boost = rng.randf_range(0.16, 0.42)
	_variant_filter_lift = rng.randf_range(0.08, 0.22)
	_acid_pan_offset = rng.randf_range(0.006, 0.03)
	_pad_cutoff = rng.randf_range(0.0028, 0.008)
	_pad_spread = rng.randf_range(0.008, 0.04)
	_bass_drive = rng.randf_range(1.45, 2.8)
	_answer_bass_drive = rng.randf_range(1.7, 3.4)
	_answer_bass_cutoff = rng.randf_range(0.026, 0.078)
	_answer_bass_decay = rng.randf_range(0.99955, 0.99986)
	_answer_bass_square_mix = rng.randf_range(0.18, 0.62)
	_answer_bass_level = rng.randf_range(0.46, 0.74)
	_answer_formant_amount = rng.randf_range(0.22, 0.56)
	_answer_formant_q = rng.randf_range(0.12, 0.32)
	_tier3_duck_depth = rng.randf_range(0.62, 0.86)
	_drum_mud_cut_amount = rng.randf_range(0.55, 0.9)
	_tier2_upward_amount = rng.randf_range(0.28, 0.62)
	_width_punch_amount = rng.randf_range(0.65, 0.95)
	_master_saturation = rng.randf_range(1.05, 1.55)
	_master_clip_drive = rng.randf_range(1.02, 1.28)
	_glitch_chance = rng.randf_range(0.18, 0.48)
	_glitch_feedback = rng.randf_range(0.28, 0.56)
	_kick_base_hz = rng.randf_range(36.0, 52.0)
	_kick_drop_hz = rng.randf_range(82.0, 138.0)
	_snare_tone_hz = rng.randf_range(145.0, 245.0)
	_hat_level = rng.randf_range(0.65, 1.35)
	_noise_state = int(seed ^ 0x5eed1234)
	_reset_track_state()


func _reset_track_state() -> void:
	_song_pos_steps = 0.0
	_last_step = -1
	_bar = 0
	_acid_phase = 0.0
	_acid_sub_phase = 0.0
	_pad_phase_a = 0.0
	_pad_phase_b = 0.19
	_pad_phase_c = 0.41
	_bass_phase = 0.0
	_answer_bass_phase = 0.0
	_kick_phase = 0.0
	_snare_tone_phase = 0.0
	_acid_env = 0.0
	_acid_filter = 0.0
	_acid_lp_l = 0.0
	_acid_lp_r = 0.0
	_acid_res_l = 0.0
	_acid_res_r = 0.0
	_acid_filter_age = 999.0
	_acid_note_gate_time = _acid_gate_time
	_acid_note_decay = _acid_filter_decay
	_acid_note_release = _acid_filter_release
	_acid_note_q_boost = 0.0
	_acid_release_from = 0.0
	_acid_releasing = false
	_acid_filter_env = 0.0
	_acid_filter_peak = 1.0
	_acid_accent_amount = 0.0
	_pad_lp_l = 0.0
	_pad_lp_r = 0.0
	_bass_lp = 0.0
	_answer_bass_lp = 0.0
	_answer_bass_body = 0.0
	_answer_formant_lp1 = 0.0
	_answer_formant_lp2 = 0.0
	_answer_formant_lp3 = 0.0
	_answer_formant_lp4 = 0.0
	_answer_bass_env = 0.0
	_synth_mud_l = 0.0
	_synth_mud_r = 0.0
	_master_side_low = 0.0
	_glitch_env = 0.0
	_tier1_frame = Vector2.ZERO
	_tier3_frame = Vector2.ZERO
	_tier2_width_duck = 0.0
	_answer_formant_mix = 0.0
	_answer_formant_target = 0.0
	_glitch_buf.resize(4096)
	for i in _glitch_buf.size():
		_glitch_buf[i] = Vector2.ZERO
	_glitch_idx = 0
	_kick_env = 0.0
	_snare_env = 0.0
	_hat_env = 0.0
	_perc_env = 0.0
	_fill_env = 0.0
	if not _acid_notes.is_empty():
		_acid_note_hz = _midi_to_hz(_acid_notes[0])
		_acid_target_hz = _acid_note_hz
		_bass_hz = _midi_to_hz(_acid_notes[0] - 12)
	if not _answer_bass_notes.is_empty():
		_answer_bass_hz = _midi_to_hz(_answer_bass_notes[0])
		_answer_bass_target_hz = _answer_bass_hz


func _ensure_music_bus() -> void:
	if AudioServer.get_bus_index("Music") >= 0:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "Music")
	AudioServer.set_bus_send(idx, "Master")
	var comp := AudioEffectCompressor.new()
	comp.threshold = -9.0
	comp.ratio = 4.0
	comp.attack_us = 2500.0
	comp.release_ms = 140.0
	comp.gain = 0.0
	AudioServer.add_bus_effect(idx, comp)
	var lim := AudioEffectLimiter.new()
	lim.threshold_db = -2.0
	lim.ceiling_db = -0.5
	lim.soft_clip_db = 1.5
	AudioServer.add_bus_effect(idx, lim)


func _start_stream() -> void:
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = MIX_RATE
	stream.buffer_length = 0.35
	_player = AudioStreamPlayer.new()
	_player.name = "ProceduralMusicPlayer"
	_player.stream = stream
	_player.bus = "Music"
	_player.volume_db = music_db
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback


func _fill_audio() -> void:
	var frames := _playback.get_frames_available()
	for i in frames:
		_playback.push_frame(_next_frame())


func _next_frame() -> Vector2:
	var dt := 1.0 / MIX_RATE
	_song_pos_steps += (bpm / 60.0 * 4.0) * dt
	var step_abs := int(floor(_song_pos_steps))
	if step_abs != _last_step:
		_last_step = step_abs
		_trigger_step(step_abs)

	var e1 := clampf(_energy, 0.0, 1.0)
	var e2 := clampf(_energy - 1.0, 0.0, 1.0)
	var e3 := clampf(_energy - 2.0, 0.0, 1.0)
	var e4 := clampf(_energy - 3.0, 0.0, 1.0)
	var variant_lift := _variant_bar_filter_lift()

	_acid_env *= 0.99935
	_acid_slide *= 0.99955
	_answer_bass_env *= _answer_bass_decay
	_kick_env *= 0.99815
	_kick_click *= 0.985
	_snare_env *= 0.9955
	_hat_env *= 0.988
	_perc_env *= 0.994
	_fill_env *= 0.996
	_glitch_env *= 0.9991
	_tier2_width_duck *= 0.965

	_acid_note_hz = lerpf(_acid_note_hz, _acid_target_hz, 0.012 + _acid_slide * 0.05)
	_answer_bass_hz = lerpf(_answer_bass_hz, _answer_bass_target_hz, 0.08)
	var acid := _acid_voice(dt, e1, e2, e4, variant_lift)
	var pad := _pad_voice(dt) * (0.38 + e1 * 0.32)
	var bass := _bass_voice(dt) * (0.12 + e2 * 0.22 + e3 * 0.16)
	var answer_bass := _answer_bass_voice(dt, e1, e2, e3, e4)
	_percussion_voice(dt, e2, e3, e4)
	var solo_active := _has_channel_solo()
	var source_solo_active := _has_source_channel_solo()
	acid *= _channel_gain(_mute_lead, _solo_lead, source_solo_active)
	answer_bass *= _channel_gain(_mute_answer, _solo_answer, source_solo_active)
	bass *= _channel_gain(_mute_bass, _solo_bass, source_solo_active)
	pad *= _channel_gain(_mute_pad, _solo_pad, source_solo_active)
	_kick_frame *= _channel_gain(_mute_kick, _solo_kick, source_solo_active)
	_snare_frame *= _channel_gain(_mute_snare, _solo_snare, source_solo_active)
	_hat_frame *= _channel_gain(_mute_hats, _solo_hats, source_solo_active)
	_perc_frame *= _channel_gain(_mute_perc, _solo_perc, source_solo_active)
	_tier1_frame = _kick_frame + _snare_frame
	_tier3_frame = _hat_frame + _perc_frame

	var pump := maxf(_kick_env * (0.62 + e4 * 0.12), _snare_env * 0.28)
	pump = maxf(pump, _external_duck)
	var tier1_activity := maxf(absf(_tier1_frame.x), absf(_tier1_frame.y))
	var tier3_gain := 1.0 - clampf((tier1_activity - 0.03) * 3.2, 0.0, _tier3_duck_depth)
	var synth_gain := clampf(1.0 - pump, 0.22, 1.0)
	var tier2 := _dynamic_width(_upward_compress_tier2(acid + answer_bass + bass * 0.55))
	var tier3 := (pad + bass * 0.45 + _tier3_frame) * tier3_gain
	var synth := _transient_mud_scoop((tier2 + tier3) * synth_gain, maxf(tier1_activity, pump))
	var glitch_gain := _channel_gain(_mute_glitch, _solo_glitch, solo_active)
	if glitch_gain > 0.0:
		synth = _apply_glitch(synth, _solo_glitch)
	return _master_process(_tier1_frame + synth)


func _trigger_step(step_abs: int) -> void:
	var step := step_abs % 16
	if step == 0:
		_bar += 1
		if _pending_energy >= 0:
			_target_energy = float(_pending_energy)
			_pending_energy = -1
	var e := int(round(_target_energy))
	var accent: float = _accents[step]
	if _note_on(step, e):
		var midi: int = _acid_notes[step]
		if _fourth_bar_ending_step(step):
			midi = _variant_lead_note(step, midi, e)
		if e >= 4 and (_bar % 4 == 3) and (step == 13 or step == 14 or step == 15):
			midi += _fill_transpose[step - 13]
			_fill_env = maxf(_fill_env, 1.0)
		_acid_target_hz = _midi_to_hz(midi)
		var lead_energy: int = mini(e, 2)
		var long_squelch := e >= 2 and _step_in_mask(step, _acid_long_mask)
		var long_amount := 1.0 if long_squelch else 0.0
		_acid_env = maxf(_acid_env, 0.28 + accent * (0.65 + float(lead_energy) * 0.06) + long_amount * 0.12)
		_acid_accent_amount = accent
		_acid_note_gate_time = _acid_gate_time * (lerpf(1.0, _acid_long_gate_mult, long_amount))
		_acid_note_decay = _acid_filter_decay * (lerpf(1.0, _acid_long_decay_mult, long_amount))
		_acid_note_release = _acid_filter_release * (lerpf(1.0, _acid_long_release_mult, long_amount))
		_acid_note_q_boost = _acid_long_q_boost * long_amount
		_acid_filter = 0.55 + accent * 0.9 + long_amount * _acid_long_sweep_boost + (_variant_filter_lift * 2.2 if _fourth_bar_ending_step(step) else 0.0)
		_acid_filter_peak = _acid_filter
		_acid_filter_env = 0.0
		_acid_filter_age = 0.0
		_acid_release_from = 0.0
		_acid_releasing = false
		_acid_slide = 1.0 if (_step_in_mask(step, _slide_mask) or long_squelch) else 0.35
	if _answer_bass_on(step, e):
		var bass_midi: int = _answer_bass_notes[step]
		if _fourth_bar_ending_step(step):
			bass_midi += 12 if step >= 14 else 7
		if e >= 4 and _bar % 4 == 1 and (step == 11 or step == 15):
			bass_midi += 12
		_answer_bass_target_hz = _midi_to_hz(bass_midi)
		var full_energy := clampf(float(e - 3), 0.0, 1.0)
		_answer_bass_env = maxf(_answer_bass_env, 0.68 + _answer_bass_accents[step] * (0.44 + full_energy * 0.18))
	if step == 0 or step == 8:
		_bass_hz = _midi_to_hz(_acid_notes[step] - 12)
	if e >= 2 and step % 2 == 1:
		_hat_env = maxf(_hat_env, 0.12 + 0.14 * float(e - 1))
	if e >= 2 and (step == 2 or step == 6 or step == 10 or step == 14):
		_perc_env = maxf(_perc_env, 0.28)
	if e >= 3 and _kick_step(step, e):
		_kick_env = 1.0
		_kick_click = 1.0
		_kick_phase = 0.0
		_tier2_width_duck = maxf(_tier2_width_duck, _width_punch_amount)
		_glitch_env = maxf(_glitch_env, 0.14 if _should_glitch(step) else _glitch_env)
	if e >= 3 and _snare_step(step, e):
		_snare_env = 1.0
		_snare_tone_phase = 0.0
		_hat_env = maxf(_hat_env, 0.45)
		_tier2_width_duck = maxf(_tier2_width_duck, _width_punch_amount)
		_glitch_env = maxf(_glitch_env, 0.18 if _should_glitch(step) else _glitch_env)


func _note_on(step: int, energy_level: int) -> bool:
	if _fourth_bar_ending_step(step) and energy_level >= 2:
		return step >= 12
	if energy_level <= 1:
		return _step_in_mask(step, _note_mask_l1)
	if energy_level == 2:
		return _step_in_mask(step, _note_mask_l2)
	if energy_level == 3:
		return _step_in_mask(step, _note_mask_l2)
	return _step_in_mask(step, _note_mask_l4)


func _answer_bass_on(step: int, energy_level: int) -> bool:
	if energy_level <= 1:
		return false
	if _fourth_bar_ending_step(step) and energy_level >= 2:
		return step == 13 or step == 15
	if _call_response:
		return _step_in_mask(step, _answer_bass_mask)
	if energy_level == 2:
		return step == 10 or step == 14
	if energy_level == 3:
		return step == 2 or step == 6 or step == 10 or step == 14
	return _step_in_mask(step, _answer_bass_mask) or step == 3 or step == 7 or step == 11 or step == 15


func _fourth_bar_ending_step(step: int) -> bool:
	return _fourth_bar_variant and (_bar % 4 == 0) and step >= 10


func _variant_bar_filter_lift() -> float:
	if not _fourth_bar_variant or _bar % 4 != 0:
		return 0.0
	var step_pos := fposmod(_song_pos_steps, 16.0)
	if step_pos < 8.0:
		return 0.0
	var t := clampf((step_pos - 8.0) / 8.0, 0.0, 1.0)
	return _variant_filter_lift * t * t


func _variant_lead_note(step: int, base_midi: int, energy_level: int) -> int:
	if energy_level <= 1:
		return base_midi
	if step == 10 or step == 11:
		return base_midi + 7
	if step == 12 or step == 13:
		return base_midi + (12 if energy_level >= 4 else 5)
	return base_midi + (19 if energy_level >= 4 else 12)


func _kick_step(step: int, energy_level: int) -> bool:
	if energy_level < 4:
		return _step_in_mask(step, _kick_mask_l3)
	return _step_in_mask(step, _kick_mask_l4)


func _snare_step(step: int, energy_level: int) -> bool:
	if energy_level < 4:
		return _step_in_mask(step, _snare_mask_l3)
	return _step_in_mask(step, _snare_mask_l4)


func _acid_voice(dt: float, e1: float, e2: float, e4: float, variant_lift: float) -> Vector2:
	var filter_env := _acid_filter_adhsr(dt)
	var cutoff := clampf(_acid_filter_base + variant_lift + filter_env * (_acid_filter_sweep + e2 * 0.16 + e4 * 0.18 + variant_lift * 0.9), 0.006, 0.88)
	var freq := _acid_note_hz * (1.0 + _fill_env * 0.015)
	_acid_phase = _wrap01(_acid_phase + freq * dt)
	_acid_sub_phase = _wrap01(_acid_sub_phase + freq * 0.5 * dt)
	var saw := _saw(_acid_phase)
	var sq := 1.0 if _acid_phase < 0.52 else -1.0
	var sub := _saw(_acid_sub_phase)
	var raw := saw * 0.68 + sq * _acid_square_mix + sub * _acid_sub_mix
	raw = _distort_acid(raw, _acid_pre_drive + e2 * 1.2 + e4 * 1.1)
	var right_raw := raw * 0.96 + _saw(_wrap01(_acid_phase + _acid_pan_offset)) * 0.04
	var q := clampf(_acid_resonance + _acid_accent_amount * 0.18 + _acid_slide * 0.08 + _acid_note_q_boost * filter_env, 0.0, 1.32)
	var filtered_l := _acid_resonant_lp_l(raw, cutoff, q)
	var filtered_r := _acid_resonant_lp_r(right_raw, cutoff * 0.92, q * 0.94)
	var q_drive := maxf(0.0, q - 0.78) * 1.8
	filtered_l = _distort_acid(filtered_l, _acid_post_drive + e4 * 0.55 + q_drive)
	filtered_r = _distort_acid(filtered_r, _acid_post_drive + e4 * 0.55 + q_drive)
	var amp := _acid_env * (0.12 + e1 * 0.12 + e2 * 0.13 + e4 * 0.09)
	return Vector2(filtered_l, filtered_r) * amp


func _acid_filter_adhsr(dt: float) -> float:
	_acid_filter_age += dt
	if not _acid_releasing and _acid_filter_age >= _acid_note_gate_time:
		_acid_release_from = _acid_filter_env
		_acid_filter_age = 0.0
		_acid_releasing = true
	if _acid_releasing:
		var rel_t := clampf(_acid_filter_age / maxf(0.001, _acid_note_release), 0.0, 1.0)
		var release_curve := pow(1.0 - rel_t, 2.2)
		_acid_filter_env = _acid_release_from * release_curve
		return _acid_filter_env
	_acid_filter_env = _acid_filter_peak * _acid_filter_adhsr_value(_acid_filter_age)
	return _acid_filter_env


func _acid_filter_adhsr_value(t: float) -> float:
	if t < _acid_filter_attack:
		var a := t / maxf(0.001, _acid_filter_attack)
		return 1.0 - pow(1.0 - a, 3.0)
	t -= _acid_filter_attack
	if t < _acid_filter_hold:
		return 1.0
	t -= _acid_filter_hold
	if t < _acid_note_decay:
		var d := t / maxf(0.001, _acid_note_decay)
		var curved := 1.0 - pow(1.0 - d, 0.42)
		return lerpf(1.0, _acid_filter_sustain, curved)
	return _acid_filter_sustain


func _acid_resonant_lp_l(input: float, cutoff: float, resonance: float) -> float:
	var peak := (_acid_lp_l - _acid_res_l) * resonance
	_acid_lp_l += (input - _acid_lp_l + peak) * cutoff
	_acid_res_l += (_acid_lp_l - _acid_res_l) * cutoff
	return clampf(_acid_res_l, -1.8, 1.8)


func _acid_resonant_lp_r(input: float, cutoff: float, resonance: float) -> float:
	var peak := (_acid_lp_r - _acid_res_r) * resonance
	_acid_lp_r += (input - _acid_lp_r + peak) * cutoff
	_acid_res_r += (_acid_lp_r - _acid_res_r) * cutoff
	return clampf(_acid_res_r, -1.8, 1.8)


func _distort_acid(v: float, drive: float) -> float:
	var biased := v + _acid_asym
	var half_a := tanh(biased * drive)
	var half_b := tanh((biased + half_a * 0.04) * drive)
	var clipped := (half_a + half_b) * 0.5
	var folded := clipped - 0.14 * sin(clipped * PI * 2.0)
	return clampf(folded - tanh(_acid_asym * drive) * 0.35, -1.0, 1.0)


func _pad_voice(dt: float) -> Vector2:
	var f0 := _midi_to_hz(_pad_notes[0])
	var f1 := _midi_to_hz(_pad_notes[1])
	var f2 := _midi_to_hz(_pad_notes[2])
	_pad_phase_a = _wrap01(_pad_phase_a + f0 * dt)
	_pad_phase_b = _wrap01(_pad_phase_b + f1 * 0.997 * dt)
	_pad_phase_c = _wrap01(_pad_phase_c + f2 * 1.003 * dt)
	var raw_l := _saw(_pad_phase_a) * 0.34 + _saw(_pad_phase_b) * 0.28 + _tri(_pad_phase_c) * 0.24
	var raw_r := _saw(_wrap01(_pad_phase_a + _pad_spread)) * 0.26 + _tri(_pad_phase_b) * 0.32 + _saw(_wrap01(_pad_phase_c + _pad_spread * 1.8)) * 0.28
	_pad_lp_l += (raw_l - _pad_lp_l) * _pad_cutoff
	_pad_lp_r += (raw_r - _pad_lp_r) * (_pad_cutoff * 0.9)
	return Vector2(_pad_lp_l, _pad_lp_r) * 0.42


func _bass_voice(dt: float) -> Vector2:
	_bass_phase = _wrap01(_bass_phase + _bass_hz * dt)
	var raw := _saw(_bass_phase) * 0.7 + (1.0 if _bass_phase < 0.5 else -1.0) * 0.3
	_bass_lp += (raw - _bass_lp) * 0.025
	var v := _soft_clip(_bass_lp * _bass_drive) * 0.32
	return Vector2(v, v)


func _answer_bass_voice(dt: float, e1: float, e2: float, e3: float, e4: float) -> Vector2:
	if _answer_bass_env < 0.001:
		return Vector2.ZERO
	_answer_bass_phase = _wrap01(_answer_bass_phase + _answer_bass_hz * dt)
	var saw := _saw(_answer_bass_phase)
	var pulse := 1.0 if _answer_bass_phase < 0.38 else -1.0
	var sub := sin(_answer_bass_phase * TWO_PI)
	var raw := saw * 0.50 + pulse * _answer_bass_square_mix + sub * 0.34
	raw = tanh(raw * (_answer_bass_drive + e3 * 0.35 + e4 * 0.5))
	raw += _answer_formants(raw) * _answer_formant_amount
	var cutoff := _answer_bass_cutoff + _answer_bass_env * (0.035 + e4 * 0.028)
	_answer_bass_lp += (raw - _answer_bass_lp) * clampf(cutoff, 0.014, 0.18)
	_answer_bass_body += (_answer_bass_lp - _answer_bass_body) * 0.022
	var click := raw - _answer_bass_lp
	var crush := 1.0 + _answer_bass_env * 3.2
	var crushed: float = floor((_answer_bass_body * 0.92 + click * 0.08) * crush) / crush
	var v: float = tanh(crushed * 2.05)
	var level := _answer_bass_env * _answer_bass_level * (0.32 + e1 * 0.14 + e2 * 0.30 + e3 * 0.18 + e4 * 0.14)
	return Vector2(v * 0.94, v) * level


func _answer_formants(input: float) -> float:
	var sin_val := sin(float(_bar) * 1.7 + fposmod(_song_pos_steps, 16.0) * 0.85)
	_answer_formant_target = 1.0 if sin_val > 0.2 else 0.0
	_answer_formant_mix = lerpf(_answer_formant_mix, _answer_formant_target, 0.09)
	var f1 := lerpf(_answer_formant_a.x, _answer_formant_b.x, _answer_formant_mix)
	var f2 := lerpf(_answer_formant_a.y, _answer_formant_b.y, _answer_formant_mix)
	var peak1 := _band_between(input, f1 * 0.72, f1 * 1.22, true)
	var peak2 := _band_between(input, f2 * 0.82, f2 * 1.12, false)
	return (peak1 + peak2 * 0.8) * (1.0 + _answer_formant_q)


func _band_between(input: float, low_hz: float, high_hz: float, first: bool) -> float:
	var low_coef := _hz_to_coef(low_hz)
	var high_coef := _hz_to_coef(high_hz)
	if first:
		_answer_formant_lp1 += (input - _answer_formant_lp1) * high_coef
		_answer_formant_lp2 += (input - _answer_formant_lp2) * low_coef
		return _answer_formant_lp1 - _answer_formant_lp2
	_answer_formant_lp3 += (input - _answer_formant_lp3) * high_coef
	_answer_formant_lp4 += (input - _answer_formant_lp4) * low_coef
	return _answer_formant_lp3 - _answer_formant_lp4


func _percussion_voice(dt: float, e2: float, e3: float, e4: float) -> Vector2:
	var kick_freq := _kick_base_hz + _kick_drop_hz * _kick_env * _kick_env
	_kick_phase += TWO_PI * kick_freq * dt
	var kick := sin(_kick_phase) * _kick_env
	kick += _noise() * _kick_click * 0.08
	kick = _soft_clip(kick * (2.5 + e4 * 0.8)) * 0.55 * e3

	_snare_tone_phase += TWO_PI * _snare_tone_hz * dt
	var snare_noise := _noise() * _snare_env
	var snare_body := sin(_snare_tone_phase) * _snare_env * 0.32
	var snare := _soft_clip((snare_noise * 0.75 + snare_body) * 1.8) * 0.30 * e3

	var hat := (_noise() - _noise() * 0.55) * _hat_env * _hat_level * (0.15 + e2 * 0.15 + e4 * 0.08)
	var perc := sin(_kick_phase * 2.7) * _perc_env * 0.08 * e2
	_kick_frame = Vector2(kick, kick)
	_snare_frame = Vector2(snare * 0.88, snare)
	_hat_frame = Vector2(hat * 0.72, hat)
	_perc_frame = Vector2(perc, perc * 0.65)
	_tier1_frame = _kick_frame + _snare_frame
	_tier3_frame = _hat_frame + _perc_frame
	return _tier1_frame + _tier3_frame


func _has_channel_solo() -> bool:
	return _has_source_channel_solo() or _solo_glitch


func _has_source_channel_solo() -> bool:
	return (
		_solo_lead
		or _solo_answer
		or _solo_bass
		or _solo_pad
		or _solo_kick
		or _solo_snare
		or _solo_hats
		or _solo_perc
	)


func _channel_gain(muted: bool, soloed: bool, solo_active: bool) -> float:
	if muted:
		return 0.0
	if solo_active and not soloed:
		return 0.0
	return 1.0


func _upward_compress_tier2(input: Vector2) -> Vector2:
	var mag := maxf(absf(input.x), absf(input.y))
	var threshold := 0.18
	if mag >= threshold or mag <= 0.0001:
		return input
	var lift := (threshold - mag) / threshold
	var gain := 1.0 + lift * _tier2_upward_amount * 2.4
	return input * gain


func _dynamic_width(input: Vector2) -> Vector2:
	if _tier2_width_duck <= 0.001:
		return input
	var mid := (input.x + input.y) * 0.5
	var side := (input.x - input.y) * 0.5
	var width := 1.0 - clampf(_tier2_width_duck, 0.0, 1.0)
	return Vector2(mid + side * width, mid - side * width)


func _transient_mud_scoop(synth: Vector2, activity: float) -> Vector2:
	var gate := clampf((activity - 0.03) * 3.0, 0.0, 1.0) * _drum_mud_cut_amount
	var low_coef := _hz_to_coef(200.0)
	var high_coef := _hz_to_coef(500.0)
	var low_l := _synth_mud_l
	var low_r := _synth_mud_r
	_synth_mud_l += (synth.x - _synth_mud_l) * low_coef
	_synth_mud_r += (synth.y - _synth_mud_r) * low_coef
	var high_l := low_l + (synth.x - low_l) * high_coef
	var high_r := low_r + (synth.y - low_r) * high_coef
	var mud := Vector2(high_l - _synth_mud_l, high_r - _synth_mud_r)
	return synth - mud * gate


func _apply_glitch(input: Vector2, wet_only: bool = false) -> Vector2:
	if _glitch_buf.is_empty():
		return Vector2.ZERO if wet_only else input
	var delayed := _glitch_buf[_glitch_idx]
	var send := input + delayed * (_glitch_feedback * _glitch_env)
	_glitch_buf[_glitch_idx] = send
	_glitch_idx = (_glitch_idx + 1) % _glitch_buf.size()
	var wet := delayed * _glitch_env * 0.35
	return wet if wet_only else input + wet


func _master_process(input: Vector2) -> Vector2:
	var sat_l := (tanh(input.x * _master_saturation) + tanh((input.x * 0.96) * _master_saturation)) * 0.5
	var sat_r := (tanh(input.y * _master_saturation) + tanh((input.y * 0.96) * _master_saturation)) * 0.5
	var saturated := Vector2(sat_l, sat_r)
	var mid := (saturated.x + saturated.y) * 0.5
	var side := (saturated.x - saturated.y) * 0.5
	_master_side_low += (side - _master_side_low) * _hz_to_coef(120.0)
	side -= _master_side_low
	var l := mid + side
	var r := mid - side
	return Vector2(_soft_clip(l * _master_clip_drive), _soft_clip(r * _master_clip_drive))


func _should_glitch(step: int) -> bool:
	if step < 12 or _bar % 8 != 0:
		return false
	var roll := absf(sin(float(_bar * 37 + step * 17) * 12.9898)) 
	return roll < _glitch_chance


func _hz_to_coef(hz: float) -> float:
	return clampf(1.0 - exp(-TWO_PI * hz / MIX_RATE), 0.0001, 0.95)


func _build_noise_buffer() -> void:
	_noise_buf.resize(44100)
	var state := 0x1234abcd
	for i in _noise_buf.size():
		state = int((state * 1664525 + 1013904223) & 0x7fffffff)
		_noise_buf[i] = (float(state) / 1073741824.0) - 1.0


func _midi_to_hz(midi: int) -> float:
	return 440.0 * pow(2.0, (float(midi) - 69.0) / 12.0)


func _wrap01(v: float) -> float:
	return v - floor(v)


func _mask_from_steps(steps: Array) -> int:
	var mask := 0
	for raw_step in steps:
		var step := clampi(int(raw_step), 0, 15)
		mask |= 1 << step
	return mask


func _step_in_mask(step: int, mask: int) -> bool:
	return (mask & (1 << step)) != 0


func _saw(p: float) -> float:
	return p * 2.0 - 1.0


func _tri(p: float) -> float:
	return 1.0 - absf(p * 2.0 - 1.0) * 2.0


func _soft_clip(v: float) -> float:
	return tanh(v)


func _noise() -> float:
	if _noise_buf.is_empty():
		return 0.0
	var v := _noise_buf[_noise_idx]
	_noise_idx = (_noise_idx + 1) % _noise_buf.size()
	return v
