## SidewalkSpawner — generates sidewalk ribbon meshes from roads.geojson.
##
## For each road way, sidewalk presence is determined by:
##   1. The OSM "sidewalk" property if present ("left", "right", "both", "no").
##   2. Category-based inference when the property is absent:
##      primary / secondary / tertiary / local → both sides
##      motorway / trunk / service            → none
##
## Each sidewalk is a flat ribbon mesh:
##   • Centreline offset from road centreline by (road_width/2 + sidewalk_width/2)
##   • Elevation:  terrain + Y_ROADS + CURB_H  (15 cm above road surface)
##   • Width:      SIDEWALK_W  (2 m)
##   • Material:   sidewalk.gdshader (concrete paving slabs)
##
## All sidewalks are merged into a single MeshInstance3D to minimise draw calls.
##
## UV convention passed to the shader:
##   UV.x  0 → 1 across sidewalk width
##   UV.y  metres along road centreline
class_name SidewalkSpawner
extends Node3D

const ROADS_PATH          := "res://data/roads.geojson"
const SIDEWALK_SHADER_PATH := "res://shaders/sidewalk.gdshader"

# Must match RoadMeshSpawner constants.
const Y_ROADS:  float = 0.12
const CURB_H:   float = 0.15

const SIDEWALK_W: float = 2.0   # sidewalk strip width (metres)
const SIDEWALK_Y: float = Y_ROADS + CURB_H   # elevation above terrain

@onready var _terrain: Terrain = get_node("../Terrain")

# ---------------------------------------------------------------------------
# Categories that get sidewalks when the OSM tag is absent.
# ---------------------------------------------------------------------------

const _DEFAULT_SIDEWALK: Dictionary = {
	"primary":   "both",
	"secondary": "both",
	"tertiary":  "both",
	"local":     "both",
	"motorway":  "none",
	"trunk":     "none",
	"service":   "none",
}

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
		push_warning("SidewalkSpawner: roads.geojson not found — skipping.")
		return

	var file := FileAccess.open(ROADS_PATH, FileAccess.READ)
	var raw  := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(raw) != OK:
		push_error("SidewalkSpawner: failed to parse roads.geojson")
		return

	var features: Array = json.data.get("features", [])
	print("SidewalkSpawner: processing %d road features ..." % features.size())

	var vertices := PackedVector3Array()
	var normals  := PackedVector3Array()
	var uvs      := PackedVector2Array()
	var indices  := PackedInt32Array()

	var waterway_cats := ["river", "canal", "stream"]
	var n_strips := 0

	for feature in features:
		var props: Dictionary = feature.get("properties", {})
		var geom:  Dictionary = feature.get("geometry", {})
		if geom.get("type") != "LineString":
			continue

		var cat: String = str(props.get("category", ""))
		if cat in waterway_cats:
			continue   # no sidewalks along waterways

		var raw_coords: Array = geom.get("coordinates", [])
		if raw_coords.size() < 2:
			continue

		var road_width: float = float(props.get("width", 4.0))

		# Determine which sides get a sidewalk.
		var sw_tag: String = str(props.get("sidewalk", ""))
		var sw: String
		if sw_tag in ["left", "right", "both", "no", "none", "separate"]:
			sw = sw_tag
		else:
			sw = _DEFAULT_SIDEWALK.get(cat, "none")

		if sw == "no" or sw == "none":
			continue

		var points := PackedVector2Array()
		for c in raw_coords:
			points.append(Vector2(float(c[0]), -float(c[1])))

		if sw == "left" or sw == "both":
			_add_sidewalk_ribbon(points, road_width, 1.0, vertices, normals, uvs, indices)
			n_strips += 1
		if sw == "right" or sw == "both":
			_add_sidewalk_ribbon(points, road_width, -1.0, vertices, normals, uvs, indices)
			n_strips += 1

	print("SidewalkSpawner: %d sidewalk strips generated." % n_strips)

	if vertices.is_empty():
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var shader := load(SIDEWALK_SHADER_PATH) as Shader
	var mat    := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("sidewalk_width", SIDEWALK_W)

	var inst := MeshInstance3D.new()
	inst.mesh = arr_mesh
	inst.set_surface_override_material(0, mat)
	add_child(inst)


# ---------------------------------------------------------------------------
# Sidewalk ribbon generation
# ---------------------------------------------------------------------------

## Appends a sidewalk ribbon offset from the road centreline.
##
## side_sign:  +1.0 = left side (perp direction),  -1.0 = right side
##
## The ribbon centreline is at:
##   road_centre + perp * side_sign * (road_width/2 + sidewalk_width/2)
func _add_sidewalk_ribbon(
	points:    PackedVector2Array,
	road_w:    float,
	side_sign: float,
	vertices:  PackedVector3Array,
	normals:   PackedVector3Array,
	uvs:       PackedVector2Array,
	indices:   PackedInt32Array,
) -> void:
	var n      := points.size()
	var offset := side_sign * (road_w * 0.5 + SIDEWALK_W * 0.5)
	var half_w := SIDEWALK_W * 0.5

	# Miter perpendiculars at each centreline point.
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
		perps[i] = Vector2(-dir.y, dir.x)   # 90° CCW → left

	var u_accum: float = 0.0
	var base_idx: int  = vertices.size()

	for i in n:
		var p    := points[i]
		var perp := perps[i]

		# Sidewalk centreline in XZ
		var sw_center := p + perp * offset
		var sw_left   := sw_center + perp * side_sign * half_w
		var sw_right  := sw_center - perp * side_sign * half_w

		var yl: float = (_terrain.sample_height(sw_left.x,  sw_left.y)  if _terrain else 0.0) + SIDEWALK_Y
		var yr: float = (_terrain.sample_height(sw_right.x, sw_right.y) if _terrain else 0.0) + SIDEWALK_Y

		if i > 0:
			u_accum += (p - points[i - 1]).length()

		vertices.append(Vector3(sw_left.x,  yl, sw_left.y))
		vertices.append(Vector3(sw_right.x, yr, sw_right.y))
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		# UV.x 0→1 across sidewalk, UV.y metres along road
		uvs.append(Vector2(0.0, u_accum))
		uvs.append(Vector2(1.0, u_accum))

	for i in n - 1:
		var a: int = base_idx + i * 2
		var b: int = a + 1
		var c: int = a + 2
		var d: int = a + 3
		indices.append_array([a, b, c, b, d, c])
