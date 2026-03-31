shader_type spatial;
render_mode cull_disabled;

// ---------------------------------------------------------------------------
// Facade atlas
// ---------------------------------------------------------------------------
// A 4096×512 PNG with 8 material slots of 512×512 px each (left to right):
//   0 plaster   1 brick_red   2 brick_beige   3 concrete_smooth
//   4 concrete_rough   5 limestone   6 stone   7 metal
//
// UV mapping (from BuildingMeshFactory, UV_SCALE = 3 m):
//   U = horizontal distance along perimeter / 3  →  tiles every 3 m
//   V = height from base / 3                     →  tiles every 3 m floor

uniform sampler2D facade_atlas : hint_default_white, filter_linear_mipmap, repeat_enable;

/// Which column in the atlas to use (0–7).  Set by BuildingMaterialLibrary.
uniform int atlas_slot = 0;

/// How many times the texture tiles per UV unit (= per 3 m of wall).
/// Brick ~3.0 (1 repeat per metre), plaster ~1.5, concrete ~1.0.
uniform float tile_repeat : hint_range(0.5, 6.0) = 1.5;

// ---------------------------------------------------------------------------
// Per-profile colours (still used for windows, doors, frames, and glass walls)
// ---------------------------------------------------------------------------

uniform vec4 wall_albedo   : source_color = vec4(0.72, 0.70, 0.68, 1.0);
uniform vec4 window_albedo : source_color = vec4(0.42, 0.52, 0.68, 1.0);
uniform vec4 frame_albedo  : source_color = vec4(0.88, 0.87, 0.84, 1.0);
uniform vec4 door_albedo   : source_color = vec4(0.38, 0.24, 0.12, 1.0);

/// Tint multiplied on top of the atlas sample (from building:colour OSM tag).
uniform vec4 colour_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float window_width  : hint_range(0.0, 1.0) = 0.45;
uniform float window_height : hint_range(0.0, 1.0) = 0.50;
uniform float door_width    : hint_range(0.0, 1.0) = 0.28;

uniform float roughness_wall  : hint_range(0.0, 1.0) = 0.88;
uniform float roughness_glass : hint_range(0.0, 1.0) = 0.05;
uniform float metallic_wall   : hint_range(0.0, 1.0) = 0.0;

/// 0=normal  3=glass curtain wall (overrides window proportions, skips atlas).
uniform int material_type = 0;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

float hash(float n) {
	return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

// ---------------------------------------------------------------------------
// Fragment
// ---------------------------------------------------------------------------

void fragment() {
	vec2  cell      = fract(UV);
	float col       = floor(UV.x);
	float floor_idx = floor(UV.y);

	bool is_ground    = floor_idx < 0.5;
	bool is_door_cell = is_ground && (hash(col) < 0.18);

	float frame_w = 0.06;

	// ---- Base wall: sample atlas or use solid colour for glass walls ----
	vec3  base_wall;
	float base_rough = roughness_wall;
	float base_metal = metallic_wall;

	if (material_type == 3) {
		// Glass curtain wall: spandrel panels use wall_albedo directly.
		base_wall     = wall_albedo.rgb * colour_tint.rgb;
		base_rough    = mix(roughness_wall, 0.30, 0.7);
		base_metal    = mix(metallic_wall,  0.40, 0.7);
		is_door_cell  = false;
	} else {
		// All other materials: sample the atlas at the correct slot.
		float slot_u  = (fract(UV.x * tile_repeat) + float(atlas_slot)) / 8.0;
		float slot_v  = fract(UV.y * tile_repeat);
		vec4  sample  = texture(facade_atlas, vec2(slot_u, slot_v));
		base_wall     = sample.rgb * colour_tint.rgb;
	}

	vec3  out_albedo   = base_wall;
	float out_rough    = base_rough;
	float out_metal    = base_metal;
	float out_specular = 0.5;

	// ---- Glass curtain wall: large windows, thin mullions ----
	float eff_win_w = window_width;
	float eff_win_h = window_height;
	if (material_type == 3) {
		eff_win_w = 0.88;
		eff_win_h = 0.92;
	}

	// ---- Door or window ----
	if (is_door_cell) {
		float dmx      = (1.0 - door_width) * 0.5;
		float door_top = 0.88;
		bool in_door   = cell.x > dmx && cell.x < (1.0 - dmx) && cell.y < door_top;
		bool in_frame  = (
			cell.x > (dmx - frame_w) && cell.x < (1.0 - dmx + frame_w) &&
			cell.y < (door_top + frame_w)
		) && !in_door;

		if (in_door) {
			out_albedo  = door_albedo.rgb;
			out_rough   = 0.75;
			out_metal   = 0.0;
		} else if (in_frame) {
			out_albedo  = frame_albedo.rgb;
			out_rough   = 0.65;
		}
	} else {
		float mx = (1.0 - eff_win_w) * 0.5;
		float my = (1.0 - eff_win_h) * 0.5;

		bool in_win = cell.x > mx && cell.x < (1.0 - mx) &&
		              cell.y > my && cell.y < (1.0 - my);

		bool in_frame = (
			cell.x > (mx - frame_w) && cell.x < (1.0 - mx + frame_w) &&
			cell.y > (my - frame_w) && cell.y < (1.0 - my + frame_w)
		) && !in_win;

		if (in_win) {
			out_albedo   = window_albedo.rgb;
			out_rough    = roughness_glass;
			out_metal    = 0.0;
			out_specular = 0.9;
		} else if (in_frame) {
			out_albedo = frame_albedo.rgb;
			out_rough  = 0.65;
			out_metal  = base_metal;
		}
	}

	ALBEDO    = out_albedo;
	ROUGHNESS = out_rough;
	METALLIC  = out_metal;
	SPECULAR  = out_specular;
}
