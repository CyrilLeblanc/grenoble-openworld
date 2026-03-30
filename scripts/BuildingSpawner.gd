## BuildingSpawner — reads buildings.geojson and instantiates extruded polygon meshes.
##
## Follows the OSM Simple 3D Buildings spec (same as osmbuildings.org):
##
##   building=yes, has_parts=false  → render at full height
##   building=yes, has_parts=true   → render as ground-level base slab only
##   building:part=yes              → render from min_height_m to height_m
##
## Wall and roof materials are resolved by BuildingMaterialLibrary, which maps
## OSM tags (building type, explicit colours) to distinct StandardMaterial3D.
##
## Coordinate convention (matches Terrain.gd and BuildingMeshFactory):
##   GeoJSON [x, y] = [UTM_easting_local, UTM_northing_local]
##   Godot   X = east  (= UTM easting,  unchanged)
##   Godot   Z = south (= -UTM northing, flipped — UTM north = Godot -Z)
class_name BuildingSpawner
extends Node3D

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

const BUILDINGS_PATH := "res://data/buildings.geojson"

const FLOOR_HEIGHT_M: float = 3.0
const DEFAULT_LEVELS: int   = 3

@onready var _terrain: Terrain = get_node("../Terrain")

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal building_spawned(world_pos: Vector3, size: Vector3, properties: Dictionary)

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _material_library := BuildingMaterialLibrary.new()

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	WorldEvents.world_data_ready.connect(_on_world_data_ready)


func _on_world_data_ready() -> void:
	_load_and_spawn()


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _load_and_spawn() -> void:
	if not FileAccess.file_exists(BUILDINGS_PATH):
		push_error("BuildingSpawner: buildings.geojson not found at %s" % BUILDINGS_PATH)
		return

	var file := FileAccess.open(BUILDINGS_PATH, FileAccess.READ)
	var raw  := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(raw) != OK:
		push_error("BuildingSpawner: failed to parse buildings.geojson")
		return

	var features: Array = json.data.get("features", [])
	print("BuildingSpawner: loading %d features ..." % features.size())

	for feature in features:
		_process_feature(feature)

	print("BuildingSpawner: done. (%d cached materials)" % _material_library.cache_size())


func _process_feature(feature: Dictionary) -> void:
	var geometry:   Dictionary = feature.get("geometry", {})
	var properties: Dictionary = feature.get("properties", {})

	if geometry.get("type") != "Polygon":
		return

	var rings: Array = geometry.get("coordinates", [])
	if rings.is_empty() or (rings[0] as Array).size() < 3:
		return

	# Convert GeoJSON [utm_east, utm_north] → Godot XZ [east, -north]
	var footprint_world := PackedVector2Array()
	for point in (rings[0] as Array):
		footprint_world.append(Vector2(float(point[0]), -float(point[1])))

	var centroid: Vector2 = _ring_centroid(footprint_world)
	var aabb:     Rect2   = _ring_aabb(footprint_world)
	var ground_y: float   = _terrain.sample_height(centroid.x, centroid.y) if _terrain else 0.0

	var is_part:   bool = bool(properties.get("is_part",  false))
	var has_parts: bool = bool(properties.get("has_parts", false))

	var height_m:     float = _resolve_height(properties)
	var min_height_m: float = float(properties.get("min_height_m", 0.0))

	if has_parts:
		height_m     = min_height_m + FLOOR_HEIGHT_M
		min_height_m = 0.0

	var footprint_local := PackedVector2Array()
	for v in footprint_world:
		footprint_local.append(v - centroid)

	var building_mesh := BuildingMeshFactory.build(footprint_local, height_m, min_height_m)
	if building_mesh == null:
		return

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh     = building_mesh
	mesh_instance.position = Vector3(centroid.x, ground_y, centroid.y)
	mesh_instance.set_surface_override_material(BuildingMeshFactory.SURFACE_WALLS, _material_library.get_wall_material(properties))
	mesh_instance.set_surface_override_material(BuildingMeshFactory.SURFACE_ROOF,  _material_library.get_roof_material(properties))
	add_child(mesh_instance)

	building_spawned.emit(
		Vector3(centroid.x, ground_y + min_height_m, centroid.y),
		Vector3(aabb.size.x, height_m - min_height_m, aabb.size.y),
		properties,
	)


# ---------------------------------------------------------------------------
# Height resolution
# ---------------------------------------------------------------------------

func _resolve_height(properties: Dictionary) -> float:
	var raw_height = properties.get("height_m")
	if raw_height != null and typeof(raw_height) == TYPE_FLOAT:
		return float(raw_height)
	var levels = properties.get("levels")
	if levels != null:
		return int(levels) * FLOOR_HEIGHT_M
	return DEFAULT_LEVELS * FLOOR_HEIGHT_M


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

func _ring_centroid(ring: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for v in ring:
		sum += v
	return sum / ring.size()


func _ring_aabb(ring: PackedVector2Array) -> Rect2:
	var min_x := INF;  var max_x := -INF
	var min_y := INF;  var max_y := -INF
	for v in ring:
		min_x = minf(min_x, v.x);  max_x = maxf(max_x, v.x)
		min_y = minf(min_y, v.y);  max_y = maxf(max_y, v.y)
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)
