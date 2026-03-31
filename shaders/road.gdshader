// road.gdshader — PBR asphalt with French IISR road markings.
//
// UV convention (set by RoadMeshSpawner):
//   UV.x  0.0 → 1.0  across road width, left→right
//         < 0 or > 1  curb face (rendered as stone)
//   UV.y  metres along the road centreline
//
// Uniforms are set per road category via ShaderMaterial on each MeshInstance3D.

shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// Road geometry
uniform float road_width : hint_range(2.0, 20.0) = 4.0;

// Marking control
uniform bool show_center_dash = true;   // dashed centre line (bidirectional roads)
uniform bool show_edge_lines  = true;   // continuous edge lines (ligne de rive)

// ── Colors ──────────────────────────────────────────────────────────────────
const vec3 ASPHALT    = vec3(0.20, 0.20, 0.20);
const vec3 WHITE      = vec3(0.95, 0.95, 0.92);
const vec3 CURB_STONE = vec3(0.52, 0.51, 0.49);  // limestone kerb

// ── French IISR T1 marking dimensions (metres) ──────────────────────────────
const float EDGE_W       = 0.15;   // ligne de rive (edge line) width
const float CENTER_W     = 0.22;   // ligne axiale (centre line) width
const float DASH_ON      = 3.0;    // trait length
const float DASH_PERIOD  = 13.0;   // module: 3 m trait + 10 m intervalle

void fragment() {
	float u = UV.x;   // 0 = left road edge, 1 = right road edge
	float v = UV.y;   // metres along road

	// ── Curb face ────────────────────────────────────────────────────────────
	if (u < 0.0 || u > 1.0) {
		ALBEDO    = CURB_STONE;
		ROUGHNESS = 0.90;
		METALLIC  = 0.0;
		SPECULAR  = 0.05;
	} else {
		// ── Road surface ──────────────────────────────────────────────────────
		float u_m = u * road_width;     // physical distance from left edge (metres)
		vec3  col = ASPHALT;

		// Edge lines — continuous white stripes (ligne de rive)
		if (show_edge_lines && (u_m < EDGE_W || u_m > road_width - EDGE_W)) {
			col = WHITE;
		}
		// Centre line — T1 dashes (only on bidirectional roads)
		else if (show_center_dash) {
			float dist_c = abs(u_m - road_width * 0.5);
			if (dist_c < CENTER_W * 0.5) {
				float phase = mod(v, DASH_PERIOD);
				if (phase < DASH_ON) {
					col = WHITE;
				}
			}
		}

		ALBEDO    = col;
		ROUGHNESS = 0.88;
		METALLIC  = 0.0;
		SPECULAR  = 0.12;
	}
}
