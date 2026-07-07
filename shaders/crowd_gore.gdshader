shader_type particles;
render_mode disable_velocity, disable_force;

// Crowd gore: meat chunks that tumble DOWN the colosseum stairs, fully on the
// GPU. Sibling of gpu_debris.gdshader, but the stands are an analytic surface
// (a radial staircase), so collision is a closed-form height function — no
// occupancy snapshot, no texture, no readback.
//
// Treads are flat, so bounces use an UP normal; surviving horizontal velocity
// carries chunks over tread edges and they skip down the steps naturally.

uniform vec3 blast_pos;
uniform float blast_radius = 3.0;
uniform vec4 base_color : source_color = vec4(0.42, 0.05, 0.04, 1.0);
uniform float gravity = 21.0;
uniform float bounce = 0.3;
uniform float friction = 0.72;
uniform float speed = 8.0;
uniform float chip_size = 0.2;
// Stadium step function parameters, all in WORLD space (the arena node can be
// offset from the world origin, so the ring centre comes in as a uniform).
uniform vec2 ring_center = vec2(0.0);
uniform float inner_r = 70.0;
uniform float base_y = 14.0;   // world y of the first row's seating surface
uniform float floor_y = 0.0;   // world y of the arena floor inside the ring
uniform float row_depth = 2.2;
uniform float row_rise = 1.4;
uniform float rows = 18.0;
uniform float kill_y = -40.0;

float rand_from_seed(inout uint seed) {
	int k;
	int s = int(seed);
	if (s == 0) {
		s = 305420679;
	}
	k = s / 127773;
	s = 16807 * (s - k * 127773) - 2836 * k;
	if (s < 0) {
		s += 2147483647;
	}
	seed = uint(s);
	return float(seed % uint(65536)) / 65535.0;
}

uint hash_u(uint x) {
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = (x >> uint(16)) ^ x;
	return x;
}

// Ground height under a point: arena floor inside the ring, stadium steps on
// the ring. (The facade front face is ignored — chunks that clear the front
// edge drop to the arena floor, which is exactly what falling gore should do.)
float ground_at(vec3 p) {
	float r = length(p.xz - ring_center);
	if (r < inner_r) {
		return floor_y;
	}
	float row = clamp(floor((r - inner_r) / row_depth), 0.0, rows - 1.0);
	return base_y + row * row_rise;
}

mat3 rot_axis_angle(vec3 a, float ang) {
	float c = cos(ang);
	float s = sin(ang);
	float t = 1.0 - c;
	return mat3(
		vec3(t * a.x * a.x + c, t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y),
		vec3(t * a.x * a.y - s * a.z, t * a.y * a.y + c, t * a.y * a.z + s * a.x),
		vec3(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c));
}

void start() {
	uint seed = hash_u(NUMBER + uint(1) + RANDOM_SEED);
	float r1 = rand_from_seed(seed);
	float r2 = rand_from_seed(seed);
	float r3 = rand_from_seed(seed);
	float r4 = rand_from_seed(seed);
	float r5 = rand_from_seed(seed);
	float r6 = rand_from_seed(seed);
	float r7 = rand_from_seed(seed);
	float r8 = rand_from_seed(seed);
	vec3 dir = vec3(r1, r2, r3) * 2.0 - 1.0 + vec3(0.0, 0.5, 0.0);
	float dl = length(dir);
	dir = dl > 0.001 ? dir / dl : vec3(0.0, 1.0, 0.0);
	vec3 pos = blast_pos + dir * blast_radius * (0.15 + 0.45 * r4);
	// Never spawn under the steps.
	pos.y = max(pos.y, ground_at(pos) + 0.15);
	VELOCITY = dir * speed * mix(0.3, 1.3, r5);
	VELOCITY.y += speed * 0.35 * r6;
	// Bias inward (toward the arena) so gore showers down the stairs.
	vec2 inward = -normalize(pos.xz);
	VELOCITY.xz += inward * speed * 0.3 * r8;
	float s = chip_size * mix(0.5, 1.5, r7 * r7);
	float shade = 0.55 + 0.6 * rand_from_seed(seed);
	COLOR = vec4(base_color.rgb * shade, 1.0);
	// CUSTOM: x = base scale, y = age (0..1), z = tumble speed, w = tumble angle
	CUSTOM = vec4(s, 0.0, (r1 - 0.5) * 20.0, r2 * 6.283);
	TRANSFORM = mat4(
		vec4(s, 0.0, 0.0, 0.0),
		vec4(0.0, s, 0.0, 0.0),
		vec4(0.0, 0.0, s, 0.0),
		vec4(pos, 1.0));
}

void process() {
	CUSTOM.y += DELTA / LIFETIME;
	VELOCITY.y -= gravity * DELTA;
	vec3 pos = TRANSFORM[3].xyz;
	vec3 next = pos + VELOCITY * DELTA;
	float g = ground_at(next);
	if (next.y <= g) {
		// Treads are flat: reflect on UP, keep sliding horizontally — chunks
		// skip over tread edges and cascade down the stairs.
		next.y = g + 0.02;
		if (VELOCITY.y < 0.0) {
			VELOCITY.y = -VELOCITY.y * bounce;
		}
		VELOCITY.xz *= friction;
	}
	float sp = length(VELOCITY);
	if (sp < 0.4 && next.y - ground_at(next) < 0.1) {
		VELOCITY = vec3(0.0);
		sp = 0.0;
	}
	if (next.y < kill_y) {
		ACTIVE = false;
	}
	CUSTOM.w += CUSTOM.z * DELTA * clamp(sp * 0.35, 0.0, 1.0);
	float fade = clamp((1.0 - CUSTOM.y) * 5.0, 0.0, 1.0);
	float s = CUSTOM.x * fade;
	uint h = hash_u(INDEX + uint(1));
	vec3 axis = normalize(vec3(
		float(h & uint(1023)) / 511.5 - 1.0,
		float((h >> uint(10)) & uint(1023)) / 511.5 - 1.0,
		float((h >> uint(20)) & uint(1023)) / 511.5 - 1.0) + vec3(0.0001));
	mat3 b = rot_axis_angle(axis, CUSTOM.w);
	uint hp = hash_u(INDEX * uint(747796405) + uint(2891336453));
	vec3 prop = vec3(
		mix(0.55, 1.0, float(hp & uint(255)) / 255.0),
		mix(0.4, 0.95, float((hp >> uint(8)) & uint(255)) / 255.0),
		mix(0.5, 1.0, float((hp >> uint(16)) & uint(255)) / 255.0));
	TRANSFORM[0] = vec4(b[0] * (s * prop.x), 0.0);
	TRANSFORM[1] = vec4(b[1] * (s * prop.y), 0.0);
	TRANSFORM[2] = vec4(b[2] * (s * prop.z), 0.0);
	TRANSFORM[3] = vec4(next, 1.0);
}
