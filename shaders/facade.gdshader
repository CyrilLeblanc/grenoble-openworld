shader_type spatial;
render_mode cull_disabled;

// ---------------------------------------------------------------------------
// Uniforms — set per building profile by BuildingMaterialLibrary
// ---------------------------------------------------------------------------

uniform vec4  wall_albedo    : source_color = vec4(0.72, 0.70, 0.68, 1.0);
uniform vec4  window_albedo  : source_color = vec4(0.42, 0.52, 0.68, 1.0);
uniform vec4  frame_albedo   : source_color = vec4(0.88, 0.87, 0.84, 1.0);
uniform vec4  door_albedo    : source_color = vec4(0.38, 0.24, 0.12, 1.0);

uniform float window_width   : hint_range(0.0, 1.0) = 0.45;
uniform float window_height  : hint_range(0.0, 1.0) = 0.50;
uniform float door_width     : hint_range(0.0, 1.0) = 0.28;

uniform float roughness_wall : hint_range(0.0, 1.0) = 0.88;
uniform float roughness_glass: hint_range(0.0, 1.0) = 0.05;
uniform float metallic_wall  : hint_range(0.0, 1.0) = 0.0;

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
	vec2  cell  = fract(UV);              // position within the current 3m tile
	float col   = floor(UV.x);           // which horizontal cell (0, 1, 2 …)
	float floor_idx = floor(UV.y);        // which floor (0 = ground)

	// --- Door: ground floor only, on cells where hash < door_probability ---
	bool is_ground  = floor_idx < 0.5;
	bool is_door_cell = is_ground && (hash(col) < 0.18);

	float frame_w = 0.06;  // frame thickness as fraction of cell

	vec3  out_albedo  = wall_albedo.rgb;
	float out_rough   = roughness_wall;
	float out_metal   = metallic_wall;
	float out_specular = 0.5;

	if (is_door_cell) {
		// Door: taller than window, anchored to floor, centered in cell.
		float dmx = (1.0 - door_width) * 0.5;
		float door_top = 0.88;  // door occupies 88% of cell height from bottom
		bool in_door = cell.x > dmx && cell.x < (1.0 - dmx) && cell.y < door_top;
		bool in_door_frame = (cell.x > (dmx - frame_w) && cell.x < (1.0 - dmx + frame_w) && cell.y < (door_top + frame_w)) && !in_door;

		if (in_door) {
			out_albedo  = door_albedo.rgb;
			out_rough   = 0.75;
			out_metal   = 0.0;
		} else if (in_door_frame) {
			out_albedo  = frame_albedo.rgb;
			out_rough   = 0.65;
		}
	} else {
		// Window: centered in cell, top half anchored.
		float mx     = (1.0 - window_width)  * 0.5;
		float my_bot = (1.0 - window_height) * 0.5;
		float my_top = my_bot;

		bool in_win = cell.x > mx && cell.x < (1.0 - mx) &&
		              cell.y > my_bot && cell.y < (1.0 - my_top);

		bool in_frame = (cell.x > (mx - frame_w) && cell.x < (1.0 - mx + frame_w) &&
		                 cell.y > (my_bot - frame_w) && cell.y < (1.0 - my_top + frame_w)) && !in_win;

		if (in_win) {
			out_albedo   = window_albedo.rgb;
			out_rough    = roughness_glass;
			out_metal    = 0.0;
			out_specular = 0.9;
		} else if (in_frame) {
			out_albedo = frame_albedo.rgb;
			out_rough  = 0.65;
			out_metal  = metallic_wall;
		}
	}

	ALBEDO    = out_albedo;
	ROUGHNESS = out_rough;
	METALLIC  = out_metal;
	SPECULAR  = out_specular;
}
