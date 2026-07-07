shader_type particles;
render_mode disable_velocity, disable_force;

// Debris that collides with the destroyed world on the GPU. Each particle
// samples a per-blast occupancy snapshot: a 3D texture rasterized from the
// alive chunk grid at the moment this blast's removals were applied. Debris
// bounces off surviving blocks and flies through the hole its own blast just
// made. No physics bodies, no per-particle CPU cost, no GPU->CPU readback.
// The snapshot is frozen per emitter — debris ignores destruction that
// happens during its ~2.5 s life, which is invisible in practice.

uniform sampler3D occupancy : filter_linear, repeat_disable;
uniform vec3 grid_origin;
uniform vec3 grid_size = vec3(24.0, 22.0, 24.0);
uniform float voxel_size = 0.5;
uniform vec3 blast_pos;
uniform float blast_radius = 4.0;
uniform vec4 base_color : source_color = vec4(0.5, 0.47, 0.44, 1.0);
uniform float gravity = 21.0;
uniform float bounce = 0.34;
uniform float friction = 0.76;
uniform float speed = 11.0;
uniform float chip_size = 0.45; // longest-axis metres, before per-axis squash
uniform float scale_mult = 1.0;
uniform float kill_y = -60.0;

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

// Linear-filtered read, clamped to the snapshot region (for gradients).
float occ_at(vec3 p) {
	vec3 uvw = (p - grid_origin) / grid_size;
	return texture(occupancy, clamp(uvw, vec3(0.0), vec3(1.0))).r;
}

bool solid_at(vec3 p) {
	vec3 uvw = (p - grid_origin) / grid_size;
	if (any(lessThan(uvw, vec3(0.0))) || any(greaterThan(uvw, vec3(1.0)))) {
		return false; // outside the snapshot: free flight
	}
	return texture(occupancy, uvw).r > 0.5;
}

vec3 normal_at(vec3 p) {
	float e = voxel_size;
	vec3 g = vec3(
		occ_at(p + vec3(e, 0.0, 0.0)) - occ_at(p - vec3(e, 0.0, 0.0)),
		occ_at(p + vec3(0.0, e, 0.0)) - occ_at(p - vec3(0.0, e, 0.0)),
		occ_at(p + vec3(0.0, 0.0, e)) - occ_at(p - vec3(0.0, 0.0, e)));
	if (dot(g, g) < 0.000001) {
		return vec3(0.0, 1.0, 0.0);
	}
	return normalize(-g); // occupancy grows into the solid; normal points out
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
	// RANDOM_SEED alone is per-EMISSION: every particle would get identical
	// randoms and the whole burst flies as one overlapped clump. Mix in
	// NUMBER (per-particle counter), same as ParticleProcessMaterial does.
	uint seed = hash_u(NUMBER + uint(1) + RANDOM_SEED);
	float r1 = rand_from_seed(seed);
	float r2 = rand_from_seed(seed);
	float r3 = rand_from_seed(seed);
	float r4 = rand_from_seed(seed);
	float r5 = rand_from_seed(seed);
	float r6 = rand_from_seed(seed);
	float r7 = rand_from_seed(seed);
	float r8 = rand_from_seed(seed);
	float r9 = rand_from_seed(seed);
	float r10 = rand_from_seed(seed);
	float r11 = rand_from_seed(seed);
	vec3 dir = vec3(r1, r2, r3) * 2.0 - 1.0 + vec3(0.0, 0.45, 0.0);
	float dl = length(dir);
	dir = dl > 0.001 ? dir / dl : vec3(0.0, 1.0, 0.0);
	vec3 pos = blast_pos + dir * blast_radius * (0.2 + 0.5 * r4);
	// If we spawned inside a surviving block, pull back toward the (freshly
	// emptied) blast centre until clear.
	for (int i = 0; i < 4; i++) {
		if (!solid_at(pos)) {
			break;
		}
		pos = mix(pos, blast_pos, 0.4);
	}
	// Heavy-tailed size: mostly rubble, ~14% real boulders (the old CPU
	// debris' occasional-big-chunk tail — uniform sizes read as confetti).
	float s = chip_size * mix(0.55, 1.7, r7 * r7);
	if (r8 < 0.14) {
		s *= mix(1.6, 2.2, r9);
	}
	s *= scale_mult;
	// Heavier chunks launch slower and arc lazily; small flecks whip out fast.
	float mass_t = clamp(s / (chip_size * 2.2), 0.0, 1.0);
	VELOCITY = dir * speed * mix(0.3, 1.45, r5) * mix(1.15, 0.55, mass_t);
	VELOCITY.y += speed * mix(0.05, 0.5, r6);
	float shade = 0.72 + 0.45 * r11;
	COLOR = vec4(base_color.rgb * shade, 1.0);
	// CUSTOM: x = base scale, y = age (0..1), z = tumble speed, w = tumble angle
	CUSTOM = vec4(s, 0.0, (r10 - 0.5) * 18.0, r2 * 6.283);
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
	if (solid_at(next)) {
		vec3 n = normal_at(next);
		float vn = dot(VELOCITY, n);
		if (vn < 0.0) {
			// tangential * friction + reflected normal * bounce
			VELOCITY = (VELOCITY - n * vn) * friction - n * vn * bounce;
		}
		next = pos + VELOCITY * DELTA;
		if (solid_at(next)) {
			// Wedged in a corner: stay put and bleed energy.
			next = pos;
			VELOCITY *= 0.4;
		}
	}
	float sp = length(VELOCITY);
	// Settle: once slow and supported, stop dead instead of micro-jittering.
	if (sp < 0.5 && solid_at(next + vec3(0.0, -voxel_size * 0.7, 0.0))) {
		VELOCITY = vec3(0.0);
		sp = 0.0;
	}
	if (next.y < kill_y) {
		ACTIVE = false;
	}
	// Tumble while moving; shrink out over the last fifth of life.
	CUSTOM.w += CUSTOM.z * DELTA * clamp(sp * 0.3, 0.0, 1.0);
	float fade = clamp((1.0 - CUSTOM.y) * 5.0, 0.0, 1.0);
	float s = CUSTOM.x * fade;
	uint h = hash_u(INDEX + uint(1));
	vec3 axis = normalize(vec3(
		float(h & uint(1023)) / 511.5 - 1.0,
		float((h >> uint(10)) & uint(1023)) / 511.5 - 1.0,
		float((h >> uint(20)) & uint(1023)) / 511.5 - 1.0) + vec3(0.0001));
	mat3 b = rot_axis_angle(axis, CUSTOM.w);
	// Per-axis squash (same ranges the CPU chips used) so shards read as
	// flakes and slivers, not uniform pebbles. Derived from INDEX: stable per
	// particle, no storage needed.
	uint hp = hash_u(INDEX * uint(747796405) + uint(2891336453));
	vec3 prop = vec3(
		mix(0.5, 1.0, float(hp & uint(255)) / 255.0),
		mix(0.32, 0.92, float((hp >> uint(8)) & uint(255)) / 255.0),
		mix(0.45, 1.0, float((hp >> uint(16)) & uint(255)) / 255.0));
	TRANSFORM[0] = vec4(b[0] * (s * prop.x), 0.0);
	TRANSFORM[1] = vec4(b[1] * (s * prop.y), 0.0);
	TRANSFORM[2] = vec4(b[2] * (s * prop.z), 0.0);
	TRANSFORM[3] = vec4(next, 1.0);
}
