shader_type spatial;
render_mode unshaded, depth_draw_opaque;

// Procedural tower-window shader. Divides the building's side faces into
// a grid of "cells" in world-space so windows are the same size across
// every building regardless of scale. Each cell is randomly lit or dark.
// Top and bottom faces are left plain (no windows on roofs).

uniform vec3 base_color : source_color = vec3(0.06, 0.06, 0.10);
uniform vec3 window_color : source_color = vec3(1.0, 0.9, 0.6);
uniform float emission_energy : hint_range(0.0, 12.0) = 3.0;
uniform float window_density : hint_range(0.0, 1.0) = 0.55;
uniform float cell_width : hint_range(0.1, 5.0) = 0.6;
uniform float cell_height : hint_range(0.1, 5.0) = 1.2;
uniform float window_margin : hint_range(0.0, 0.5) = 0.22;
uniform float seed : hint_range(0.0, 1000.0) = 17.0;
uniform float edge_glow : hint_range(0.0, 4.0) = 0.8;

float hash21(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 34.545);
	return fract(p.x * p.y);
}

void fragment() {
	// Transform normal to world-space so we can pick the right axis pair
	// per face. Using MODEL_MATRIX means the face detection stays correct
	// even if the building is rotated.
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n = abs(wn);

	// Pick grid axes based on dominant face normal.
	// Top/bottom faces (normal mostly along Y): no windows.
	bool is_roof = n.y > n.x && n.y > n.z;
	vec2 grid_uv;
	if (n.x > n.z) {
		grid_uv = vec2(wp.z, wp.y);   // +X / -X face
	} else {
		grid_uv = vec2(wp.x, wp.y);   // +Z / -Z face
	}

	vec2 cell = floor(vec2(grid_uv.x / cell_width, grid_uv.y / cell_height));
	vec2 local = fract(vec2(grid_uv.x / cell_width, grid_uv.y / cell_height));

	// Inset "window" shape within each cell.
	float wx = step(window_margin, local.x) * step(local.x, 1.0 - window_margin);
	float wy = step(window_margin, local.y) * step(local.y, 1.0 - window_margin);
	float window_shape = wx * wy;

	// Per-cell random: is this window lit?
	float r = hash21(cell + vec2(seed, seed * 1.7));
	float lit = step(1.0 - window_density, r) * window_shape;

	// Soft edge glow: brighter near cell borders inside the window shape.
	float edge_x = min(local.x - window_margin, (1.0 - window_margin) - local.x);
	float edge_y = min(local.y - window_margin, (1.0 - window_margin) - local.y);
	float edge = 1.0 - smoothstep(0.0, 0.1, min(edge_x, edge_y));
	float rim = edge * lit * edge_glow;

	ALBEDO = base_color;
	if (is_roof) {
		EMISSION = vec3(0.0);
	} else {
		EMISSION = window_color * (lit + rim) * emission_energy;
	}
}
