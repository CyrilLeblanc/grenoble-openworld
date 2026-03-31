## BuildingMaterialLibrary — maps OSM building tags to wall/roof materials.
##
## Wall materials use facade.gdshader for procedural windows + doors.
## Roof materials stay as StandardMaterial3D (flat colour).
##
## Priority:
##   1. building=  type → select visual profile (window proportions, colours)
##   2. building:material → select surface pattern (brick/stone/concrete/glass/metal)
##   3. building:colour → colour tint applied on top of the facade shader
##   4. Default profile if nothing matches
##
## Materials are cached to avoid duplicates across thousands of buildings.
class_name BuildingMaterialLibrary

const _FACADE_SHADER_PATH := "res://shaders/facade.gdshader"
const _FACADE_ATLAS_PATH  := "res://data/facade_atlas.png"

# ---------------------------------------------------------------------------
# Visual profiles — wall shader params + roof colour
# ---------------------------------------------------------------------------

const _PROFILES: Dictionary = {
	"residential": {
		"wall_colour":   Color(0.88, 0.82, 0.72),
		"wall_rough":    0.92, "wall_metal": 0.0,
		"win_width":     0.45, "win_height": 0.50,
		"door_width":    0.28,
		"roof_colour":   Color(0.58, 0.44, 0.34), "roof_rough": 0.95,
	},
	"industrial": {
		"wall_colour":   Color(0.64, 0.64, 0.62),
		"wall_rough":    0.85, "wall_metal": 0.08,
		"win_width":     0.30, "win_height": 0.38,
		"door_width":    0.32,
		"roof_colour":   Color(0.48, 0.48, 0.47), "roof_rough": 0.80,
	},
	"commercial": {
		"wall_colour":   Color(0.76, 0.79, 0.83),
		"wall_rough":    0.45, "wall_metal": 0.25,
		"win_width":     0.72, "win_height": 0.78,
		"door_width":    0.30,
		"roof_colour":   Color(0.42, 0.43, 0.46), "roof_rough": 0.65,
	},
	"civic": {
		"wall_colour":   Color(0.84, 0.79, 0.69),
		"wall_rough":    0.93, "wall_metal": 0.0,
		"win_width":     0.52, "win_height": 0.62,
		"door_width":    0.32,
		"roof_colour":   Color(0.52, 0.49, 0.41), "roof_rough": 0.95,
	},
	"garage": {
		"wall_colour":   Color(0.58, 0.58, 0.56),
		"wall_rough":    0.95, "wall_metal": 0.0,
		"win_width":     0.0,  "win_height": 0.0,   # no windows
		"door_width":    0.0,
		"roof_colour":   Color(0.38, 0.38, 0.38), "roof_rough": 0.90,
	},
	"default": {
		"wall_colour":   Color(0.72, 0.70, 0.68),
		"wall_rough":    0.88, "wall_metal": 0.0,
		"win_width":     0.40, "win_height": 0.48,
		"door_width":    0.28,
		"roof_colour":   Color(0.55, 0.45, 0.38), "roof_rough": 0.92,
	},
}

const _TYPE_TO_PROFILE: Dictionary = {
	"apartments":        "residential",
	"house":             "residential",
	"detached":          "residential",
	"residential":       "residential",
	"semidetached_house":"residential",
	"terrace":           "residential",
	"bungalow":          "residential",
	"dormitory":         "residential",

	"industrial":        "industrial",
	"warehouse":         "industrial",
	"garages":           "industrial",
	"shed":              "industrial",
	"hangar":            "industrial",
	"service":           "industrial",

	"retail":            "commercial",
	"commercial":        "commercial",
	"office":            "commercial",
	"supermarket":       "commercial",
	"shop":              "commercial",
	"kiosk":             "commercial",

	"school":            "civic",
	"university":        "civic",
	"hospital":          "civic",
	"government":        "civic",
	"civic":             "civic",
	"public":            "civic",
	"sports_hall":       "civic",
	"train_station":     "civic",
	"stadium":           "civic",
	"church":            "civic",
	"cathedral":         "civic",
	"chapel":            "civic",
	"mosque":            "civic",
	"synagogue":         "civic",

	"garage":            "garage",
	"roof":              "garage",
	"outbuilding":       "garage",
	"hut":               "garage",
	"carport":           "garage",
}

# ---------------------------------------------------------------------------
# Cache + shader
# ---------------------------------------------------------------------------

var _cache: Dictionary   = {}
var _shader: Shader      = null
var _atlas: Texture2D    = null

func _get_shader() -> Shader:
	if _shader == null:
		_shader = load(_FACADE_SHADER_PATH) as Shader
	return _shader

func _get_atlas() -> Texture2D:
	if _atlas == null:
		_atlas = load(_FACADE_ATLAS_PATH) as Texture2D
	return _atlas

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func get_wall_material(properties: Dictionary) -> Material:
	var profile  := _resolve_profile(properties)
	var mat_type := _resolve_material_type(properties)

	# Base material cached by (profile, material_type).
	var base_key := "%s_%d" % [profile, mat_type]
	if not _cache.has(base_key):
		_cache[base_key] = _facade_material(profile, mat_type)

	# building:colour → tint applied on top of the facade shader.
	var raw_colour = properties.get("wall_colour")
	if raw_colour == null or typeof(raw_colour) != TYPE_STRING or (raw_colour as String).is_empty():
		return _cache[base_key]

	var tint_key := base_key + "_" + str(raw_colour)
	if not _cache.has(tint_key):
		var base_mat: Material = _cache[base_key]
		if base_mat is ShaderMaterial:
			var tinted := (base_mat as ShaderMaterial).duplicate() as ShaderMaterial
			tinted.set_shader_parameter("colour_tint",
				_parse_osm_colour(raw_colour, Color.WHITE))
			_cache[tint_key] = tinted
		else:
			# Shader unavailable — fall back to a plain coloured material.
			_cache[tint_key] = _plain_wall_material(raw_colour)
	return _cache[tint_key]


func get_roof_material(properties: Dictionary) -> StandardMaterial3D:
	var raw_colour = properties.get("roof_colour")
	if raw_colour != null and typeof(raw_colour) == TYPE_STRING:
		return _plain_colour_material(
			_parse_osm_colour(raw_colour, _PROFILES["default"]["roof_colour"]),
			0.88, 0.0)

	var profile := _resolve_profile(properties)
	var key := profile + "_roof"
	if not _cache.has(key):
		var p: Dictionary = _PROFILES[profile]
		_cache[key] = _plain_colour_material(p["roof_colour"], p["roof_rough"], 0.0)
	return _cache[key]


func cache_size() -> int:
	return _cache.size()

# ---------------------------------------------------------------------------
# Material builders
# ---------------------------------------------------------------------------

func _facade_material(profile: String, mat_type: int = 0) -> Material:
	var shader := _get_shader()
	if shader == null:
		var p: Dictionary = _PROFILES[profile]
		return _plain_colour_material(p["wall_colour"], p["wall_rough"], p["wall_metal"])

	var p: Dictionary = _PROFILES[profile]
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var atlas := _get_atlas()
	if atlas != null:
		mat.set_shader_parameter("facade_atlas", atlas)
	mat.set_shader_parameter("wall_albedo",    p["wall_colour"])
	mat.set_shader_parameter("roughness_wall", p["wall_rough"])
	mat.set_shader_parameter("metallic_wall",  p["wall_metal"])
	mat.set_shader_parameter("window_width",   p["win_width"])
	mat.set_shader_parameter("window_height",  p["win_height"])
	mat.set_shader_parameter("door_width",     p["door_width"])
	mat.set_shader_parameter("window_albedo",  _window_colour(p["wall_colour"]))
	mat.set_shader_parameter("colour_tint",    Color.WHITE)
	mat.set_shader_parameter("material_type",  mat_type)

	var slot: int = _MATTYPE_SLOT[mat_type] if mat_type < _MATTYPE_SLOT.size() and _MATTYPE_SLOT[mat_type] >= 0 \
		else _PROFILE_SLOT.get(profile, 0)
	mat.set_shader_parameter("atlas_slot",   slot)
	mat.set_shader_parameter("tile_repeat",  _SLOT_TILE_REPEAT[slot] if slot < _SLOT_TILE_REPEAT.size() else 1.5)
	return mat


func _plain_wall_material(raw: String) -> StandardMaterial3D:
	var key := "plain_wall_" + raw
	if not _cache.has(key):
		var colour := _parse_osm_colour(raw, _PROFILES["default"]["wall_colour"])
		_cache[key] = _plain_colour_material(colour, 0.88, 0.0)
	return _cache[key]


func _plain_colour_material(colour: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness    = roughness
	mat.metallic     = metallic
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	return mat


## Derive a glass tint from the wall colour — slightly cooler and desaturated.
static func _window_colour(wall: Color) -> Color:
	var hsv := Color(wall)
	return Color.from_hsv(
		fposmod(hsv.h + 0.55, 1.0),   # shift hue toward blue
		hsv.s * 0.4,
		clampf(hsv.v * 0.6 + 0.2, 0.3, 0.7),
	)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _resolve_profile(properties: Dictionary) -> String:
	var building_type: String = str(properties.get("building", ""))
	return _TYPE_TO_PROFILE.get(building_type, "default")


## Atlas slot for each profile (when no explicit material overrides it).
const _PROFILE_SLOT: Dictionary = {
	"residential": 0,  # plaster
	"commercial":  3,  # concrete_smooth
	"industrial":  4,  # concrete_rough
	"civic":       5,  # limestone
	"garage":      4,  # concrete_rough
	"default":     0,  # plaster
}

## Atlas slot forced by building:material (overrides profile default).
## -1 means "use profile slot".
const _MATTYPE_SLOT: Array = [
	-1,  # 0 default → profile
	 1,  # 1 brick   → brick_red
	 3,  # 2 concrete → concrete_smooth
	-1,  # 3 glass   → skips atlas entirely
	 5,  # 4 stone   → limestone
	 7,  # 5 metal   → metal
]

## How many texture tiles per UV unit (= per 3 m of wall), per slot.
const _SLOT_TILE_REPEAT: Array = [
	1.5,  # 0 plaster
	3.0,  # 1 brick_red
	3.0,  # 2 brick_beige
	1.0,  # 3 concrete_smooth
	1.2,  # 4 concrete_rough
	1.5,  # 5 limestone
	2.0,  # 6 stone
	1.0,  # 7 metal
]


## Map building:material OSM tag → shader material_type int.
## 0=default  1=brick  2=concrete  3=glass  4=stone  5=metal
func _resolve_material_type(properties: Dictionary) -> int:
	var mat: String = str(properties.get("material", ""))
	match mat:
		"brick", "brick_block":
			return 1
		"concrete", "cement", "reinforced_concrete", "prefabricated_concrete":
			return 2
		"glass":
			return 3
		"stone", "limestone", "sandstone", "granite", "flint", "cobblestone":
			return 4
		"metal", "steel", "aluminium", "aluminum", "copper", "zinc":
			return 5
		_:
			return 0


static func _parse_osm_colour(raw: String, fallback: Color) -> Color:
	var s := raw.strip_edges()
	if s.is_empty():
		return fallback
	const SENTINEL := Color(9.0, 9.0, 9.0, 9.0)
	var c := Color.from_string(s, SENTINEL)
	if c != SENTINEL:
		return c
	if not s.begins_with("#"):
		c = Color.from_string("#" + s, SENTINEL)
		if c != SENTINEL:
			return c
	return fallback
