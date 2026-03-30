## Terrain — builds and owns the terrain mesh from a heightmap PNG.
##
## Attach to a MeshInstance3D node.
## The mesh is generated once at startup; streaming is handled by ChunkManager
## in later phases.
class_name Terrain
extends MeshInstance3D

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

## Path to the 16-bit greyscale heightmap inside res://
const HEIGHTMAP_PATH := "res://data/heightmap.png"

## Number of subdivisions per axis on the terrain quad.
## 512 gives ~260k quads — enough for Phase 1.
@export var mesh_subdivisions: int = 512

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _image: Image  # kept alive for sample_height()

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_image = _load_heightmap()
	if _image == null:
		push_error("Terrain: could not load heightmap at %s" % HEIGHTMAP_PATH)
		return

	mesh = _build_mesh(_image)
	mesh.surface_set_material(0, _make_material())
	_attach_collision(_image)

	# Defer so all sibling _ready() calls finish before listeners connect.
	call_deferred("_notify_world_ready")


func _notify_world_ready() -> void:
	WorldEvents.world_data_ready.emit()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Return the terrain elevation (metres) at the given world-space XZ position.
## X = east, Z = south (Godot convention, origin = world centre).
func sample_height(x: float, z: float) -> float:
	if _image == null:
		return 0.0

	var u: float = clamp(x / WorldConfig.world_width_m + 0.5, 0.0, 1.0)
	var v: float = clamp(z / WorldConfig.world_height_m + 0.5, 0.0, 1.0)

	var px := clampi(int(u * _image.get_width()),  0, _image.get_width()  - 1)
	var py := clampi(int(v * _image.get_height()), 0, _image.get_height() - 1)

	return _image.get_pixel(px, py).r * WorldConfig.elevation_range_m


# ---------------------------------------------------------------------------
# Heightmap loading
# ---------------------------------------------------------------------------

func _load_heightmap() -> Image:
	var img := Image.new()
	if img.load(HEIGHTMAP_PATH) != OK:
		return null
	return img


# ---------------------------------------------------------------------------
# Mesh generation
# ---------------------------------------------------------------------------

func _build_mesh(image: Image) -> ArrayMesh:
	var width_m:    float = WorldConfig.world_width_m
	var height_m:   float = WorldConfig.world_height_m
	var elev_range: float = WorldConfig.elevation_range_m

	var subdivs:        int = mesh_subdivisions
	var verts_per_side: int = subdivs + 1

	var vertices := PackedVector3Array()
	var normals  := PackedVector3Array()
	var uvs      := PackedVector2Array()
	var indices  := PackedInt32Array()

	vertices.resize(verts_per_side * verts_per_side)
	normals.resize(verts_per_side * verts_per_side)
	uvs.resize(verts_per_side * verts_per_side)

	var img_w: int = image.get_width()
	var img_h: int = image.get_height()

	for row in verts_per_side:
		for col in verts_per_side:
			var u: float = float(col) / subdivs
			var v: float = float(row) / subdivs

			var px: int = clampi(int(u * img_w), 0, img_w - 1)
			var py: int = clampi(int(v * img_h), 0, img_h - 1)
			var elevation_m: float = image.get_pixel(px, py).r * elev_range

			# X = east, Z = south (Godot convention), origin = world centre
			var x: float = (u - 0.5) * width_m
			var z: float = (v - 0.5) * height_m

			var idx: int = row * verts_per_side + col
			vertices[idx] = Vector3(x, elevation_m, z)
			uvs[idx]      = Vector2(u, v)

	for row in subdivs:
		for col in subdivs:
			var tl: int = row * verts_per_side + col
			var tr: int = tl + 1
			var bl: int = tl + verts_per_side
			var br: int = bl + 1
			indices.append_array([tl, bl, tr, tr, bl, br])

	normals = _compute_normals(vertices, indices, verts_per_side * verts_per_side)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return arr_mesh


func _compute_normals(
		vertices: PackedVector3Array,
		indices:  PackedInt32Array,
		vertex_count: int,
) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertex_count)

	for i in range(0, indices.size(), 3):
		var a := vertices[indices[i]]
		var b := vertices[indices[i + 1]]
		var c := vertices[indices[i + 2]]
		var face_normal := (b - a).cross(c - a)
		normals[indices[i]]     += face_normal
		normals[indices[i + 1]] += face_normal
		normals[indices[i + 2]] += face_normal

	for i in vertex_count:
		normals[i] = normals[i].normalized()

	return normals


# ---------------------------------------------------------------------------
# Collision
# ---------------------------------------------------------------------------

func _attach_collision(image: Image) -> void:
	var shape := HeightMapShape3D.new()
	var size: int = mesh_subdivisions + 1
	var map_data := PackedFloat32Array()
	map_data.resize(size * size)

	var img_w: int = image.get_width()
	var img_h: int = image.get_height()
	var elev_range: float = WorldConfig.elevation_range_m

	for row in size:
		for col in size:
			var u: float = float(col) / mesh_subdivisions
			var v: float = float(row) / mesh_subdivisions
			var px: int = clampi(int(u * img_w), 0, img_w - 1)
			var py: int = clampi(int(v * img_h), 0, img_h - 1)
			map_data[row * size + col] = image.get_pixel(px, py).r * elev_range

	shape.map_width = size
	shape.map_depth = size
	shape.map_data  = map_data

	var body      := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	add_child(body)


# ---------------------------------------------------------------------------
# Material
# ---------------------------------------------------------------------------

func _make_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_FRONT

	const TEXTURE_PATH := "res://data/terrain_texture.png"
	if FileAccess.file_exists(TEXTURE_PATH):
		var img := Image.new()
		if img.load(TEXTURE_PATH) == OK:
			mat.albedo_texture        = ImageTexture.create_from_image(img)
			mat.texture_filter        = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			mat.albedo_color          = Color.WHITE  # no tint — show texture as-is
	else:
		mat.albedo_color = Color(0.38, 0.52, 0.28)  # fallback: earthy green

	return mat
