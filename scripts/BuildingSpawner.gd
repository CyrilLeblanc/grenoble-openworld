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
## Accumulated per-building data for the LOD box pass.
## Key: Vector2i chunk coord.  Value: Array of {cx, cz, ground_y, height, min_height, sx, sz}.
var _lod_data: Dictionary = {}

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

	_spawn_lod_boxes()
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
	mesh_instance.set_surface_override_material(BuildingMeshFactory.SURFACE_WALLS, _material_library.get_wall_material(properties) as Material)
	mesh_instance.set_surface_override_material(BuildingMeshFactory.SURFACE_ROOF,  _material_library.get_roof_material(properties))
	# LOD: hide detail mesh beyond near distance.
	mesh_instance.visibility_range_end       = WorldConfig.LOD_BUILDING_DETAIL_M
	mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	add_child(mesh_instance)

	# Accumulate data for the cheap LOD box pass.
	var chunk_coord := Vector2i(
		int(floor(centroid.x / WorldConfig.CHUNK_SIZE_M)),
		int(floor(centroid.y / WorldConfig.CHUNK_SIZE_M)),
	)
	if not _lod_data.has(chunk_coord):
		_lod_data[chunk_coord] = []
	_lod_data[chunk_coord].append({
		"cx":         centroid.x,
		"cz":         centroid.y,
		"ground_y":   ground_y,
		"height":     height_m - min_height_m,
		"min_height": min_height_m,
		"sx":         maxf(aabb.size.x, 2.0),
		"sz":         maxf(aabb.size.y, 2.0),
	})

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


# ---------------------------------------------------------------------------
# LOD box pass — one merged cheap mesh per chunk for distant buildings
# ---------------------------------------------------------------------------

func _spawn_lod_boxes() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color  = Color(0.75, 0.72, 0.68)
	mat.roughness     = 0.95
	mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_FRONT

	for chunk_coord in _lod_data:
		var entries: Array = _lod_data[chunk_coord]
		var origin := Vector3(
			chunk_coord.x * WorldConfig.CHUNK_SIZE_M,
			0.0,
			chunk_coord.y * WorldConfig.CHUNK_SIZE_M,
		)

		var verts   := PackedVector3Array()
		var normals := PackedVector3Array()
		var indices := PackedInt32Array()

		for entry in entries:
			var h: float = entry["height"]
			if h <= 0.0:
				continue
			_add_box_to_arrays(
				verts, normals, indices,
				Vector3(
					entry["cx"] - origin.x,
					entry["ground_y"] + entry["min_height"] + h * 0.5,
					entry["cz"] - origin.z,
				),
				Vector3(entry["sx"] * 0.5, h * 0.5, entry["sz"] * 0.5),
			)

		if verts.is_empty():
			continue

		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX]  = indices

		var arr_mesh := ArrayMesh.new()
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		var lod_node := MeshInstance3D.new()
		lod_node.mesh                        = arr_mesh
		lod_node.position                    = origin
		lod_node.visibility_range_begin      = WorldConfig.LOD_BUILDING_DETAIL_M
		lod_node.visibility_range_end        = WorldConfig.LOD_BUILDING_BOX_M
		lod_node.visibility_range_fade_mode  = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		lod_node.set_surface_override_material(0, mat)
		add_child(lod_node)

	print("BuildingSpawner: LOD boxes spawned for %d chunks." % _lod_data.size())


func _add_box_to_arrays(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	indices: PackedInt32Array,
	center:  Vector3,
	half:    Vector3,
) -> void:
	# 6 faces, each a quad of 2 triangles.
	var faces: Array = [
		[Vector3(-1, 0, 0), [Vector3(-half.x, -half.y, -half.z), Vector3(-half.x, -half.y,  half.z), Vector3(-half.x,  half.y,  half.z), Vector3(-half.x,  half.y, -half.z)]],
		[Vector3( 1, 0, 0), [Vector3( half.x, -half.y,  half.z), Vector3( half.x, -half.y, -half.z), Vector3( half.x,  half.y, -half.z), Vector3( half.x,  half.y,  half.z)]],
		[Vector3(0, -1, 0), [Vector3(-half.x, -half.y,  half.z), Vector3(-half.x, -half.y, -half.z), Vector3( half.x, -half.y, -half.z), Vector3( half.x, -half.y,  half.z)]],
		[Vector3(0,  1, 0), [Vector3(-half.x,  half.y, -half.z), Vector3(-half.x,  half.y,  half.z), Vector3( half.x,  half.y,  half.z), Vector3( half.x,  half.y, -half.z)]],
		[Vector3(0, 0, -1), [Vector3( half.x, -half.y, -half.z), Vector3(-half.x, -half.y, -half.z), Vector3(-half.x,  half.y, -half.z), Vector3( half.x,  half.y, -half.z)]],
		[Vector3(0, 0,  1), [Vector3(-half.x, -half.y,  half.z), Vector3( half.x, -half.y,  half.z), Vector3( half.x,  half.y,  half.z), Vector3(-half.x,  half.y,  half.z)]],
	]
	for face in faces:
		var n: Vector3  = face[0]
		var corners: Array = face[1]
		var base := verts.size()
		for c in corners:
			verts.append(center + c)
			normals.append(n)
		indices.append_array([base, base+1, base+2, base, base+2, base+3])
