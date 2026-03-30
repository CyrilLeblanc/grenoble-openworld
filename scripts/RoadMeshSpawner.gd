## RoadMeshSpawner — reads roads.geojson and renders road/waterway ribbons on the terrain.
##
## Each OSM way becomes a ribbon mesh that follows the terrain surface.
## All ways of the same category are merged into a single ArrayMesh to minimise
## draw calls (one MeshInstance3D per category).
##
## Ribbon algorithm: miter directions at interior points prevent gaps at corners.
##
## Y offsets keep roads visible above landuse overlays:
##   Roads      : terrain + 1.5 m
##   Waterways  : terrain + 1.6 m  (drawn on top of roads where they cross)
##
## Coordinate convention matches Terrain.gd:
##   GeoJSON [x, y] = [UTM_easting_local, UTM_northing_local]
##   Godot X = east, Z = south (northing flipped to -Z)
class_name RoadMeshSpawner
extends Node3D

const ROADS_PATH := "res://data/roads.geojson"

const Y_ROADS:      float = 0.12
const Y_WATERWAYS:  float = 0.18

@onready var _terrain: Terrain = get_node("../Terrain")

# ---------------------------------------------------------------------------
# Visual properties per category
# ---------------------------------------------------------------------------

const _CATEGORY_COLOUR: Dictionary = {
	"motorway":  Color(0.90, 0.65, 0.20),
	"trunk":     Color(0.85, 0.60, 0.20),
	"primary":   Color(0.85, 0.85, 0.55),
	"secondary": Color(0.92, 0.92, 0.70),
	"tertiary":  Color(0.80, 0.80, 0.80),
	"local":     Color(0.72, 0.72, 0.72),
	"service":   Color(0.65, 0.65, 0.65),
	"river":     Color(0.28, 0.52, 0.78),
	"canal":     Color(0.30, 0.48, 0.70),
	"stream":    Color(0.40, 0.58, 0.80),
}

const _CATEGORY_ROUGHNESS: Dictionary = {
	"motorway":  0.70,
	"trunk":     0.72,
	"primary":   0.80,
	"secondary": 0.85,
	"tertiary":  0.88,
	"local":     0.90,
	"service":   0.92,
	"river":     0.05,
	"canal":     0.08,
	"stream":    0.10,
}

const _WATERWAY_CATEGORIES: Array = ["river", "canal", "stream"]

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	WorldEvents.world_data_ready.connect(_on_world_data_ready)


func _on_world_data_ready() -> void:
	_load_and_spawn()


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

func _load_and_spawn() -> void:
	if not FileAccess.file_exists(ROADS_PATH):
		push_warning("RoadMeshSpawner: roads.geojson not found — skipping.")
		return

	var file := FileAccess.open(ROADS_PATH, FileAccess.READ)
	var raw  := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(raw) != OK:
		push_error("RoadMeshSpawner: failed to parse roads.geojson")
		return

	var features: Array = json.data.get("features", [])
	print("RoadMeshSpawner: loading %d features ..." % features.size())

	# Group features by category.
	var by_category: Dictionary = {}
	for feature in features:
		var props: Dictionary = feature.get("properties", {})
		var cat: String = str(props.get("category", ""))
		if cat.is_empty() or not _CATEGORY_COLOUR.has(cat):
			continue
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(feature)

	# Build one mesh per category.
	for cat in by_category:
		var mesh := _build_category_mesh(by_category[cat])
		if mesh == null:
			continue
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.set_surface_override_material(0, _make_material(cat))
		add_child(instance)

	print("RoadMeshSpawner: done. (%d categories)" % by_category.size())


# ---------------------------------------------------------------------------
# Mesh building — one mesh per category (all ways merged)
# ---------------------------------------------------------------------------

func _build_category_mesh(features: Array) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals  := PackedVector3Array()
	var uvs      := PackedVector2Array()
	var indices  := PackedInt32Array()

	for feature in features:
		var props: Dictionary = feature.get("properties", {})
		var geom:  Dictionary = feature.get("geometry", {})
		if geom.get("type") != "LineString":
			continue

		var raw_coords: Array = geom.get("coordinates", [])
		if raw_coords.size() < 2:
			continue

		var width: float = float(props.get("width", 4.0))
		var cat: String  = str(props.get("category", "local"))
		var y_base: float = Y_WATERWAYS if cat in _WATERWAY_CATEGORIES else Y_ROADS

		# Convert GeoJSON [utm_east, utm_north] → Godot XZ [east, -north]
		var points := PackedVector2Array()
		for c in raw_coords:
			points.append(Vector2(float(c[0]), -float(c[1])))

		_add_ribbon(points, width, y_base, vertices, normals, uvs, indices)

	if vertices.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return arr_mesh


# ---------------------------------------------------------------------------
# Ribbon generation — miter at interior points to avoid gaps at corners
# ---------------------------------------------------------------------------

func _add_ribbon(
	points:   PackedVector2Array,
	width:    float,
	y_base:   float,
	vertices: PackedVector3Array,
	normals:  PackedVector3Array,
	uvs:      PackedVector2Array,
	indices:  PackedInt32Array,
) -> void:
	var n := points.size()
	var half := width * 0.5

	# Pre-compute miter perpendiculars at each point.
	var perps := PackedVector2Array()
	perps.resize(n)

	for i in n:
		var dir := Vector2.ZERO
		if i > 0:
			dir += (points[i] - points[i - 1]).normalized()
		if i < n - 1:
			dir += (points[i + 1] - points[i]).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2(1.0, 0.0)
		dir = dir.normalized()
		# Perpendicular (rotate 90°)
		perps[i] = Vector2(-dir.y, dir.x)

	# Build left/right vertex arrays with terrain height.
	var u_accum: float = 0.0
	var base_idx: int  = vertices.size()

	for i in n:
		var p := points[i]
		var perp := perps[i]

		var left  := p + perp * half
		var right := p - perp * half

		var yl: float = (_terrain.sample_height(left.x,  left.y)  if _terrain else 0.0) + y_base
		var yr: float = (_terrain.sample_height(right.x, right.y) if _terrain else 0.0) + y_base

		if i > 0:
			u_accum += (p - points[i - 1]).length()
		var u_tiled: float = u_accum / width

		vertices.append(Vector3(left.x,  yl, left.y))
		vertices.append(Vector3(right.x, yr, right.y))
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		uvs.append(Vector2(0.0, u_tiled))
		uvs.append(Vector2(1.0, u_tiled))

	# Quads between consecutive pairs.
	for i in n - 1:
		var a: int = base_idx + i * 2        # left  i
		var b: int = base_idx + i * 2 + 1   # right i
		var c: int = base_idx + i * 2 + 2   # left  i+1
		var d: int = base_idx + i * 2 + 3   # right i+1
		indices.append_array([a, b, c, b, d, c])


# ---------------------------------------------------------------------------
# Material
# ---------------------------------------------------------------------------

func _make_material(category: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color  = _CATEGORY_COLOUR.get(category, Color(0.7, 0.7, 0.7))
	mat.roughness     = _CATEGORY_ROUGHNESS.get(category, 0.85)
	mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
	return mat
