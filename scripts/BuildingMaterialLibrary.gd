## BuildingMaterialLibrary — maps OSM building tags to StandardMaterial3D instances.
##
## Priority:
##   1. Explicit OSM colour tag (wall_colour / roof_colour) — used as-is
##   2. building= type → visual profile (colour + roughness + metallic)
##   3. Default profile for unrecognised types
##
## Materials are cached to avoid duplicates across thousands of buildings.
class_name BuildingMaterialLibrary

# ---------------------------------------------------------------------------
# Visual profiles per semantic building category
# ---------------------------------------------------------------------------

## Each profile defines wall and roof appearance.
const _PROFILES: Dictionary = {
	"residential": {
		"wall_colour": Color(0.88, 0.82, 0.72), "wall_rough": 0.92, "wall_metal": 0.0,
		"roof_colour": Color(0.58, 0.44, 0.34), "roof_rough": 0.95,
	},
	"industrial": {
		"wall_colour": Color(0.64, 0.64, 0.62), "wall_rough": 0.85, "wall_metal": 0.08,
		"roof_colour": Color(0.48, 0.48, 0.47), "roof_rough": 0.80,
	},
	"commercial": {
		"wall_colour": Color(0.76, 0.79, 0.83), "wall_rough": 0.45, "wall_metal": 0.25,
		"roof_colour": Color(0.42, 0.43, 0.46), "roof_rough": 0.65,
	},
	"civic": {
		"wall_colour": Color(0.84, 0.79, 0.69), "wall_rough": 0.93, "wall_metal": 0.0,
		"roof_colour": Color(0.52, 0.49, 0.41), "roof_rough": 0.95,
	},
	"garage": {
		"wall_colour": Color(0.58, 0.58, 0.56), "wall_rough": 0.95, "wall_metal": 0.0,
		"roof_colour": Color(0.38, 0.38, 0.38), "roof_rough": 0.90,
	},
	"default": {
		"wall_colour": Color(0.72, 0.70, 0.68), "wall_rough": 0.88, "wall_metal": 0.0,
		"roof_colour": Color(0.55, 0.45, 0.38), "roof_rough": 0.92,
	},
}

## Maps building= tag values to a profile name.
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
# Cache
# ---------------------------------------------------------------------------

var _cache: Dictionary = {}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func get_wall_material(properties: Dictionary) -> StandardMaterial3D:
	var raw_colour = properties.get("wall_colour")
	if raw_colour != null and typeof(raw_colour) == TYPE_STRING:
		return _colour_material(raw_colour, _PROFILES["default"]["wall_colour"])

	var profile := _resolve_profile(properties)
	var key := profile + "_wall"
	if not _cache.has(key):
		var p: Dictionary = _PROFILES[profile]
		_cache[key] = _make_material(p["wall_colour"], p["wall_rough"], p["wall_metal"])
	return _cache[key]


func get_roof_material(properties: Dictionary) -> StandardMaterial3D:
	var raw_colour = properties.get("roof_colour")
	if raw_colour != null and typeof(raw_colour) == TYPE_STRING:
		return _colour_material(raw_colour, _PROFILES["default"]["roof_colour"])

	var profile := _resolve_profile(properties)
	var key := profile + "_roof"
	if not _cache.has(key):
		var p: Dictionary = _PROFILES[profile]
		_cache[key] = _make_material(p["roof_colour"], p["roof_rough"], 0.0)
	return _cache[key]


func cache_size() -> int:
	return _cache.size()

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _resolve_profile(properties: Dictionary) -> String:
	var building_type: String = str(properties.get("building", ""))
	return _TYPE_TO_PROFILE.get(building_type, "default")


func _colour_material(raw: String, fallback: Color) -> StandardMaterial3D:
	var colour := _parse_osm_colour(raw, fallback)
	var key: String = "colour_" + raw
	if not _cache.has(key):
		_cache[key] = _make_material(colour, 0.88, 0.0)
	return _cache[key]


func _make_material(colour: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness    = roughness
	mat.metallic     = metallic
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	return mat


## Parse an OSM colour string into a Godot Color.
## Handles: named colours ("white", "grey"), #rrggbb, bare rrggbb hex.
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
