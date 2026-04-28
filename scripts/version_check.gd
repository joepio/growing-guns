extends Node

# Lightweight "new version available" nudge for the web-zip distribution
# (users who don't install via the itch.io app, which auto-updates already).
# Fires one HTTPRequest at boot against a public manifest, semver-compares to
# our packed-in version (project.godot → application/config/version, kept in
# sync by tools/build_release.sh), and if the remote is newer drops a small
# clickable button in the bottom-right that opens the itch page on shell_open.

const REMOTE_VERSION_URL := "https://raw.githubusercontent.com/joepio/rounds-fps/main/VERSION"
const ITCH_URL := "https://joepio.itch.io/more-rounds"


func _ready() -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_response)
	# Failing to even start the request (no network at boot, etc.) is silent —
	# version checks are nice-to-have, never block boot.
	if http.request(REMOTE_VERSION_URL) != OK:
		queue_free()


func _on_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var remote: String = body.get_string_from_utf8().strip_edges()
	# raw.githubusercontent serves the file's raw bytes, including a trailing
	# newline — strip_edges takes care of it. Sanity-check the shape so a
	# 200-OK page (e.g. a redirect target) doesn't get parsed as a version.
	if remote.is_empty() or not remote[0].is_valid_int():
		return
	var local: String = String(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	if not _is_newer(remote, local):
		return
	_show_update_banner(remote)


# Compares dotted-int versions component-by-component. Missing components are
# treated as 0 so "0.3" > "0.2.5" evaluates correctly.
static func _is_newer(remote: String, local: String) -> bool:
	var r: PackedStringArray = remote.split(".")
	var l: PackedStringArray = local.split(".")
	var n: int = maxi(r.size(), l.size())
	for i in n:
		var ri: int = (r[i] as String).to_int() if i < r.size() else 0
		var li: int = (l[i] as String).to_int() if i < l.size() else 0
		if ri > li:
			return true
		if ri < li:
			return false
	return false


func _show_update_banner(remote_version: String) -> void:
	# Need a HUD CanvasLayer to anchor onto. game.tscn always has one named
	# "HUD" — bail quietly on other scenes (action_lab / gun_lab).
	var scene := get_tree().current_scene
	if scene == null:
		return
	var hud := scene.get_node_or_null("HUD") as CanvasLayer
	if hud == null:
		return

	var btn := Button.new()
	btn.name = "VersionUpdateBanner"
	btn.text = "  ↑ v%s available — click to download  " % remote_version
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", Color(1, 0.95, 0.5))
	btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	btn.add_theme_constant_override("outline_size", 3)
	btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	btn.offset_left = -300
	btn.offset_top = -52
	btn.offset_right = -12
	btn.offset_bottom = -14
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.pressed.connect(func() -> void:
		OS.shell_open(ITCH_URL)
		btn.queue_free())
	hud.add_child(btn)
