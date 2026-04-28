extends Node3D

# Wraps an ArenaGenerator with a WorldEnvironment + sun + fill light so it
# slots into game.gd's MAP_POOL the same way the hand-built arena scenes do.
#
# game.gd calls apply_seed(seed) right after add_child() — that's the only
# entry point. The generator regenerates synchronously, then we copy the
# matching palette into our environment + lights so the atmosphere matches.

@onready var generator: Node3D = $Generator
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var fill_light: OmniLight3D = $FillLight


func _ready() -> void:
	# Listen so a manual change to generator.seed (e.g. in editor) still
	# updates the atmosphere. game.gd's apply_seed path also goes through here.
	if not generator.regenerated.is_connected(_on_regenerated):
		generator.regenerated.connect(_on_regenerated)
	# Pre-populate with a default-seed arena so spawnpoints exist before
	# game.gd's first _swap_arena fires. Without this, players who join
	# during the WAITING state (or between rounds, where there's a brief
	# window mid-swap) fall through _pick_spawn's "no spawnpoints" fallback
	# and end up outside the arena bounds. The first real round start will
	# overwrite this with the proper seed via apply_seed().
	apply_seed(0)


func apply_seed(s: int) -> void:
	# Set seed first so palette lookup uses the new value, then regenerate
	# synchronously so spawnpoints exist before the caller queries them.
	generator.seed = s
	generator.regenerate()


func _on_regenerated(_stats: Dictionary) -> void:
	if generator and generator.has_method("apply_palette_to_environment"):
		generator.apply_palette_to_environment(world_env.environment, sun, fill_light)
