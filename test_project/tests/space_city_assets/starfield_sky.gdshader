shader_type sky;

// Procedural starfield sky. Hashes the view direction into cells and
// lights a pinprick in each cell with a random brightness.

uniform vec3 sky_top : source_color = vec3(0.008, 0.008, 0.028);
uniform vec3 sky_horizon : source_color = vec3(0.025, 0.012, 0.065);
uniform float gradient_curve : hint_range(0.05, 2.0) = 0.35;
uniform float star_density : hint_range(0.92, 0.999) = 0.988;
uniform float star_brightness : hint_range(0.2, 6.0) = 2.5;
uniform float star_twinkle : hint_range(0.0, 1.5) = 0.35;
uniform float cell_scale : hint_range(20.0, 400.0) = 180.0;
uniform vec3 star_tint_a : source_color = vec3(1.0, 0.95, 0.85);
uniform vec3 star_tint_b : source_color = vec3(0.7, 0.85, 1.0);

float hash21(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 34.545);
	return fract(p.x * p.y);
}

vec2 dir_to_uv(vec3 d) {
	float u = atan(d.z, d.x) / (2.0 * 3.14159265) + 0.5;
	float v = asin(clamp(d.y, -1.0, 1.0)) / 3.14159265 + 0.5;
	return vec2(u, v);
}

void sky() {
	float vf = clamp(pow(max(EYEDIR.y, 0.0), gradient_curve), 0.0, 1.0);
	vec3 base = mix(sky_horizon, sky_top, vf);

	vec3 star = vec3(0.0);
	if (EYEDIR.y > -0.05) {
		vec2 sky_uv = dir_to_uv(normalize(EYEDIR));
		vec2 grid = sky_uv * cell_scale;
		vec2 cell = floor(grid);
		vec2 local = fract(grid) - 0.5;

		float r = hash21(cell);
		float lit = step(star_density, r);
		float dist = length(local);
		float disc = smoothstep(0.12, 0.0, dist);
		float halo = smoothstep(0.28, 0.05, dist) * 0.25;

		float t = hash21(cell + 7.3);
		float tw = 1.0 - star_twinkle * 0.5 * (1.0 + sin(TIME * (1.5 + t * 2.0) + t * 6.28));

		vec3 tint = mix(star_tint_a, star_tint_b, hash21(cell + 3.1));

		star = tint * (disc + halo) * lit * star_brightness * tw;
		star *= smoothstep(-0.05, 0.1, EYEDIR.y);
	}

	COLOR = base + star;
}
