## ForestSpawner — scatters trees inside wood/forest landuse polygons using MultiMesh.
##
## Tree positions are generated on a jittered grid (GRID_SPACING metres) clipped to
## each polygon via Geometry2D.is_point_in_polygon().  All instances share one
## MultiMesh so the GPU renders them in a single draw call.
##
## Tree mesh (built procedurally):
##   Trunk  : thin box  0.4 × 2.5 × 0.4 m  (brown vertex colour)
##   Canopy : 6-sided cone 2.8 m radius, 5 m tall, base at Y=2.0 m (green)
##
## Coordinate convention matches Terrain.gd:
##   GeoJSON [x, y] = [UTM easting, UTM northing]  →  Godot [x, -y]
class_name ForestSpawner
extends Node3D

const LANDUSE_PATH   := "res://data/landuse.geojson"
const TREES_PATH     := "res://data/trees.geojson"
const GRID_SPACING   := 20.0   ## metres between tree slots
const GRID_JITTER    := 7.0    ## max random offset per slot
const MAX_PER_POLYGON := 1500  ## hard cap to bound load time on huge polygons
const SCALE_MIN      := 0.65
const SCALE_MAX      := 1.35

## Canopy colour variants — picked per-instance for visual variety.
const CANOPY_COLOURS: Array[Color] = [
	Color(0.12, 0.38, 0.10),
	Color(0.16, 0.42, 0.12),
	Color(0.10, 0.32, 0.09),
	Color(0.20, 0.45, 0.14),
]
const TRUNK_COLOUR := Color(0.32, 0.20, 0.09)

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
	if not FileAccess.file_exists(LANDUSE_PATH):
		push_warning("ForestSpawner: landuse.geojson not found — skipping.")
		return

	var file := FileAccess.open(LANDUSE_PATH, FileAccess.READ)
	var raw  := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(raw) != OK:
		push_error("ForestSpawner: failed to parse landuse.geojson")
		return

	var features: Array = json.data.get("features", [])

	# Collect all tree transforms across every wood polygon.
	var transforms: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 42  # deterministic

	for feature in features:
		var props: Dictionary = feature.get("properties", {})
		if str(props.get("type", "")) != "wood":
			continue

		var geom: Dictionary = feature.get("geometry", {})
		if geom.get("type") != "Polygon":
			continue

		var rings: Array = geom.get("coordinates", [])
		if rings.is_empty() or (rings[0] as Array).size() < 3:
			continue

		# Convert GeoJSON [utm_east, utm_north] → Godot XZ [east, -north]
		var ring := PackedVector2Array()
		for c in (rings[0] as Array):
			ring.append(Vector2(float(c[0]), -float(c[1])))

		_scatter_in_polygon(ring, rng, transforms)

	# Individual OSM trees (natural=tree nodes) — exact positions.
	_add_individual_trees(rng, transforms)

	if transforms.is_empty():
		return

	print("ForestSpawner: placing %d trees ..." % transforms.size())
	_build_multimesh(transforms)
	print("ForestSpawner: done.")


# ---------------------------------------------------------------------------
# Individual trees from trees.geojson
# ---------------------------------------------------------------------------

func _add_individual_trees(rng: RandomNumberGenerator, out: Array[Transform3D]) -> void:
	if not FileAccess.file_exists(TREES_PATH):
		return

	var file := FileAccess.open(TREES_PATH, FileAccess.READ)
	var raw  := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(raw) != OK:
		return

	var features: Array = json.data.get("features", [])
	var added := 0

	for feature in features:
		var geom: Dictionary = feature.get("geometry", {})
		if geom.get("type") != "Point":
			continue

		var coords: Array = geom.get("coordinates", [])
		var x := float(coords[0])
		var z := -float(coords[1])   # northing → Godot -Z

		var props: Dictionary = feature.get("properties", {})
		var raw_height        = props.get("height")
		var height_m: float   = float(raw_height) if raw_height != null else 0.0

		# Derive scale from height tag (default tree ≈ 7 m tall).
		var scale := rng.randf_range(SCALE_MIN, SCALE_MAX)
		if height_m > 0.0:
			scale = clampf(height_m / 7.0, 0.3, 3.0)

		var terrain_y: float = _terrain.sample_height(x, z) if _terrain else 0.0
		var yaw := rng.randf_range(0.0, TAU)
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3.ONE * scale)
		out.append(Transform3D(basis, Vector3(x, terrain_y, z)))
		added += 1

	print("ForestSpawner: %d individual trees added." % added)


# ---------------------------------------------------------------------------
# Point scattering inside a polygon
# ---------------------------------------------------------------------------

func _scatter_in_polygon(
	ring:       PackedVector2Array,
	rng:        RandomNumberGenerator,
	out:        Array[Transform3D],
) -> void:
	# Bounding box.
	var min_x := INF;  var max_x := -INF
	var min_y := INF;  var max_y := -INF
	for v in ring:
		min_x = minf(min_x, v.x);  max_x = maxf(max_x, v.x)
		min_y = minf(min_y, v.y);  max_y = maxf(max_y, v.y)

	var count := 0

	var gx := min_x
	while gx < max_x:
		var gy := min_y
		while gy < max_y:
			# Jitter inside the grid cell.
			var px := gx + rng.randf_range(-GRID_JITTER, GRID_JITTER)
			var py := gy + rng.randf_range(-GRID_JITTER, GRID_JITTER)
			var pt := Vector2(px, py)

			if Geometry2D.is_point_in_polygon(pt, ring):
				var terrain_y: float = _terrain.sample_height(px, py) if _terrain else 0.0
				var scale := rng.randf_range(SCALE_MIN, SCALE_MAX)
				var yaw   := rng.randf_range(0.0, TAU)

				var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3.ONE * scale)
				out.append(Transform3D(basis, Vector3(px, terrain_y, py)))
				count += 1
				if count >= MAX_PER_POLYGON:
					return

			gy += GRID_SPACING
		gx += GRID_SPACING


# ---------------------------------------------------------------------------
# MultiMesh construction
# ---------------------------------------------------------------------------

func _build_multimesh(transforms: Array[Transform3D]) -> void:
	var mm := MultiMesh.new()
	mm.transform_format    = MultiMesh.TRANSFORM_3D
	mm.use_custom_data     = false
	mm.use_colors          = true   # per-instance canopy colour variation
	mm.instance_count      = transforms.size()
	mm.mesh                = _build_tree_mesh()

	var rng := RandomNumberGenerator.new()
	rng.seed = 1337

	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, CANOPY_COLOURS[rng.randi() % CANOPY_COLOURS.size()])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)


# ---------------------------------------------------------------------------
# Procedural tree mesh
# ---------------------------------------------------------------------------

## Build a simple low-poly tree: box trunk + 6-sided cone canopy.
## Vertex colours encode trunk (brown) vs canopy (green) so one material suffices.
func _build_tree_mesh() -> ArrayMesh:
	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	_add_box(verts, normals, colours, indices,
		Vector3(0.0, 1.25, 0.0), 0.2, 2.5, 0.2, TRUNK_COLOUR)

	_add_cone(verts, normals, colours, indices,
		Vector3(0.0, 2.0, 0.0), 2.8, 5.0, 6, Color.WHITE)
	# Canopy colour comes from per-instance colour (mm.use_colors = true),
	# so we leave canopy vertex colour white — it gets multiplied at runtime.

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
	mat.roughness = 0.9
	arr_mesh.surface_set_material(0, mat)

	return arr_mesh


func _add_box(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	colours: PackedColorArray,
	indices: PackedInt32Array,
	center:  Vector3,
	sx:      float,
	sy:      float,
	sz:      float,
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


func _add_cone(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	colours: PackedColorArray,
	indices: PackedInt32Array,
	base_center: Vector3,
	radius:  float,
	height:  float,
	sides:   int,
	colour:  Color,
) -> void:
	var apex := base_center + Vector3(0.0, height, 0.0)
	var apex_idx := verts.size()
	verts.append(apex)
	normals.append(Vector3.UP)
	colours.append(colour)

	for i in sides:
		var angle := TAU * i / sides
		var v := base_center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		var v_next := base_center + Vector3(cos(TAU * (i+1) / sides) * radius, 0.0, sin(TAU * (i+1) / sides) * radius)
		var n := ((v - apex).cross(v_next - apex)).normalized()

		var b := verts.size()
		verts.append_array([apex, v, v_next])
		normals.append_array([n, n, n])
		colours.append_array([colour, colour, colour])
		indices.append_array([b, b+1, b+2])
