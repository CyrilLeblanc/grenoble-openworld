## ForestSpawner — scatters trees inside wood/forest landuse polygons and places
## individual OSM trees (natural=tree) at their exact surveyed positions.
##
## Tree types (3 distinct mesh silhouettes):
##   GENERIC  — default deciduous: moderate cone, 6 sides, radius 2.8 m, height 5 m
##   CONIFER  — Pinus / Picea / Abies / …: tall narrow cone, 8 sides, radius 1.5 m, height 9 m
##   BROAD    — Platanus / Acer / Tilia / …: wide flat crown, 8 sides, radius 4.5 m, height 3.5 m
##
## Individual OSM trees use:
##   genus          → mesh type
##   height         → Y scale (relative to each type's canonical height)
##   diameter_crown → XZ scale (if present, independent of height scale)
##   circumference  → trunk radius (visual only — trunk box X/Z)
##   start_date     → age factor: young trees are smaller
##
## Forest-polygon scatter uses GENERIC with uniform random scale.
##
## LOD (per chunk):
##   Near  (< LOD_TREE_3D_M)      : full 3D mesh  (MultiMeshInstance3D)
##   Far   (< LOD_TREE_BILLBOARD_M): vertical quad billboard
##
## Coordinate convention matches Terrain.gd:
##   GeoJSON [x, y] = [UTM easting, UTM northing]  →  Godot [x, -y]
class_name ForestSpawner
extends Node3D

const LANDUSE_PATH    := "res://data/landuse.geojson"
const TREES_PATH      := "res://data/trees.geojson"
const GRID_SPACING    := 20.0    ## metres between tree slots in forest polygons
const GRID_JITTER     := 7.0     ## max random XZ offset per slot
const MAX_PER_POLYGON := 1500    ## hard cap per wood polygon

const SCALE_MIN := 0.65
const SCALE_MAX := 1.35

# ---------------------------------------------------------------------------
# Tree types
# ---------------------------------------------------------------------------

enum TreeType { GENERIC, CONIFER, BROAD }

## Canonical height of each mesh type (used to compute Y scale from height tag).
const _CANONICAL_H: Dictionary = {
	TreeType.GENERIC: 7.0,
	TreeType.CONIFER: 12.0,
	TreeType.BROAD:   9.0,
}

## Canonical canopy radius (used to compute XZ scale from diameter_crown).
const _CANONICAL_R: Dictionary = {
	TreeType.GENERIC: 2.8,
	TreeType.CONIFER: 1.5,
	TreeType.BROAD:   4.5,
}

## Genera that map to CONIFER (case-insensitive first-word of species/genus tag).
const _CONIFER_GENERA: Array = [
	"pinus", "picea", "abies", "cedrus", "larix", "cupressus",
	"thuja", "pseudotsuga", "sequoia", "taxus", "juniperus",
]

## Genera that map to BROAD.
const _BROAD_GENERA: Array = [
	"platanus", "acer", "tilia", "fraxinus", "salix",
	"populus", "quercus", "ulmus", "betula", "fagus",
]

# ---------------------------------------------------------------------------
# Per-type canopy colour palettes
# ---------------------------------------------------------------------------

const _COLOURS: Dictionary = {
	TreeType.GENERIC: [
		Color(0.12, 0.38, 0.10),
		Color(0.16, 0.42, 0.12),
		Color(0.10, 0.32, 0.09),
		Color(0.20, 0.45, 0.14),
	],
	TreeType.CONIFER: [
		Color(0.06, 0.22, 0.07),
		Color(0.08, 0.26, 0.09),
		Color(0.05, 0.18, 0.06),
		Color(0.09, 0.28, 0.10),
	],
	TreeType.BROAD: [
		Color(0.25, 0.50, 0.15),
		Color(0.28, 0.54, 0.17),
		Color(0.22, 0.46, 0.13),
		Color(0.30, 0.56, 0.18),
	],
}

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

	# Per-type transform arrays.
	var type_transforms: Dictionary = {
		TreeType.GENERIC: [],
		TreeType.CONIFER: [],
		TreeType.BROAD:   [],
	}

	var rng := RandomNumberGenerator.new()
	rng.seed = 42

	# Forest-polygon scatter → generic only (no genus data on area polygons).
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

		var ring := PackedVector2Array()
		for c in (rings[0] as Array):
			ring.append(Vector2(float(c[0]), -float(c[1])))

		_scatter_in_polygon(ring, rng, type_transforms[TreeType.GENERIC])

	# Individual OSM trees → genus-dispatched type + non-uniform scale.
	_add_individual_trees(rng, type_transforms)

	var total := 0
	for t in type_transforms:
		total += (type_transforms[t] as Array).size()
	print("ForestSpawner: placing %d trees ..." % total)

	for tree_type in type_transforms:
		var xforms: Array = type_transforms[tree_type]
		if xforms.is_empty():
			continue
		var typed: Array[Transform3D] = []
		for x in xforms:
			typed.append(x)
		_build_lod_multimeshes(typed, tree_type)

	print("ForestSpawner: done.")


# ---------------------------------------------------------------------------
# Individual trees from trees.geojson
# ---------------------------------------------------------------------------

func _add_individual_trees(
	rng:             RandomNumberGenerator,
	type_transforms: Dictionary,
) -> void:
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
		var z := -float(coords[1])

		var props: Dictionary = feature.get("properties", {})

		# Determine mesh type from genus.
		var genus: String = str(props.get("genus", "")).to_lower()
		var tree_type := _genus_to_type(genus)

		# Height → Y scale.
		var raw_h = props.get("height")
		var height_m: float = float(raw_h) if raw_h != null else 0.0
		var canonical_h: float = _CANONICAL_H[tree_type]
		var scale_y: float = rng.randf_range(SCALE_MIN, SCALE_MAX)
		if height_m > 0.0:
			scale_y = clampf(height_m / canonical_h, 0.3, 3.5)

		# diameter_crown → independent XZ scale.
		var raw_dc = props.get("diameter_crown")
		var diam_crown: float = float(raw_dc) if raw_dc != null else 0.0
		var scale_xz: float = scale_y   # default: uniform
		if diam_crown > 0.0:
			var canonical_r: float = _CANONICAL_R[tree_type]
			scale_xz = clampf(diam_crown * 0.5 / canonical_r, 0.3, 3.5)

		# start_date → age factor (saplings are smaller).
		var start_raw: String = str(props.get("start_date", ""))
		if start_raw.length() >= 4 and start_raw.substr(0, 4).is_valid_int():
			var year := int(start_raw.substr(0, 4))
			if year > 1900:
				var age := 2025 - year
				var age_factor := clampf(float(age) / 50.0, 0.25, 1.0)
				scale_y  *= age_factor
				scale_xz *= age_factor

		var terrain_y: float = _terrain.sample_height(x, z) if _terrain else 0.0
		var yaw := rng.randf_range(0.0, TAU)
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(
			Vector3(scale_xz, scale_y, scale_xz)
		)
		(type_transforms[tree_type] as Array).append(Transform3D(basis, Vector3(x, terrain_y, z)))
		added += 1

	print("ForestSpawner: %d individual trees added." % added)


# ---------------------------------------------------------------------------
# Genus → tree type
# ---------------------------------------------------------------------------

func _genus_to_type(genus_lower: String) -> TreeType:
	if genus_lower in _CONIFER_GENERA:
		return TreeType.CONIFER
	if genus_lower in _BROAD_GENERA:
		return TreeType.BROAD
	return TreeType.GENERIC


# ---------------------------------------------------------------------------
# Point scattering inside a polygon
# ---------------------------------------------------------------------------

func _scatter_in_polygon(
	ring: PackedVector2Array,
	rng:  RandomNumberGenerator,
	out:  Array,
) -> void:
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
# LOD MultiMesh construction
# ---------------------------------------------------------------------------

func _build_lod_multimeshes(all_transforms: Array[Transform3D], tree_type: TreeType) -> void:
	var by_chunk: Dictionary = {}
	for xform in all_transforms:
		var key := Vector2i(
			int(floor(xform.origin.x / WorldConfig.CHUNK_SIZE_M)),
			int(floor(xform.origin.z / WorldConfig.CHUNK_SIZE_M)),
		)
		if not by_chunk.has(key):
			by_chunk[key] = []
		by_chunk[key].append(xform)

	var near_mesh := _build_tree_mesh(tree_type)
	var far_mesh  := _build_billboard_mesh()
	var colours: Array = _COLOURS[tree_type]
	var rng := RandomNumberGenerator.new()

	for chunk_key in by_chunk:
		var chunk_xforms: Array = by_chunk[chunk_key]
		var chunk_origin := Vector3(
			(chunk_key.x + 0.5) * WorldConfig.CHUNK_SIZE_M,
			0.0,
			(chunk_key.y + 0.5) * WorldConfig.CHUNK_SIZE_M,
		)

		var local_xforms: Array[Transform3D] = []
		for xform in chunk_xforms:
			local_xforms.append(Transform3D(xform.basis, xform.origin - chunk_origin))

		rng.seed = hash(chunk_key) ^ (0xF00DCAFE + int(tree_type))

		# Near: full 3D mesh.
		var mm_near := _make_multimesh(local_xforms, near_mesh, colours, rng)
		var mmi_near := MultiMeshInstance3D.new()
		mmi_near.multimesh                  = mm_near
		mmi_near.position                   = chunk_origin
		mmi_near.visibility_range_end       = WorldConfig.LOD_TREE_3D_M
		mmi_near.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		add_child(mmi_near)

		# Far: billboard, same seed so colours match.
		rng.seed = hash(chunk_key) ^ (0xF00DCAFE + int(tree_type))
		var mm_far := _make_multimesh(local_xforms, far_mesh, colours, rng)
		var mmi_far := MultiMeshInstance3D.new()
		mmi_far.multimesh                   = mm_far
		mmi_far.position                    = chunk_origin
		mmi_far.visibility_range_begin      = WorldConfig.LOD_TREE_3D_M
		mmi_far.visibility_range_end        = WorldConfig.LOD_TREE_BILLBOARD_M
		mmi_far.visibility_range_fade_mode  = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		add_child(mmi_far)


func _make_multimesh(
	xforms:  Array[Transform3D],
	mesh:    Mesh,
	colours: Array,
	rng:     RandomNumberGenerator,
) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors       = true
	mm.use_custom_data  = false
	mm.instance_count   = xforms.size()
	mm.mesh             = mesh
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colours[rng.randi() % colours.size()])
	return mm


# ---------------------------------------------------------------------------
# Billboard mesh (shared across tree types — transform scale handles variation)
# ---------------------------------------------------------------------------

func _build_billboard_mesh() -> ArrayMesh:
	var hw := 2.8
	var h  := 7.0

	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	verts.append_array([
		Vector3(-hw, 0.0, 0.0), Vector3(hw, 0.0, 0.0),
		Vector3(hw, h, 0.0),    Vector3(-hw, h, 0.0),
	])
	for _i in 4:
		normals.append(Vector3.BACK)
		colours.append(Color.WHITE)
	indices.append_array([0, 1, 2, 0, 2, 3])

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
	mat.roughness                  = 0.9
	mat.billboard_mode             = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	arr_mesh.surface_set_material(0, mat)
	return arr_mesh


# ---------------------------------------------------------------------------
# Procedural tree meshes
# ---------------------------------------------------------------------------

func _build_tree_mesh(tree_type: TreeType) -> ArrayMesh:
	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	match tree_type:
		TreeType.CONIFER:
			# Tall narrow cone — trunk starts at ground, canopy from y=0.5
			_add_box(verts, normals, colours, indices,
				Vector3(0.0, 3.0, 0.0), 0.15, 6.0, 0.15, TRUNK_COLOUR)
			_add_cone(verts, normals, colours, indices,
				Vector3(0.0, 0.5, 0.0), 1.5, 9.0, 8, Color.WHITE)
		TreeType.BROAD:
			# Wide spreading crown — high trunk, low flat canopy
			_add_box(verts, normals, colours, indices,
				Vector3(0.0, 2.5, 0.0), 0.30, 5.0, 0.30, TRUNK_COLOUR)
			_add_cone(verts, normals, colours, indices,
				Vector3(0.0, 4.0, 0.0), 4.5, 3.5, 10, Color.WHITE)
		_: # GENERIC / deciduous
			_add_box(verts, normals, colours, indices,
				Vector3(0.0, 1.25, 0.0), 0.20, 2.5, 0.20, TRUNK_COLOUR)
			_add_cone(verts, normals, colours, indices,
				Vector3(0.0, 2.0, 0.0), 2.8, 5.0, 6, Color.WHITE)

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


func _add_cone(
	verts:       PackedVector3Array,
	normals:     PackedVector3Array,
	colours:     PackedColorArray,
	indices:     PackedInt32Array,
	base_center: Vector3,
	radius: float, height: float, sides: int,
	colour: Color,
) -> void:
	var apex := base_center + Vector3(0.0, height, 0.0)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var v0 := base_center + Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var v1 := base_center + Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		var n  := ((v0 - apex).cross(v1 - apex)).normalized()
		var b  := verts.size()
		verts.append_array([apex, v0, v1])
		normals.append_array([n, n, n])
		colours.append_array([colour, colour, colour])
		indices.append_array([b, b+1, b+2])
