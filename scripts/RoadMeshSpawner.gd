## RoadMeshSpawner — reads roads.geojson and renders road ribbons with a
## cross-section profile (curb + road surface) and waterway ribbons.
##
## Road cross-section per ring (4 vertices, left → right):
##   [0] left_curb_top   — terrain + Y_ROADS + CURB_H,   UV.x = -0.1
##   [1] left_road_edge  — terrain + Y_ROADS,             UV.x =  0.0
##   [2] right_road_edge — terrain + Y_ROADS,             UV.x =  1.0
##   [3] right_curb_top  — terrain + Y_ROADS + CURB_H,   UV.x =  1.1
##
##   UV.y = accumulated metres along the centreline (for shader dash pattern).
##
## The road.gdshader uses UV.x to distinguish road surface (0..1) from curb
## face (< 0 or > 1), so both are rendered by the same material.
##
## Bridge handling (bridge=true in OSM):
##   Height is linearly interpolated between the first and last point terrain
##   heights, ignoring any terrain dip (river bed) beneath the bridge.
##   BRIDGE_LAYER_H * layer is added as vertical clearance.
##   Curb height is raised to BRIDGE_RAIL_H (1 m) to act as a railing.
##
## Waterways keep the original flat ribbon (no curbs) with a plain water material.
##
## Coordinate convention (matches Terrain.gd):
##   GeoJSON [x, y] = [UTM_easting_local, UTM_northing_local]
##   Godot   X = east,  Z = −north  (northing flipped)
class_name RoadMeshSpawner
extends Node3D

const ROADS_PATH := "res://data/roads.geojson"
const ROAD_SHADER_PATH := "res://shaders/road.gdshader"

# Y elevation above terrain surface
const Y_ROADS:     float = 0.12
const Y_WATERWAYS: float = 0.18

# Curb height above road surface (metres) — normal streets
const CURB_H: float = 0.15

# Bridge-specific constants
const BRIDGE_RAIL_H:   float = 1.00   # railing height replaces curb on bridges
const BRIDGE_LAYER_H:  float = 5.00   # extra metres per OSM layer value

@onready var _terrain: Terrain = get_node("../Terrain")

# ---------------------------------------------------------------------------
# Per-category road shader config
# ---------------------------------------------------------------------------

# Nominal width used for marking proportions in the shader (metres).
# Roads in the same category may have slightly different widths from OSM,
# but markings are placed at the category's typical width.
const _CATEGORY_WIDTH: Dictionary = {
	"motorway":  12.0,
	"trunk":     10.0,
	"primary":    8.0,
	"secondary":  6.0,
	"tertiary":   5.0,
	"local":      4.0,
	"service":    3.0,
}

# Whether to draw a dashed centre line (bidirectional two-lane roads).
const _SHOW_CENTER_DASH: Dictionary = {
	"motorway":  false,
	"trunk":     false,
	"primary":   true,
	"secondary": true,
	"tertiary":  true,
	"local":     true,
	"service":   false,
}

# Whether to draw edge lines (not needed on service lanes).
const _SHOW_EDGE_LINES: Dictionary = {
	"motorway":  true,
	"trunk":     true,
	"primary":   true,
	"secondary": true,
	"tertiary":  true,
	"local":     true,
	"service":   false,
}

# Waterway flat-ribbon colors
const _WATERWAY_COLOUR: Dictionary = {
	"river":  Color(0.28, 0.52, 0.78),
	"canal":  Color(0.30, 0.48, 0.70),
	"stream": Color(0.40, 0.58, 0.80),
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

	# Separate road categories from waterway categories.
	var road_by_cat:  Dictionary = {}
	var water_by_cat: Dictionary = {}

	for feature in features:
		var props: Dictionary = feature.get("properties", {})
		var cat: String = str(props.get("category", ""))
		if cat.is_empty():
			continue
		if cat in _WATERWAY_CATEGORIES:
			if not water_by_cat.has(cat):
				water_by_cat[cat] = []
			water_by_cat[cat].append(feature)
		elif _CATEGORY_WIDTH.has(cat):
			if not road_by_cat.has(cat):
				road_by_cat[cat] = []
			road_by_cat[cat].append(feature)

	# Build road meshes (cross-section profile + road shader).
	var road_shader := load(ROAD_SHADER_PATH) as Shader
	for cat in road_by_cat:
		var mesh := _build_road_mesh(road_by_cat[cat])
		if mesh == null:
			continue
		var mat := ShaderMaterial.new()
		mat.shader = road_shader
		mat.set_shader_parameter("road_width",       _CATEGORY_WIDTH.get(cat, 4.0))
		mat.set_shader_parameter("show_center_dash", _SHOW_CENTER_DASH.get(cat, true))
		mat.set_shader_parameter("show_edge_lines",  _SHOW_EDGE_LINES.get(cat, true))
		var inst := MeshInstance3D.new()
		inst.mesh = mesh
		inst.set_surface_override_material(0, mat)
		add_child(inst)

	# Build waterway meshes (flat ribbon, water material).
	for cat in water_by_cat:
		var mesh := _build_waterway_mesh(water_by_cat[cat])
		if mesh == null:
			continue
		var mat := StandardMaterial3D.new()
		mat.albedo_color = _WATERWAY_COLOUR.get(cat, Color(0.3, 0.5, 0.75))
		mat.roughness    = 0.05
		mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		var inst := MeshInstance3D.new()
		inst.mesh = mesh
		inst.set_surface_override_material(0, mat)
		add_child(inst)

	print("RoadMeshSpawner: done. (%d road + %d waterway categories)" \
		% [road_by_cat.size(), water_by_cat.size()])


# ---------------------------------------------------------------------------
# Road mesh — cross-section profile with curbs
# ---------------------------------------------------------------------------

func _build_road_mesh(features: Array) -> ArrayMesh:
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

		var width: float  = float(props.get("width", 4.0))
		var bridge: bool  = bool(props.get("bridge", false))
		var layer: int    = int(props.get("layer", 0))

		var points := PackedVector2Array()
		for c in raw_coords:
			points.append(Vector2(float(c[0]), -float(c[1])))

		_add_road_profile(points, width, bridge, layer, vertices, normals, uvs, indices)

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


## Append a road with cross-section profile (left_curb_top, left_road,
## right_road, right_curb_top) to the shared vertex/index buffers.
##
## UV.x: -0.1 (left curb top), 0.0 (left road), 1.0 (right road), 1.1 (right curb top)
## UV.y: accumulated metres along centreline
##
## bridge=true  → linear height interpolation between endpoints, 1 m railings.
## bridge_layer → adds BRIDGE_LAYER_H metres of clearance per layer value.
func _add_road_profile(
	points:       PackedVector2Array,
	width:        float,
	bridge:       bool,
	bridge_layer: int,
	vertices:     PackedVector3Array,
	normals:      PackedVector3Array,
	uvs:          PackedVector2Array,
	indices:      PackedInt32Array,
) -> void:
	var n    := points.size()
	var half := width * 0.5
	var curb_h := BRIDGE_RAIL_H if bridge else CURB_H

	# For bridges, sample terrain only at the two endpoints.
	var h_start: float = 0.0
	var h_end:   float = 0.0
	if bridge and _terrain:
		h_start = _terrain.sample_height(points[0].x,     points[0].y)
		h_end   = _terrain.sample_height(points[n - 1].x, points[n - 1].y)
	var layer_offset: float = float(bridge_layer) * BRIDGE_LAYER_H

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
		perps[i] = Vector2(-dir.y, dir.x)   # 90° CCW → left side

	var u_accum: float = 0.0
	var base_idx: int  = vertices.size()

	for i in n:
		var p    := points[i]
		var perp := perps[i]

		var left  := p + perp * half    # left road edge (XZ)
		var right := p - perp * half    # right road edge (XZ)

		var yl: float
		var yr: float
		if bridge:
			var t := float(i) / float(max(n - 1, 1))
			var h: float = lerp(h_start, h_end, t) + Y_ROADS + layer_offset
			yl = h
			yr = h
		else:
			yl = (_terrain.sample_height(left.x,  left.y)  if _terrain else 0.0) + Y_ROADS
			yr = (_terrain.sample_height(right.x, right.y) if _terrain else 0.0) + Y_ROADS

		if i > 0:
			u_accum += (p - points[i - 1]).length()

		# Emit 4 vertices per ring:
		# [0] left_curb_top   [1] left_road   [2] right_road   [3] right_curb_top
		vertices.append(Vector3(left.x,  yl + curb_h, left.y))   # 0 left/rail top
		vertices.append(Vector3(left.x,  yl,          left.y))   # 1 left road edge
		vertices.append(Vector3(right.x, yr,          right.y))  # 2 right road edge
		vertices.append(Vector3(right.x, yr + curb_h, right.y))  # 3 right/rail top

		# Normals: curbs face outward, road faces up.
		normals.append(Vector3(-perp.x, 0.0, -perp.y).normalized())  # left curb outward
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		normals.append(Vector3( perp.x, 0.0,  perp.y).normalized())  # right curb outward

		uvs.append(Vector2(-0.1,  u_accum))   # left curb top
		uvs.append(Vector2( 0.0,  u_accum))   # left road edge
		uvs.append(Vector2( 1.0,  u_accum))   # right road edge
		uvs.append(Vector2( 1.1,  u_accum))   # right curb top

	# Connect consecutive rings with quads (6 triangles per step = 3 face strips).
	for i in n - 1:
		var a0: int = base_idx + i * 4 + 0   # left_curb_top[i]
		var a1: int = base_idx + i * 4 + 1   # left_road[i]
		var a2: int = base_idx + i * 4 + 2   # right_road[i]
		var a3: int = base_idx + i * 4 + 3   # right_curb_top[i]
		var b0: int = a0 + 4                  # left_curb_top[i+1]
		var b1: int = a1 + 4
		var b2: int = a2 + 4
		var b3: int = a3 + 4

		# Left curb face
		indices.append_array([a0, b0, b1, a0, b1, a1])
		# Road surface
		indices.append_array([a1, b1, b2, a1, b2, a2])
		# Right curb face
		indices.append_array([a2, b2, b3, a2, b3, a3])


# ---------------------------------------------------------------------------
# Waterway mesh — flat ribbon (unchanged approach)
# ---------------------------------------------------------------------------

func _build_waterway_mesh(features: Array) -> ArrayMesh:
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

		var points := PackedVector2Array()
		for c in raw_coords:
			points.append(Vector2(float(c[0]), -float(c[1])))

		_add_flat_ribbon(points, width, Y_WATERWAYS, vertices, normals, uvs, indices)

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


func _add_flat_ribbon(
	points:   PackedVector2Array,
	width:    float,
	y_base:   float,
	vertices: PackedVector3Array,
	normals:  PackedVector3Array,
	uvs:      PackedVector2Array,
	indices:  PackedInt32Array,
) -> void:
	var n    := points.size()
	var half := width * 0.5

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
		perps[i] = Vector2(-dir.y, dir.x)

	var u_accum: float = 0.0
	var base_idx: int  = vertices.size()

	for i in n:
		var p    := points[i]
		var perp := perps[i]
		var left  := p + perp * half
		var right := p - perp * half

		var yl: float = (_terrain.sample_height(left.x,  left.y)  if _terrain else 0.0) + y_base
		var yr: float = (_terrain.sample_height(right.x, right.y) if _terrain else 0.0) + y_base

		if i > 0:
			u_accum += (p - points[i - 1]).length()

		vertices.append(Vector3(left.x,  yl, left.y))
		vertices.append(Vector3(right.x, yr, right.y))
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		uvs.append(Vector2(0.0, u_accum / width))
		uvs.append(Vector2(1.0, u_accum / width))

	for i in n - 1:
		var a: int = base_idx + i * 2
		var b: int = a + 1
		var c: int = a + 2
		var d: int = a + 3
		indices.append_array([a, b, c, b, d, c])
