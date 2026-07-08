shader_type spatial;
// fog_disabled: the arena's distance haze was washing the screens to
// parchment at bowl distances — real jumbotrons punch through.
render_mode unshaded, cull_back, fog_disabled;

// Stadium jumbotron screen (see stadium_tv.gd). The "broadcast" is the
// viewer's own previous frame: hint_screen_texture reuses the main
// viewport's shared per-frame screen copy, so there is NO second scene
// render — each player sees their own POV on the stadium screens, dressed
// with scanlines, a rolling flicker band, a blinking LIVE bug and a color
// ticker bar. (Reading the screen moves this material to the transparent
// pass, so the TV's own rectangle isn't in the copy — a TV seen on a TV
// shows the wall behind it, not infinite recursion.)
//
// Unshaded on purpose: TVs stay lit during the blackout modifier, exactly
// like real stadium screens (and per docs/lore.md, they're the venue's own
// hardware). Palette rule: no red — teal/magenta/gold/lime.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float feed_on : hint_range(0.0, 1.0) = 1.0;
uniform float brightness = 1.4;
// Manual partial atmosphere: fog_disabled kills the engine fog entirely,
// which made the screens look pasted onto the scene. Blend a *fraction* of
// a matched haze back in by view distance — bright like a real jumbotron,
// but still sitting in the arena's air.
uniform vec3 haze_color : source_color = vec3(0.80, 0.74, 0.63);
uniform float haze_density = 0.008;
uniform float haze_strength : hint_range(0.0, 1.0) = 0.5;

const vec3 TEAL = vec3(0.05, 0.75, 0.72);
const vec3 MAGENTA = vec3(0.90, 0.15, 0.75);
const vec3 GOLD = vec3(0.95, 0.72, 0.10);
const vec3 LIME = vec3(0.55, 0.90, 0.12);
const vec3 CYAN = vec3(0.15, 0.65, 0.95);
const vec3 VIOLET = vec3(0.55, 0.25, 0.95);

float box(vec2 p, vec2 h) {
	vec2 d = abs(p) - h;
	return step(max(d.x, d.y), 0.0);
}

mat2 rot(float a) { return mat2(vec2(cos(a), -sin(a)), vec2(sin(a), cos(a))); }

// Blocky "LIVE" glyphs in a local space where each letter fits ~[0,1]^2.
float live_text(vec2 p) {
	float m = 0.0;
	// L
	m += box(p - vec2(0.08, 0.5), vec2(0.07, 0.5));
	m += box(p - vec2(0.28, 0.08), vec2(0.22, 0.08));
	// I
	m += box(p - vec2(0.75, 0.5), vec2(0.07, 0.5));
	// V — two slanted bars meeting at the bottom.
	vec2 vp = p - vec2(1.25, 0.5);
	m += box(rot(0.32) * (vp - vec2(-0.14, 0.05)), vec2(0.065, 0.52));
	m += box(rot(-0.32) * (vp - vec2(0.14, 0.05)), vec2(0.065, 0.52));
	// E
	m += box(p - vec2(1.78, 0.5), vec2(0.07, 0.5));
	m += box(p - vec2(1.95, 0.92), vec2(0.20, 0.08));
	m += box(p - vec2(1.92, 0.50), vec2(0.17, 0.075));
	m += box(p - vec2(1.95, 0.08), vec2(0.20, 0.08));
	return clamp(m, 0.0, 1.0);
}

// Fallback content: lore-palette color bars with a drifting bright sweep.
vec3 color_bars(vec2 uv, float t) {
	vec3 cols[7] = {TEAL, MAGENTA, GOLD, LIME, CYAN, VIOLET, vec3(0.92)};
	int k = int(clamp(floor(uv.x * 7.0), 0.0, 6.0));
	vec3 c = cols[k];
	// Bright diagonal sweep so the bars read animated, not frozen.
	float sweep = pow(0.5 + 0.5 * sin((uv.x + uv.y) * 3.0 - t * 1.2), 8.0);
	return c * (0.75 + 0.45 * sweep);
}

void fragment() {
	vec2 uv = UV;
	// Bezel: rounded-rect screen inset in a dark frame.
	vec2 q = abs(uv - 0.5) - vec2(0.475, 0.46);
	float bezel = step(max(q.x, q.y), 0.0);

	vec3 content;
	if (feed_on > 0.5) {
		vec3 f = texture(screen_tex, uv).rgb;
		// Broadcast grade: contrast pivot above mid to cut the arena's
		// atmospheric haze, plus a saturation push so the feed reads punchy
		// at bowl distances.
		f = clamp((f - 0.5) * 1.35 + 0.45, 0.0, 1.4);
		float luma = dot(f, vec3(0.299, 0.587, 0.114));
		content = mix(vec3(luma), f, 1.15);
	} else {
		content = color_bars(uv, TIME);
	}

	// Ticker bar along the bottom: animated teal->magenta gradient with a
	// bright chevron sweep. (Text comes later; the motion sells "broadcast".)
	if (uv.y > 0.88) {
		float g = fract(uv.x * 1.5 - TIME * 0.07);
		vec3 bar = mix(TEAL, MAGENTA, g);
		float chevron = pow(0.5 + 0.5 * sin(uv.x * 40.0 - TIME * 6.0), 10.0);
		content = bar * 0.85 + GOLD * chevron * 0.5;
	}

	// LIVE bug, top-left, with a blinking dot. Dot is magenta — the one red
	// rule: red belongs to blood and gun-flesh only.
	// Letter glyphs are authored y-up; quad UV v runs downward — flip.
	vec2 lp = (uv - vec2(0.045, 0.045)) / vec2(0.055, 0.078);
	lp.y = 1.0 - lp.y;
	float dot = step(length(lp - vec2(-0.85, 0.5)), 0.32) * step(0.5, fract(TIME * 0.8));
	float letters = live_text(lp);
	content = mix(content, vec3(0.95), letters);
	content = mix(content, MAGENTA * 1.4, dot);

	// Broadcast dressing: scanlines + a slow rolling flicker band + vignette.
	float scan = 0.88 + 0.12 * sin(uv.y * 320.0);
	float roll = 1.0 - 0.12 * pow(0.5 + 0.5 * sin(uv.y * 6.28 + TIME * 1.7), 6.0);
	float vig = 1.0 - 0.35 * pow(length(uv - 0.5) * 1.35, 2.5);

	vec3 screen_col = content * scan * roll * vig * brightness;
	vec3 frame_col = vec3(0.05, 0.05, 0.06);
	vec3 col = mix(frame_col, screen_col, bezel);
	float dist = length(VERTEX);
	float haze = (1.0 - exp(-dist * haze_density)) * haze_strength;
	ALBEDO = mix(col, haze_color, haze);
}
