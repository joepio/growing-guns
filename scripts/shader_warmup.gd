class_name ShaderWarmup extends RefCounted

const GRENADE_SCRIPT := preload("res://scripts/grenade.gd")
const ION_CANNON_SCRIPT := preload("res://scripts/ion_cannon.gd")
const PLAYER_SCRIPT := preload("res://scripts/player.gd")

# Process-wide — GPU PSOs stay compiled after the first warmup pass.
static var effect_shaders_warmed: bool = false


static func find_arena_generator(root: Node) -> ArenaGenerator:
	if root == null:
		return null
	if root is ArenaGenerator:
		return root as ArenaGenerator
	for child in root.get_children():
		var found := find_arena_generator(child)
		if found != null:
			return found
	return null


# Compile every combat effect + destructible rock shader once per session.
# Call from the menu during idle time so match start never waits on this.
static func warmup_effect_shaders(scene_root: Node, force_draw: bool = true) -> void:
	if effect_shaders_warmed or scene_root == null:
		return
	var arena_gen := find_arena_generator(scene_root)
	if arena_gen == null:
		return
	effect_shaders_warmed = true
	Trace.span_begin("shader_warmup (session)")
	Violence.prewarm_disintegration_cache()
	GRENADE_SCRIPT.warmup_shaders(scene_root)
	GRENADE_SCRIPT.warmup_scene(scene_root)
	Violence.warmup_blast_materials(scene_root)
	ION_CANNON_SCRIPT.warmup_shaders(scene_root)
	PLAYER_SCRIPT.warmup_phoenix_shaders(scene_root)
	Violence.warmup_gib_render(scene_root)
	GpuDebris.warmup(scene_root)
	arena_gen.warmup_gpu_materials(scene_root)
	if force_draw and DisplayServer.get_name() != "headless":
		RenderingServer.force_draw(true)
	Trace.span_end("shader_warmup (session)")
