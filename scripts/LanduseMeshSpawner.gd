## LanduseMeshSpawner — reads landuse.geojson and renders flat polygon overlays.
##
## Each landuse/natural/leisure area becomes a flat mesh that follows the terrain
## surface (height sampled per vertex). A small Y offset avoids z-fighting.
##
## Normalised type → material mapping:
##   wood       → dark green,  roughness 0.95
##   water      → water.gdshader (animated waves, see shader for parameters)
##   grass      → light green, roughness 0.95
##   wetland    → teal-green,  roughness 0.90
##   farmland   → golden tan,  roughness 0.95
##   park       → medium green,roughness 0.95
##   sports     → bright green,roughness 0.90
##   residential→ skip (blends with terrain texture)
##   industrial → light grey,  roughness 0.80
##
## Coordinate convention matches Terrain.gd:
##   GeoJSON [x, y] = [UTM_easting_local, UTM_northing_local]
##   Godot X = east, Z = south (northing flipped to -Z)
class_name LanduseMeshSpawner
extends Node3D

const LANDUSE_PATH    := "res://data/landuse.geojson"
const WATER_SHADER_PATH := "res://shaders/water.gdshader"

## Base Y offset above terrain. Each priority tier adds an extra 0.05 m on top.
const Y_OFFSET_BASE: float = 0.04

@onready var _terrain: Terrain = get_node("../Terrain")

# ---------------------------------------------------------------------------
# Materials per normalised type
# ---------------------------------------------------------------------------

const _TYPE_COLOURS: Dictionary = {
	"wood":        Color(0.15, 0.35, 0.12),
	"water":       Color(0.25, 0.50, 0.75),
	"grass":       Color(0.45, 0.65, 0.28),
	"wetland":     Color(0.30, 0.52, 0.38),
	"farmland":    Color(0.72, 0.65, 0.35),
	"park":        Color(0.35, 0.60, 0.25),
	"sports":      Color(0.40, 0.72, 0.28),
	"industrial":  Color(0.62, 0.62, 0.60),
}

const _TYPE_ROUGHNESS: Dictionary = {
	"wood":        0.95,
	"water":       0.05,
	"grass":       0.95,
	"wetland":     0.90,
	"farmland":    0.95,
	"park":        0.95,
	"sports":      0.88,
	"industrial":  0.80,
}

## Render priority — higher draws on top when polygons overlap.
const _TYPE_PRIORITY: Dictionary = {
	"grass":       0,
	"farmland":    0,
	"industrial":  0,
	"wetland":     1,
	"park":        1,
	"sports":      2,
	"water":       2,
	"wood":        3,
}

var _material_cache: Dictionary = {}
var _water_shader: Shader = null

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
	if not FileAccess.file_exists(LANDUSE_PATH):
		push_warning("LanduseMeshSpawner: landuse.geojson not found — skipping.")
		return

	var file := FileAccess.open(LANDUSE_PATH, FileAccess.READ)
	var raw  := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(raw) != OK:
		push_error("LanduseMeshSpawner: failed to parse landuse.geojson")
		return

	var features: Array = json.data.get("features", [])
	print("LanduseMeshSpawner: loading %d features ..." % features.size())

	var spawned := 0
	for feature in features:
		if _process_feature(feature):
			spawned += 1

	print("LanduseMeshSpawner: done. (%d meshes)" % spawned)


func _process_feature(feature: Dictionary) -> bool:
	var geometry:   Dictionary = feature.get("geometry", {})
	var properties: Dictionary = feature.get("properties", {})

	var landuse_type: String = str(properties.get("type", ""))
	if landuse_type.is_empty() or not _TYPE_COLOURS.has(landuse_type):
		return false

	# Skip residential — blends naturally with terrain satellite texture.
	if landuse_type == "residential":
		return false

	if geometry.get("type") != "Polygon":
		return false

	var rings: Array = geometry.get("coordinates", [])
	if rings.is_empty() or (rings[0] as Array).size() < 3:
		return false

	# Convert GeoJSON [utm_east, utm_north] → Godot XZ [east, -north]
	var ring_world := PackedVector2Array()
	for point in (rings[0] as Array):
		ring_world.append(Vector2(float(point[0]), -float(point[1])))

	var centroid := _ring_centroid(ring_world)

	var ring_local := PackedVector2Array()
	for v in ring_world:
		ring_local.append(v - centroid)

	var y_offset: float = Y_OFFSET_BASE + int(_TYPE_PRIORITY.get(landuse_type, 0)) * 0.05
	var mesh := _build_flat_mesh(ring_local, centroid, y_offset)
	if mesh == null:
		return false

	var instance := MeshInstance3D.new()
	instance.mesh     = mesh
	instance.position = Vector3(centroid.x, 0.0, centroid.y)
	instance.set_surface_override_material(0, _get_material(landuse_type))
	add_child(instance)
	return true


func _build_flat_mesh(ring_local: PackedVector2Array, centroid: Vector2, y_offset: float) -> ArrayMesh:
	var tris := Geometry2D.triangulate_polygon(ring_local)
	if tris.is_empty():
		return null

	var vertices := PackedVector3Array()
	var normals  := PackedVector3Array()
	var uvs      := PackedVector2Array()

	# Sample terrain height per vertex so the mesh hugs the ground.
	for v in ring_local:
		var world_x := centroid.x + v.x
		var world_z := centroid.y + v.y
		var terrain_y: float = _terrain.sample_height(world_x, world_z) if _terrain else 0.0
		vertices.append(Vector3(v.x, terrain_y + y_offset, v.y))
		normals.append(Vector3.UP)
		uvs.append(Vector2(v.x, v.y) / 10.0)

	# Check winding and build indices.
	var a := vertices[tris[0]]
	var b := vertices[tris[1]]
	var c := vertices[tris[2]]
	var faces_up: bool = (b - a).cross(c - a).dot(Vector3.UP) > 0.0

	var indices := PackedInt32Array()
	for i in range(0, tris.size(), 3):
		if faces_up:
			indices.append_array([tris[i], tris[i + 1], tris[i + 2]])
		else:
			indices.append_array([tris[i], tris[i + 2], tris[i + 1]])

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
# Material cache
# ---------------------------------------------------------------------------

func _get_material(landuse_type: String) -> Material:
	if _material_cache.has(landuse_type):
		return _material_cache[landuse_type]

	var mat: Material
	if landuse_type == "water":
		if _water_shader == null:
			_water_shader = load(WATER_SHADER_PATH)
		var smat := ShaderMaterial.new()
		smat.shader = _water_shader
		mat = smat
	else:
		var smat := StandardMaterial3D.new()
		smat.albedo_color   = _TYPE_COLOURS[landuse_type]
		smat.roughness      = _TYPE_ROUGHNESS.get(landuse_type, 0.90)
		smat.cull_mode      = BaseMaterial3D.CULL_DISABLED
		smat.render_priority = _TYPE_PRIORITY.get(landuse_type, 0)
		mat = smat

	_material_cache[landuse_type] = mat
	return mat


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

func _ring_centroid(ring: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for v in ring:
		sum += v
	return sum / ring.size()
