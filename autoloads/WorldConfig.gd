## WorldConfig — Autoload singleton
##
## Single source of truth for all world parameters.
## Read by terrain, building spawner, chunk manager, and any future system
## that needs to know the world's geographic or spatial configuration.
extends Node

# ---------------------------------------------------------------------------
# Geographic origin (matches the Python pipeline config)
# ---------------------------------------------------------------------------

const CENTER_LAT: float = 45.188967
const CENTER_LON: float = 5.724615

# ---------------------------------------------------------------------------
# World extents (populated at runtime from heightmap.json)
# ---------------------------------------------------------------------------

## Total width of the world in metres (east–west).
var world_width_m: float = 10_000.0

## Total height of the world in metres (north–south).
var world_height_m: float = 10_000.0

## Minimum real-world elevation (metres above sea level) → heightmap value 0.
var elevation_min_m: float = 200.0

## Maximum real-world elevation (metres above sea level) → heightmap value 1.
var elevation_max_m: float = 2700.0

## Vertical scale applied to the terrain mesh so that 1 heightmap unit = 1 metre.
var elevation_range_m: float:
	get: return elevation_max_m - elevation_min_m

# ---------------------------------------------------------------------------
# Chunk system
# ---------------------------------------------------------------------------

## Side length of one chunk in metres.  Must divide world_width_m evenly.
const CHUNK_SIZE_M: float = 500.0

# ---------------------------------------------------------------------------
# LOD distances
# ---------------------------------------------------------------------------

## Buildings: detailed extruded mesh hidden beyond this distance.
const LOD_BUILDING_DETAIL_M: float = 2400.0
## Buildings: z LOD box hidden beyond this distance.
const LOD_BUILDING_BOX_M: float    = 6400.0
## Trees: full 3D mesh hidden beyond this distance from the chunk centre.
const LOD_TREE_3D_M: float         = 600.0
## Trees: billboard hidden beyond this distance from the chunk centre.
const LOD_TREE_BILLBOARD_M: float  = 1400.0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_load_metadata()


func _load_metadata() -> void:
	const META_PATH := "res://data/heightmap.json"
	if not FileAccess.file_exists(META_PATH):
		push_warning("WorldConfig: heightmap.json not found — using default values.")
		return

	var file := FileAccess.open(META_PATH, FileAccess.READ)
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()

	if err != OK:
		push_error("WorldConfig: failed to parse heightmap.json")
		return

	var data: Dictionary = json.data
	world_width_m   = data.get("world_width_m",   world_width_m)
	world_height_m  = data.get("world_height_m",  world_height_m)
	elevation_min_m = data.get("elevation_min_m", elevation_min_m)
	elevation_max_m = data.get("elevation_max_m", elevation_max_m)
