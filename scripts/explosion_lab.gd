extends Node3D

# Explosion lab + benchmark: see/hear explosions in isolation, tune them live,
# toggle individual FX layers on/off, and stress-test (N explosions/sec) with a
# live performance HUD — so we can measure the real cost of each layer and
# iterate (MultiMesh, pre-baked anims, etc.).
#
# Run: godot --path . res://scenes/explosion_lab.tscn  (or set as main scene).
#
# Controls: SPACE = boom · RMB = mouse look · WASD/QE = move · Shift = sprint.
# Time scale only slows the visuals; audio always plays at normal pitch.

const ARENA_SCENE := preload("res://scenes/arena_procedural.tscn")
const ION_CANNON := preload("res://scripts/ion_cannon.gd")
const ARENA_SEED := 7

const MOVE_SPEED := 8.0
const FAST_MULT := 4.0
const MOUSE_SENS := 0.0025
const BLAST_PAD := Vector3(0.0, 2.0, 0.0)
const WARM_COLOR := Color(1.0, 0.9, 0.32)
const ION_COLOR := Color(0.38, 0.78, 1.0)

const TYPE_BULLET := 0
const TYPE_ION := 1
const MAX_BOOMS_PER_FRAME := 24   # stress-spawn clamp so a stall can't spiral

var state: int = 1
var local_player: Node = null

var _camera: Camera3D
var _yaw: float = 0.0
var _pitch: float = -0.18

var _radius: float = 8.0
var _repeat_interval: float = 0.0
var _blast_type: int = TYPE_BULLET
var _repeat_accum: float = 0.0

# Stress test
var _stress_rate: float = 0.0   # explosions/sec
var _stress_accum: float = 0.0
var _booms_this_second: int = 0
var _boom_rate_accum: float = 0.0
var _booms_last_second: int = 0

# Per-layer toggles (which sub-effects each boom spawns)
var _fx := {
	"heat": true,
	"shock": true,
	"lights": true,
	"fireball": true,
	"smoke": true,
	"fire_clouds": true,
	"shards": true,
	"embers": true,
}

var _perf_labels := {}
var _perf_accum: float = 0.0

# Automated sweep (run with `--benchmark`): cycles through stress rates, samples
# steady-state perf for each, prints a table, then quits.
var _bench := false
var _bench_rates := [0.0, 20.0, 50.0, 100.0, 200.0, 400.0]
var _bench_stage := 0
var _bench_t := 0.0
const _BENCH_WARM := 2.0     # let each rate reach steady state
const _BENCH_SAMPLE := 2.0   # then average over this window
var _bs_fps := 0.0
var _bs_frame := 0.0
var _bs_cpu := 0.0
var _bs_draw := 0.0
var _bs_nodes := 0.0
var _bs_n := 0

func _ready() -> void:
	_build_arena()
	_build_camera()
	_build_ui()
	_build_perf_hud()
	_warmup()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if "--benchmark" in OS.get_cmdline_args() or "--benchmark" in OS.get_cmdline_user_args():
		_bench = true
		_radius = 10.0
		_stress_rate = _bench_rates[0]
		print("[exlab] benchmark sweep starting (radius=%.0f)" % _radius)

func _exit_tree() -> void:
	Engine.time_scale = 1.0

func _warmup() -> void:
	Violence.warmup_blast_materials(self)
	preload("res://scripts/grenade.gd").warmup_shaders(self)
	ION_CANNON.warmup_shaders(self)
	SFX.warmup_specials()

# -------------------- scene --------------------

func _build_arena() -> void:
	var arena: Node = ARENA_SCENE.instantiate()
	arena.name = "Arena"
	add_child(arena)
	if arena.has_method("apply_seed"):
		arena.apply_seed(ARENA_SEED)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.rotation = Vector3(_pitch, _yaw, 0)
	add_child(_camera)
	_camera.global_position = Vector3(0, 5, 16)
	_camera.make_current()
	var listener := RaytracedAudioListener.new()
	_camera.add_child(listener)
	listener.owner = _camera

# -------------------- input / camera --------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_boom()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -1.4, 1.4)
		_camera.rotation = Vector3(_pitch, _yaw, 0)

func _process(delta: float) -> void:
	if _camera == null:
		return
	if not _camera.current:
		_camera.make_current()
	var rt_delta: float = delta / maxf(Engine.time_scale, 0.0001)
	var dir := Vector3.ZERO
	var b := _camera.global_transform.basis
	if Input.is_key_pressed(KEY_W): dir -= b.z
	if Input.is_key_pressed(KEY_S): dir += b.z
	if Input.is_key_pressed(KEY_A): dir -= b.x
	if Input.is_key_pressed(KEY_D): dir += b.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir -= Vector3.UP
	if dir != Vector3.ZERO:
		var speed := MOVE_SPEED * (FAST_MULT if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		_camera.global_position += dir.normalized() * speed * rt_delta
	if _repeat_interval > 0.0:
		_repeat_accum += rt_delta
		if _repeat_accum >= _repeat_interval:
			_repeat_accum = 0.0
			_boom()
	if _stress_rate > 0.0:
		_stress_accum += rt_delta * _stress_rate
		var n := 0
		while _stress_accum >= 1.0 and n < MAX_BOOMS_PER_FRAME:
			_stress_accum -= 1.0
			_boom()
			n += 1
		if _stress_accum > MAX_BOOMS_PER_FRAME:
			_stress_accum = 0.0   # shed backlog instead of spiralling
	# measured boom rate
	_boom_rate_accum += rt_delta
	if _boom_rate_accum >= 1.0:
		_boom_rate_accum -= 1.0
		_booms_last_second = _booms_this_second
		_booms_this_second = 0
	# perf HUD refresh (4x/sec)
	_perf_accum += delta
	if _perf_accum >= 0.25:
		_perf_accum = 0.0
		_update_perf()
	if _bench:
		_bench_tick(delta)

func _bench_tick(delta: float) -> void:
	_bench_t += delta
	if _bench_t >= _BENCH_WARM:
		_bs_fps += Engine.get_frames_per_second()
		_bs_frame += 1000.0 / maxf(Engine.get_frames_per_second(), 1.0)
		_bs_cpu += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		_bs_draw += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		_bs_nodes += Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
		_bs_n += 1
	if _bench_t >= _BENCH_WARM + _BENCH_SAMPLE:
		var n := maxf(_bs_n, 1)
		print("[exlab] rate=%4.0f/s  fps=%5.1f  frame=%5.2fms  cpu=%5.2fms  draws=%6.0f  nodes=%6.0f" % [
			_bench_rates[_bench_stage], _bs_fps / n, _bs_frame / n, _bs_cpu / n, _bs_draw / n, _bs_nodes / n])
		_bench_stage += 1
		_bench_t = 0.0
		_bs_fps = 0.0; _bs_frame = 0.0; _bs_cpu = 0.0; _bs_draw = 0.0; _bs_nodes = 0.0; _bs_n = 0
		if _bench_stage >= _bench_rates.size():
			print("[exlab] benchmark done")
			get_tree().quit()
		else:
			_stress_rate = _bench_rates[_bench_stage]

# -------------------- explosions --------------------

func _boom() -> void:
	_booms_this_second += 1
	var pos := BLAST_PAD
	if _stress_rate > 0.0:
		# Spread stress booms a little so they're not all one pixel-stack.
		pos += Vector3(randf_range(-1.0, 1.0), randf_range(0.0, 0.6), randf_range(-1.0, 1.0)) * _radius
	if _blast_type == TYPE_ION:
		SFX.ion_cannon_detonate(pos, _radius)
		var ion: Node = ION_CANNON.new()
		ion.set_process(false)   # don't run its charge state machine
		add_child(ion)
		ion._spawn_ion_detonation_fx(self, pos, _radius)
		ion.queue_free()
		return
	# Bullet blast, built layer by layer so each can be toggled. Calls the layer
	# spawners directly — bypasses the production per-frame blast budget so the
	# stress test can actually push past it.
	var col := WARM_COLOR
	# Audio (skipped under heavy stress so a 100/s test isn't 100 sounds/sec).
	if _stress_rate < 8.0:
		SFX.explosion(pos, _radius)
	if _fx.heat:
		Violence.spawn_heat_distortion(self, pos, _radius, Violence.blast_expand_time(_radius), clampf(_radius * 0.012, 0.025, 0.06))
	if _fx.shock:
		Violence.spawn_shockwave_ring(self, pos, _radius)
	if _fx.lights:
		Violence._spawn_blast_flash_light(self, pos, _radius)
		Violence._spawn_blast_core_light(self, pos, _radius, col)
	if _fx.fireball:
		Violence._spawn_blast_fireball(self, pos, _radius, col)
	if _fx.smoke:
		Violence.spawn_blast_fire_smoke(self, pos, _radius, col)
	if _fx.fire_clouds:
		Violence.spawn_blast_fire_clouds(self, pos, _radius, col)
	if _fx.shards:
		Violence.spawn_blast_flame_shards(self, pos, _radius, col)
	if _fx.embers:
		Violence.spawn_blast_embers(self, pos, _radius, col)

# -------------------- UI --------------------

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_TOP_LEFT)
	scroll.position = Vector2(12, 12)
	scroll.custom_minimum_size = Vector2(410, 660)
	canvas.add_child(scroll)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.66)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	scroll.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	panel.add_child(vb)

	_header(vb, "EXPLOSION LAB", Color(1, 0.7, 0.3), 16)
	var hint := Label.new()
	hint.text = "SPACE boom · RMB look · WASD/QE move · Shift sprint"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vb.add_child(hint)

	var boom_btn := Button.new()
	boom_btn.text = "💥  BOOM"
	boom_btn.focus_mode = Control.FOCUS_NONE
	boom_btn.pressed.connect(_boom)
	vb.add_child(boom_btn)

	var type_row := HBoxContainer.new()
	type_row.add_theme_constant_override("separation", 8)
	vb.add_child(type_row)
	var type_lbl := Label.new()
	type_lbl.text = "Type"
	type_lbl.custom_minimum_size = Vector2(120, 0)
	type_lbl.add_theme_font_size_override("font_size", 12)
	type_row.add_child(type_lbl)
	var type_opt := OptionButton.new()
	type_opt.focus_mode = Control.FOCUS_NONE
	type_opt.add_item("Bullet blast", TYPE_BULLET)
	type_opt.add_item("Ion detonation", TYPE_ION)
	type_opt.item_selected.connect(func(idx: int) -> void: _blast_type = idx)
	type_row.add_child(type_opt)

	vb.add_child(HSeparator.new())
	_add_slider(vb, "Time scale (slow-mo)", 0.02, 1.0, Engine.time_scale, 0.01,
		func(v: float) -> void: Engine.time_scale = v)
	_add_slider(vb, "Blast radius (m)", 2.0, 24.0, _radius, 0.5,
		func(v: float) -> void: _radius = v)
	_add_slider(vb, "Auto-repeat (s, 0=off)", 0.0, 4.0, _repeat_interval, 0.1,
		func(v: float) -> void:
			_repeat_interval = v
			_repeat_accum = 0.0)
	_add_slider(vb, "STRESS: explosions/sec", 0.0, 400.0, _stress_rate, 1.0,
		func(v: float) -> void:
			_stress_rate = v
			_stress_accum = 0.0)

	vb.add_child(HSeparator.new())
	_header(vb, "FX LAYERS (toggle)", Color(0.7, 0.9, 1.0), 12)
	_add_toggle(vb, "Heat distortion", "heat")
	_add_toggle(vb, "Shockwave", "shock")
	_add_toggle(vb, "Lights", "lights")
	_add_toggle(vb, "Hot core (additive)", "fireball")
	_add_toggle(vb, "Smoke clouds", "smoke")
	_add_toggle(vb, "Fire clouds", "fire_clouds")
	_add_toggle(vb, "Flame shards", "shards")
	_add_toggle(vb, "Embers", "embers")

	vb.add_child(HSeparator.new())
	_header(vb, "DENSITY", Color(0.7, 0.9, 1.0), 12)
	_add_slider(vb, "Smoke clouds ×", 0.0, 3.0, Violence.blast_smoke_count_scale, 0.1,
		func(v: float) -> void: Violence.blast_smoke_count_scale = v)
	_add_slider(vb, "Fire clouds ×", 0.0, 3.0, Violence.blast_fire_cloud_count_scale, 0.1,
		func(v: float) -> void: Violence.blast_fire_cloud_count_scale = v)
	_add_slider(vb, "Flame shards ×", 0.0, 3.0, Violence.blast_shard_count_scale, 0.1,
		func(v: float) -> void: Violence.blast_shard_count_scale = v)
	_add_slider(vb, "Embers ×", 0.0, 3.0, Violence.blast_ember_count_scale, 0.1,
		func(v: float) -> void: Violence.blast_ember_count_scale = v)

	vb.add_child(HSeparator.new())
	_header(vb, "SFX LEVELS (dB)", Color(0.7, 0.9, 1.0), 12)
	AudioSettingsPanel.add_sfx_slider(vb, "Explosion bang", "explosion_bang_db", -24.0, 24.0, 130.0)
	AudioSettingsPanel.add_sfx_slider(vb, "Explosion rumble", "explosion_rumble_db", -24.0, 24.0, 130.0)
	AudioSettingsPanel.add_sfx_slider(vb, "Ion burst", "ion_cannon_burst_db", -24.0, 12.0, 130.0)

func _header(vb: VBoxContainer, text: String, col: Color, size: int) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	vb.add_child(l)

func _add_toggle(vb: VBoxContainer, label: String, key: String) -> void:
	var cb := CheckButton.new()
	cb.text = label
	cb.button_pressed = _fx[key]
	cb.focus_mode = Control.FOCUS_NONE
	cb.add_theme_font_size_override("font_size", 12)
	cb.toggled.connect(func(on: bool) -> void: _fx[key] = on)
	vb.add_child(cb)

func _add_slider(vb: VBoxContainer, label: String, lo: float, hi: float, value: float, step: float, on_change: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vb.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(150, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(140, 18)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.focus_mode = Control.FOCUS_NONE
	row.add_child(slider)
	var val := Label.new()
	val.text = "%.2f" % value
	val.custom_minimum_size = Vector2(46, 0)
	val.add_theme_font_size_override("font_size", 12)
	row.add_child(val)
	slider.value_changed.connect(func(v: float) -> void:
		val.text = "%.2f" % v
		on_change.call(v))

# -------------------- perf HUD --------------------

func _build_perf_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-280, 12)
	panel.custom_minimum_size = Vector2(268, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.72)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	canvas.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	panel.add_child(vb)
	_header(vb, "PERFORMANCE", Color(0.6, 1.0, 0.6), 14)
	for k in ["fps", "frame", "cpu", "phys", "gpu_hint", "draw", "objects", "prims", "nodes", "orphans", "vram", "rate"]:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 12)
		l.text = ""
		vb.add_child(l)
		_perf_labels[k] = l

func _update_perf() -> void:
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(fps, 1.0)
	var cpu_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_perf_labels["fps"].text = "FPS: %d" % fps
	_perf_labels["fps"].add_theme_color_override("font_color",
		Color(0.5, 1, 0.5) if fps >= 60 else (Color(1, 0.9, 0.4) if fps >= 30 else Color(1, 0.45, 0.4)))
	_perf_labels["frame"].text = "Frame: %.2f ms" % frame_ms
	_perf_labels["cpu"].text = "CPU process: %.2f ms" % cpu_ms
	_perf_labels["phys"].text = "Physics: %.2f ms" % phys_ms
	# If the frame is much longer than CPU work, we're GPU/fill-rate bound.
	var gpu_bound := frame_ms > (cpu_ms + phys_ms) * 1.4
	_perf_labels["gpu_hint"].text = "Bound: %s" % ("GPU / fill-rate" if gpu_bound else "CPU")
	_perf_labels["gpu_hint"].add_theme_color_override("font_color", Color(1, 0.7, 0.4) if gpu_bound else Color(0.7, 0.85, 1))
	_perf_labels["draw"].text = "Draw calls: %d" % int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_perf_labels["objects"].text = "Objects drawn: %d" % int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_perf_labels["prims"].text = "Primitives: %s" % _fmt(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_perf_labels["nodes"].text = "Nodes: %d" % int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_perf_labels["orphans"].text = "Orphan nodes: %d" % int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	_perf_labels["vram"].text = "VRAM: %.1f MB" % (Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)
	_perf_labels["rate"].text = "Booms/sec (actual): %d" % _booms_last_second

func _fmt(n: float) -> String:
	if n >= 1000000.0:
		return "%.1fM" % (n / 1000000.0)
	if n >= 1000.0:
		return "%.1fk" % (n / 1000.0)
	return "%d" % int(n)
