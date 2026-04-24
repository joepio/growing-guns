extends Control

@onready var name_input: LineEdit = $Container/Panel/Margin/VBox/NameSection/NameInput
@onready var addr_input: LineEdit = $Container/Panel/Margin/VBox/JoinSection/HBoxJoin/AddrInput
@onready var bot_button: Button = $Container/Panel/Margin/VBox/MainActions/BotButton
@onready var host_button: Button = $Container/Panel/Margin/VBox/MainActions/HostButton
@onready var join_button: Button = $Container/Panel/Margin/VBox/JoinSection/HBoxJoin/JoinButton
@onready var game_list_vbox: VBoxContainer = $Container/Panel/Margin/VBox/ScrollContainer/GameList
@onready var status_label: Label = $Container/Panel/Margin/VBox/Status

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_retro_filter()

	bot_button.pressed.connect(_on_vs_bot)
	host_button.pressed.connect(_on_host)
	join_button.pressed.connect(_on_join)

	name_input.text = "Player_%d" % (randi() % 1000)

	# Start listening for local games immediately
	NetworkManager.game_discovered.connect(_on_games_discovered)
	NetworkManager.start_discovery()

func _build_retro_filter() -> void:
	var retro_overlay := ColorRect.new()
	retro_overlay.name = "RetroFilter"
	retro_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	retro_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var shader := Shader.new()
	shader.code = "
		shader_type canvas_item;
		uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

		const float bayer[16] = {
			0.0/16.0, 8.0/16.0, 2.0/16.0, 10.0/16.0,
			12.0/16.0, 4.0/16.0, 14.0/16.0, 6.0/16.0,
			3.0/16.0, 11.0/16.0, 1.0/16.0, 9.0/16.0,
			15.0/16.0, 7.0/16.0, 13.0/16.0, 5.0/16.0
		};

		void fragment() {
			vec2 uv = SCREEN_UV;
			vec2 centered_uv = uv - 0.5;
			float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
			vec2 aspect_uv = centered_uv * vec2(aspect, 1.0);
			float dist = length(aspect_uv);
			float distortion = 0.15;
			float max_dist_sq = dot(vec2(0.5 * aspect, 0.5), vec2(0.5 * aspect, 0.5));
			float zoom = 0.995 / (1.0 + distortion * max_dist_sq);
			uv = 0.5 + centered_uv * zoom * (1.0 + distortion * dist * dist);

			vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
			int p_size = max(1, int(round(res.y / 720.0)));
			uv = (floor(uv * res / float(p_size)) + 0.5) * float(p_size) / res;
			vec2 uv_min = SCREEN_PIXEL_SIZE * 0.5;
			vec2 uv_max = vec2(1.0) - uv_min;

			float amount = 0.001 * (dist * dist);
			float r = texture(screen_texture, clamp(uv + vec2(amount, 0.0), uv_min, uv_max)).r;
			float g = texture(screen_texture, clamp(uv, uv_min, uv_max)).g;
			float b = texture(screen_texture, clamp(uv - vec2(amount, 0.0), uv_min, uv_max)).b;
			vec3 color = vec3(r, g, b);

			vec3 bleed = vec3(0.0);
			vec2 b_offset = SCREEN_PIXEL_SIZE * float(p_size) * 1.5;
			bleed += texture(screen_texture, clamp(uv + vec2(b_offset.x, b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(-b_offset.x, b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(b_offset.x, -b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(-b_offset.x, -b_offset.y), uv_min, uv_max)).rgb;
			color += bleed * 0.15;

			ivec2 p = ivec2(FRAGCOORD.xy / float(p_size));
			float threshold = (bayer[(p.x % 4) * 4 + (p.y % 4)] - 0.5) * 0.5;

			float levels = 32.0;
			float vignette = clamp(1.0 - dist * 1.4, 0.0, 1.0);
			color = floor(color * levels + threshold + 0.5) / levels;
			color *= mix(0.7, 1.0, vignette);			COLOR.rgb = color;
			COLOR.a = 1.0;
		}
	"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	retro_overlay.material = mat
	add_child(retro_overlay)

func _exit_tree() -> void:
	# Stop discovery if we leave the main menu (though typically we only go to game)
	NetworkManager.stop_discovery()

func _on_vs_bot() -> void:
	status_label.text = "Starting solo match..."
	if NetworkManager.host_game(name_input.text):
		NetworkManager.set_meta("spawn_bot_on_start", true)
		_go_to_game()

func _on_host() -> void:
	status_label.text = "Hosting..."
	NetworkManager.set_meta("spawn_bot_on_start", false)
	if NetworkManager.host_game(name_input.text):
		_go_to_game()
	else:
		status_label.text = "Failed to host (port in use?)"

func _on_join() -> void:
	var addr := addr_input.text.strip_edges()
	if addr.is_empty():
		addr = "127.0.0.1"
	_do_join(addr)

func _do_join(addr: String) -> void:
	status_label.text = "Connecting to %s..." % addr
	if NetworkManager.join_game(addr, name_input.text):
		_go_to_game()
	else:
		status_label.text = "Failed to connect"

func _on_games_discovered(games: Dictionary) -> void:
	# Clear list
	for child in game_list_vbox.get_children():
		child.queue_free()

	if games.is_empty():
		var lbl := Label.new()
		lbl.text = "   (searching...)"
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		lbl.add_theme_font_size_override("font_size", 12)
		game_list_vbox.add_child(lbl)
		return

	for addr in games:
		var game: Dictionary = games[addr]
		var btn := Button.new()
		btn.text = " JOIN: %s (%d/%d) @ %s" % [game.name, game.players, game.max, addr]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(0, 36)
		btn.add_theme_font_size_override("font_size", 12)
		btn.add_theme_color_override("font_hover_color", Color(0.6, 0.9, 1.0))

		# Reuse the established button styles
		btn.add_theme_stylebox_override("normal", load("res://scenes/main.tscn::Style_Button"))
		btn.add_theme_stylebox_override("hover", load("res://scenes/main.tscn::Style_Button_Hover"))
		btn.add_theme_stylebox_override("pressed", load("res://scenes/main.tscn::Style_Button"))

		btn.pressed.connect(_do_join.bind(addr))
		game_list_vbox.add_child(btn)

func _go_to_game() -> void:
	get_tree().change_scene_to_file("res://scenes/game.tscn")
