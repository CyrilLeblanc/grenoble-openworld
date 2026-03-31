// water.gdshader — Animated procedural water surface.
//
// No texture assets required: normals are computed from overlapping
// sine-wave functions in world space, giving consistent wave scale
// regardless of polygon size or UV layout.
//
// Designed for flat horizontal polygons (water bodies, rivers, canals).
// Works at any viewing distance — subtle at range, detailed up close.

shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// ── Colour ────────────────────────────────────────────────────────────────────
uniform vec4 shallow_color : source_color = vec4(0.18, 0.45, 0.72, 1.0);
uniform vec4 deep_color    : source_color = vec4(0.10, 0.28, 0.52, 1.0);

// ── Wave parameters ───────────────────────────────────────────────────────────
uniform float wave_speed  : hint_range(0.0, 2.0)  = 0.35;
uniform float wave_scale  : hint_range(0.001, 0.1) = 0.018;  // world-space frequency
uniform float wave_height : hint_range(0.0, 1.0)  = 0.28;    // normal perturbation strength

// ── World position from vertex shader ─────────────────────────────────────────
varying vec3 _world_pos;

void vertex() {
	_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t  = TIME * wave_speed;
	float wx = _world_pos.x * wave_scale;
	float wz = _world_pos.z * wave_scale;

	// Two overlapping wave sets for a less regular look.
	float s1 = sin(wx * 3.10 + t)        * cos(wz * 2.70 + t * 0.80);
	float s2 = sin(wx * 5.30 - t * 1.20) * cos(wz * 4.10 + t * 1.10);
	float s3 = sin(wx * 1.70 + t * 0.60) * cos(wz * 7.30 - t * 0.50);
	float wave_sum = (s1 + s2 * 0.6 + s3 * 0.4);

	// Gradient approximation for the perturbed surface normal (world-space).
	float wh = wave_height;
	float nx = -(cos(wx * 3.10 + t) * 3.10 * cos(wz * 2.70 + t * 0.80)
	            + cos(wx * 5.30 - t * 1.20) * 5.30 * cos(wz * 4.10 + t * 1.10) * 0.6
	            + cos(wx * 1.70 + t * 0.60) * 1.70 * cos(wz * 7.30 - t * 0.50) * 0.4
	            ) * wave_scale * wh;
	float nz = -(sin(wx * 3.10 + t) * (-sin(wz * 2.70 + t * 0.80)) * 2.70
	            + sin(wx * 5.30 - t * 1.20) * (-sin(wz * 4.10 + t * 1.10)) * 4.10 * 0.6
	            + sin(wx * 1.70 + t * 0.60) * (-sin(wz * 7.30 - t * 0.50)) * 7.30 * 0.4
	            ) * wave_scale * wh;

	vec3 world_normal = normalize(vec3(nx, 1.0, nz));

	// Transform to view space for NORMAL output.
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	// Color: blend shallow/deep based on wave phase.
	float depth_factor = clamp(wave_sum * 0.5 + 0.5, 0.0, 1.0);
	ALBEDO    = mix(deep_color.rgb, shallow_color.rgb, depth_factor * 0.4 + 0.3);
	ROUGHNESS = 0.04;
	METALLIC  = 0.0;
	SPECULAR  = 0.92;
}
