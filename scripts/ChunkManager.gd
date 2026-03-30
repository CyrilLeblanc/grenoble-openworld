## ChunkManager — tracks player position and manages chunk load/unload.
##
## Phase 1: the entire world is one chunk — no streaming yet.
## The class is fully wired up so Phase 2 streaming slots in without
## touching any other script.
##
## Attach to a Node3D in the Main scene.
class_name ChunkManager
extends Node3D

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

## How many chunks in each direction around the player to keep loaded.
## Radius 1 = 3×3 grid. Currently unused in Phase 1 (single chunk).
@export var load_radius: int = 1

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

## Map of chunk coords → Chunk node (loaded chunks)
var _loaded: Dictionary = {}   # Vector2i → Node3D

var _last_player_chunk: Vector2i = Vector2i(0x7FFFFFFF, 0x7FFFFFFF)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	WorldEvents.player_moved.connect(_on_player_moved)
	# Phase 1: load the single origin chunk immediately
	_ensure_chunk_loaded(Vector2i.ZERO)


# ---------------------------------------------------------------------------
# Player tracking
# ---------------------------------------------------------------------------

func _on_player_moved(world_position: Vector3) -> void:
	var chunk_coords := _world_to_chunk(world_position)
	if chunk_coords == _last_player_chunk:
		return
	_last_player_chunk = chunk_coords
	_update_loaded_chunks(chunk_coords)


# ---------------------------------------------------------------------------
# Chunk grid logic
# ---------------------------------------------------------------------------

func _world_to_chunk(world_pos: Vector3) -> Vector2i:
	var size := WorldConfig.CHUNK_SIZE_M
	return Vector2i(
		int(floor(world_pos.x / size)),
		int(floor(world_pos.z / size)),
	)


func _update_loaded_chunks(centre: Vector2i) -> void:
	var desired := _desired_chunk_set(centre)

	# Unload chunks outside radius
	for coords in _loaded.keys():
		if coords not in desired:
			_unload_chunk(coords)

	# Load new chunks
	for coords in desired:
		if coords not in _loaded:
			_ensure_chunk_loaded(coords)


func _desired_chunk_set(centre: Vector2i) -> Array:
	var result: Array = []
	for dx in range(-load_radius, load_radius + 1):
		for dz in range(-load_radius, load_radius + 1):
			result.append(centre + Vector2i(dx, dz))
	return result


# ---------------------------------------------------------------------------
# Load / unload
# ---------------------------------------------------------------------------

func _ensure_chunk_loaded(coords: Vector2i) -> void:
	if coords in _loaded:
		return

	# For Phase 1 we only load coords (0,0) — the whole world is one chunk.
	# Phase 2 will load the correct terrain tile and building subset per chunk.
	if coords != Vector2i.ZERO:
		return

	var chunk := Node3D.new()
	chunk.name = "Chunk_%d_%d" % [coords.x, coords.y]
	add_child(chunk)
	_loaded[coords] = chunk

	WorldEvents.chunk_loaded.emit(coords)


func _unload_chunk(coords: Vector2i) -> void:
	var chunk: Node3D = _loaded.get(coords)
	if chunk == null:
		return

	WorldEvents.chunk_unloaded.emit(coords)
	chunk.queue_free()
	_loaded.erase(coords)
