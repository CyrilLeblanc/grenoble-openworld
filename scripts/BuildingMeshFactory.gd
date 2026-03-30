## BuildingMeshFactory — generates an extruded polygon mesh from a building footprint.
##
## The mesh has two named surfaces so the caller can apply separate materials:
##   SURFACE_WALLS — vertical faces (wall colour)
##   SURFACE_ROOF  — horizontal caps: roof + underside of floating parts (roof colour)
##
## Supports the OSM Simple 3D Buildings spec:
##   min_height_m — base of the extrusion above local ground (default 0)
##   height_m     — top of the extrusion above local ground
##
## The mesh is centred at the local XZ origin; the caller positions the
## MeshInstance3D at the building's world location.
##
## UV mapping (world-space scale, UV_SCALE metres per tile):
##   Walls: U = horizontal distance along perimeter, V = height from base
##   Roof:  planar XZ projection
class_name BuildingMeshFactory

const SURFACE_WALLS: int = 0
const SURFACE_ROOF:  int = 1

## Textures tile every UV_SCALE metres (≈ 1 floor height).
const UV_SCALE: float = 3.0


## Build and return an ArrayMesh for one building or building part.
##
## ring_xz      — exterior footprint, relative to centroid, in Godot XZ.
## height_m     — top of extrusion in local Y (metres above ground).
## min_height_m — base of extrusion in local Y (default 0 = ground level).
static func build(
	ring_xz:      PackedVector2Array,
	height_m:     float,
	min_height_m: float = 0.0,
) -> ArrayMesh:
	if ring_xz.size() < 3 or height_m <= min_height_m:
		return null

	# --- Surface 0: walls ---
	var wall_verts   := PackedVector3Array()
	var wall_normals := PackedVector3Array()
	var wall_uvs     := PackedVector2Array()
	var wall_indices := PackedInt32Array()
	_add_walls(ring_xz, height_m, min_height_m, wall_verts, wall_normals, wall_uvs, wall_indices)

	# --- Surface 1: roof + optional bottom cap ---
	var cap_verts   := PackedVector3Array()
	var cap_normals := PackedVector3Array()
	var cap_uvs     := PackedVector2Array()
	var cap_indices := PackedInt32Array()
	_add_cap(ring_xz, height_m,     Vector3.UP,   cap_verts, cap_normals, cap_uvs, cap_indices)
	if min_height_m > 0.0:
		_add_cap(ring_xz, min_height_m, Vector3.DOWN, cap_verts, cap_normals, cap_uvs, cap_indices)

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _pack(wall_verts, wall_normals, wall_uvs, wall_indices))
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _pack(cap_verts,  cap_normals,  cap_uvs,  cap_indices))
	return arr_mesh


# ---------------------------------------------------------------------------
# Walls
# ---------------------------------------------------------------------------

static func _add_walls(
	ring:         PackedVector2Array,
	height_m:     float,
	min_height_m: float,
	vertices:     PackedVector3Array,
	normals:      PackedVector3Array,
	uvs:          PackedVector2Array,
	indices:      PackedInt32Array,
) -> void:
	var centroid := _centroid(ring)
	var n := ring.size()
	var wall_height: float = height_m - min_height_m
	var u_offset: float = 0.0

	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]

		var v0 := Vector3(a.x, min_height_m, a.y)
		var v1 := Vector3(b.x, min_height_m, b.y)
		var v2 := Vector3(b.x, height_m,     b.y)
		var v3 := Vector3(a.x, height_m,     a.y)

		var edge             := v1 - v0
		var candidate_normal := Vector3(-edge.z, 0.0, edge.x).normalized()
		var mid              := (v0 + v1) * 0.5
		var to_outside       := mid - Vector3(centroid.x, mid.y, centroid.y)
		if candidate_normal.dot(to_outside) < 0.0:
			candidate_normal = -candidate_normal

		var face_normal := (v1 - v0).cross(v2 - v0)
		var base := vertices.size()
		vertices.append_array([v0, v1, v2, v3])
		normals.append_array([candidate_normal, candidate_normal, candidate_normal, candidate_normal])

		var edge_len: float = Vector2(b.x - a.x, b.y - a.y).length()
		var u0_f := u_offset / UV_SCALE
		var u1_f := (u_offset + edge_len) / UV_SCALE
		var v_bot := 0.0
		var v_top := wall_height / UV_SCALE
		uvs.append_array([
			Vector2(u0_f, v_bot),
			Vector2(u1_f, v_bot),
			Vector2(u1_f, v_top),
			Vector2(u0_f, v_top),
		])
		u_offset += edge_len

		if face_normal.dot(candidate_normal) >= 0.0:
			indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
		else:
			indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


# ---------------------------------------------------------------------------
# Horizontal cap (roof or bottom)
# ---------------------------------------------------------------------------

static func _add_cap(
	ring:       PackedVector2Array,
	y:          float,
	normal_dir: Vector3,
	vertices:   PackedVector3Array,
	normals:    PackedVector3Array,
	uvs:        PackedVector2Array,
	indices:    PackedInt32Array,
) -> void:
	var tris := Geometry2D.triangulate_polygon(ring)
	if tris.is_empty():
		return

	var base := vertices.size()
	for v in ring:
		vertices.append(Vector3(v.x, y, v.y))
		normals.append(normal_dir)
		uvs.append(Vector2(v.x, v.y) / UV_SCALE)

	var a := vertices[base + tris[0]]
	var b := vertices[base + tris[1]]
	var c := vertices[base + tris[2]]
	var faces_correct: bool = (b - a).cross(c - a).dot(normal_dir) > 0.0

	for i in range(0, tris.size(), 3):
		if faces_correct:
			indices.append_array([base + tris[i], base + tris[i + 1], base + tris[i + 2]])
		else:
			indices.append_array([base + tris[i], base + tris[i + 2], base + tris[i + 1]])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _pack(
	vertices: PackedVector3Array,
	normals:  PackedVector3Array,
	uvs:      PackedVector2Array,
	indices:  PackedInt32Array,
) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices
	return arrays


static func _centroid(ring: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for v in ring:
		sum += v
	return sum / ring.size()
