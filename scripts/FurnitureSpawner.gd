## FurnitureSpawner — places street furniture from furniture.geojson using MultiMesh.
##
## One MultiMeshInstance3D per furniture type; all geometry is procedural (no assets).
## Furniture is only visible within LOD_MAX_M — too small to render at distance.
##
## Types (from OSM tags, see extract_furniture.py):
##   lamp     — street lamp: pole + horizontal arm + light globe
##   bin      — waste basket: stubby box
##   bench    — park bench: seat + backrest + two legs
##   bus_stop — bus stop: pole + rectangular sign panel
##   bike     — bicycle rack: horizontal bar + two posts
##
## Orientation:
##   If the OSM "direction" property is set (degrees from north, clockwise),
##   the furniture is rotated to face that bearing.
##   Otherwise a deterministic pseudo-random yaw is used.
##
## Coordinate convention matches Terrain.gd:
##   GeoJSON [x, y] = [UTM easting, UTM northing]  →  Godot [x, -y]
class_name FurnitureSpawner
extends Node3D

const FURNITURE_PATH := "res://data/furniture.geojson"
const LOD_MAX_M      := 300.0   ## furniture hidden beyond this distance (metres)

@onready var _terrain: Terrain = get_node("../Terrain")

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
	if not FileAccess.file_exists(FURNITURE_PATH):
		push_warning("FurnitureSpawner: furniture.geojson not found — skipping.")
		return

	var file := FileAccess.open(FURNITURE_PATH, FileAccess.READ)
	var raw  := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(raw) != OK:
		push_error("FurnitureSpawner: failed to parse furniture.geojson")
		return

	var features: Array = json.data.get("features", [])
	print("FurnitureSpawner: loading %d items ..." % features.size())

	# Group transforms by type.
	var by_type: Dictionary = {}   # type → Array[Transform3D]
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED_F00D

	for feature in features:
		var props: Dictionary = feature.get("properties", {})
		var ftype: String = str(props.get("type", ""))
		if ftype.is_empty():
			continue

		var geom: Dictionary = feature.get("geometry", {})
		if geom.get("type") != "Point":
			continue

		var coords: Array = geom.get("coordinates", [])
		var x := float(coords[0])
		var z := -float(coords[1])
		var terrain_y: float = _terrain.sample_height(x, z) if _terrain else 0.0

		# Yaw from OSM direction tag (degrees from north, clockwise).
		var raw_dir = props.get("direction")
		var yaw: float
		if raw_dir != null and typeof(raw_dir) in [TYPE_INT, TYPE_FLOAT]:
			yaw = PI - deg_to_rad(float(raw_dir))
		else:
			yaw = rng.randf_range(0.0, TAU)

		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
		var xform := Transform3D(basis, Vector3(x, terrain_y, z))

		if not by_type.has(ftype):
			by_type[ftype] = []
		(by_type[ftype] as Array).append(xform)

	# Build one MultiMeshInstance3D per type.
	var total := 0
	for ftype in by_type:
		var xforms: Array = by_type[ftype]
		var mesh := _build_mesh(ftype)
		if mesh == null:
			continue

		var typed: Array[Transform3D] = []
		for x in xforms:
			typed.append(x)

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors       = false
		mm.use_custom_data  = false
		mm.instance_count   = typed.size()
		mm.mesh             = mesh
		for i in typed.size():
			mm.set_instance_transform(i, typed[i])

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh                  = mm
		mmi.visibility_range_end       = LOD_MAX_M
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		add_child(mmi)
		total += typed.size()

	print("FurnitureSpawner: done. (%d items placed)" % total)


# ---------------------------------------------------------------------------
# Mesh dispatch
# ---------------------------------------------------------------------------

func _build_mesh(ftype: String) -> ArrayMesh:
	match ftype:
		"lamp":     return _build_lamp_mesh()
		"bin":      return _build_bin_mesh()
		"bench":    return _build_bench_mesh()
		"bus_stop": return _build_bus_stop_mesh()
		"bike":     return _build_bike_mesh()
	return null


# ---------------------------------------------------------------------------
# Procedural mesh builders
# ---------------------------------------------------------------------------

## Street lamp: vertical pole + short horizontal arm + light globe.
func _build_lamp_mesh() -> ArrayMesh:
	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	var POLE_GREY  := Color(0.38, 0.38, 0.38)
	var LIGHT_WARM := Color(0.95, 0.88, 0.55)

	# Pole: 0.08 × 4.8 × 0.08, centred vertically
	_add_box(verts, normals, colours, indices,
		Vector3(0.0, 2.4, 0.0), 0.08, 4.8, 0.08, POLE_GREY)
	# Arm: 0.7 × 0.06 × 0.06, extending in +X from pole top
	_add_box(verts, normals, colours, indices,
		Vector3(0.35, 4.7, 0.0), 0.7, 0.06, 0.06, POLE_GREY)
	# Light globe: 0.22 × 0.22 × 0.22 at arm end
	_add_box(verts, normals, colours, indices,
		Vector3(0.7, 4.65, 0.0), 0.22, 0.22, 0.22, LIGHT_WARM)

	return _finalize_mesh(verts, normals, colours, indices)


## Waste basket: simple squat box.
func _build_bin_mesh() -> ArrayMesh:
	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	_add_box(verts, normals, colours, indices,
		Vector3(0.0, 0.42, 0.0), 0.38, 0.84, 0.38, Color(0.27, 0.27, 0.27))

	return _finalize_mesh(verts, normals, colours, indices)


## Park bench: seat + backrest + two legs.
func _build_bench_mesh() -> ArrayMesh:
	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	var WOOD  := Color(0.42, 0.26, 0.10)
	var METAL := Color(0.40, 0.40, 0.40)

	# Seat
	_add_box(verts, normals, colours, indices,
		Vector3(0.0, 0.46, 0.0), 1.50, 0.05, 0.40, WOOD)
	# Backrest
	_add_box(verts, normals, colours, indices,
		Vector3(0.0, 0.70, -0.18), 1.50, 0.38, 0.05, WOOD)
	# Left leg
	_add_box(verts, normals, colours, indices,
		Vector3(-0.65, 0.23, 0.0), 0.05, 0.46, 0.38, METAL)
	# Right leg
	_add_box(verts, normals, colours, indices,
		Vector3( 0.65, 0.23, 0.0), 0.05, 0.46, 0.38, METAL)

	return _finalize_mesh(verts, normals, colours, indices)


## Bus stop: tall pole + rectangular sign panel.
func _build_bus_stop_mesh() -> ArrayMesh:
	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	var GREY := Color(0.55, 0.55, 0.55)
	# SMTC TAG (Grenoble) livery: green-teal
	var PANEL := Color(0.08, 0.48, 0.32)

	# Pole
	_add_box(verts, normals, colours, indices,
		Vector3(0.0, 1.25, 0.0), 0.06, 2.50, 0.06, GREY)
	# Sign panel
	_add_box(verts, normals, colours, indices,
		Vector3(0.0, 2.58, 0.0), 0.36, 0.28, 0.04, PANEL)

	return _finalize_mesh(verts, normals, colours, indices)


## Bicycle rack: horizontal top bar + two side posts.
func _build_bike_mesh() -> ArrayMesh:
	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	var STEEL := Color(0.48, 0.48, 0.52)

	# Top bar
	_add_box(verts, normals, colours, indices,
		Vector3(0.0, 0.90, 0.0), 1.50, 0.06, 0.06, STEEL)
	# Left post
	_add_box(verts, normals, colours, indices,
		Vector3(-0.72, 0.45, 0.0), 0.06, 0.90, 0.06, STEEL)
	# Right post
	_add_box(verts, normals, colours, indices,
		Vector3( 0.72, 0.45, 0.0), 0.06, 0.90, 0.06, STEEL)

	return _finalize_mesh(verts, normals, colours, indices)


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

func _add_box(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	colours: PackedColorArray,
	indices: PackedInt32Array,
	center:  Vector3,
	sx: float, sy: float, sz: float,
	colour:  Color,
) -> void:
	var hx := sx * 0.5;  var hy := sy * 0.5;  var hz := sz * 0.5
	var faces: Array = [
		[Vector3(-1,0,0), [Vector3(-hx,-hy,-hz), Vector3(-hx,-hy, hz), Vector3(-hx, hy, hz), Vector3(-hx, hy,-hz)]],
		[Vector3( 1,0,0), [Vector3( hx,-hy, hz), Vector3( hx,-hy,-hz), Vector3( hx, hy,-hz), Vector3( hx, hy, hz)]],
		[Vector3(0,-1,0), [Vector3(-hx,-hy, hz), Vector3(-hx,-hy,-hz), Vector3( hx,-hy,-hz), Vector3( hx,-hy, hz)]],
		[Vector3(0, 1,0), [Vector3(-hx, hy,-hz), Vector3(-hx, hy, hz), Vector3( hx, hy, hz), Vector3( hx, hy,-hz)]],
		[Vector3(0,0,-1), [Vector3( hx,-hy,-hz), Vector3(-hx,-hy,-hz), Vector3(-hx, hy,-hz), Vector3( hx, hy,-hz)]],
		[Vector3(0,0, 1), [Vector3(-hx,-hy, hz), Vector3( hx,-hy, hz), Vector3( hx, hy, hz), Vector3(-hx, hy, hz)]],
	]
	for face in faces:
		var n: Vector3 = face[0]
		var corners: Array = face[1]
		var base := verts.size()
		for c in corners:
			verts.append(center + c)
			normals.append(n)
			colours.append(colour)
		indices.append_array([base, base+1, base+2, base, base+2, base+3])


func _finalize_mesh(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	colours: PackedColorArray,
	indices: PackedInt32Array,
) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR]  = colours
	arrays[Mesh.ARRAY_INDEX]  = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	arr_mesh.surface_set_material(0, mat)
	return arr_mesh
