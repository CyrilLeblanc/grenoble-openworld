// sidewalk.gdshader — Procedural concrete paving-slab surface for sidewalks.
//
// UV convention (set by SidewalkSpawner):
//   UV.x  0.0 → 1.0  across sidewalk width
//   UV.y  metres along the road centreline

shader_type spatial;
render_mode cull_disabled;

// Physical width of the sidewalk strip (metres), used to convert U to metres.
uniform float sidewalk_width : hint_range(0.5, 5.0) = 2.0;

// ── Colors ───────────────────────────────────────────────────────────────────
const vec3 CONCRETE = vec3(0.72, 0.70, 0.68);
const vec3 GROUT    = vec3(0.48, 0.47, 0.45);

// ── Slab geometry (metres) ───────────────────────────────────────────────────
const float SLAB_ACROSS = 0.40;   // slab width, perpendicular to road
const float SLAB_ALONG  = 0.60;   // slab length, along road
const float GROUT_W     = 0.015;  // grout-line half-width

void fragment() {
	float u_m = UV.x * sidewalk_width;   // metres across sidewalk
	float v_m = UV.y;                     // metres along road

	// Fractional position within each slab cell
	float cx = fract(u_m / SLAB_ACROSS);
	float cy = fract(v_m / SLAB_ALONG);

	// Distance to nearest grout line in each axis (metres)
	float dx = min(cx, 1.0 - cx) * SLAB_ACROSS;
	float dy = min(cy, 1.0 - cy) * SLAB_ALONG;

	// Inside grout if either axis is within GROUT_W
	float grout = step(GROUT_W, min(dx, dy));   // 1 = slab, 0 = grout

	ALBEDO    = mix(GROUT, CONCRETE, grout);
	ROUGHNESS = 0.92;
	METALLIC  = 0.0;
	SPECULAR  = 0.05;
}
