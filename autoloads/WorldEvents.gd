## WorldEvents — Autoload signal bus
##
## Central hub for decoupled communication between systems.
## No logic lives here — only signal declarations.
##
## Usage:
##   Emit:   WorldEvents.player_moved.emit(position)
##   Listen: WorldEvents.player_moved.connect(_on_player_moved)
extends Node

# ---------------------------------------------------------------------------
# Player
# ---------------------------------------------------------------------------

## Emitted by the player every frame while moving.
signal player_moved(world_position: Vector3)

# ---------------------------------------------------------------------------
# Chunks
# ---------------------------------------------------------------------------

## Emitted by ChunkManager when a chunk finishes loading all its content.
signal chunk_loaded(chunk_coords: Vector2i)

## Emitted by ChunkManager just before a chunk is freed.
signal chunk_unloaded(chunk_coords: Vector2i)

# ---------------------------------------------------------------------------
# Data pipeline
# ---------------------------------------------------------------------------

## Emitted once when all static world data (terrain + buildings) is ready.
signal world_data_ready()
