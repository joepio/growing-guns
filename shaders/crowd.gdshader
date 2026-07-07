shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_back;

// Colosseum crowd: tiny 3D box-figures (torso/head/arms, ~48 tris) in ONE
// MultiMesh. LIT (not unshaded) so the crowd shades with the sun like the
// stands do — and blackout rounds darken it for free via the global light
// crush, no world_light_dim needed here.
//
// Cheer is pure vertex work: UV2.x tags ARM vertices (they raise and spread
// while the wave is up), UV2.y tags HEAD vertices (skin tint over the tunic
// color). INSTANCE_CUSTOM: x = phase, y = tempo, z = hop amp, w = shade.

// Mood, driven per-frame by CrowdAudio (the same values that mix the crowd
// sound loops): excitement = enthusiasm, panic = fear. Defaults reproduce the
// idle crowd exactly when nothing sets them (labs, editor preview).
uniform float excitement : hint_range(0.0, 1.0) = 0.0;
uniform float panic : hint_range(0.0, 1.0) = 0.0;

// Flee-from-blast, fully on the GPU: ColosseumCrowd drops recent blasts into
// this 4-slot ring (xyz = world pos, w = radius) and updates flee_age (seconds
// since each) once per frame while any is active. Displacement is a pure
// function of seat/blast/age, so no per-instance state: spectators sprint
// tangentially along their row away from the blast, hold, then drift back —
// and land exactly back on their own seat by construction.
uniform vec4 flee_blast[4];
uniform vec4 flee_age = vec4(1000.0);
// Per-slot: age at which the walk-back starts. Sustained fire on a section
// extends its slot's hold instead of re-recording — the displacement profile
// never dips, so no one snaps home mid-barrage.
uniform vec4 flee_hold = vec4(6.0);
uniform vec2 ring_center = vec2(0.0);

const float FLEE_OUT_END = 1.2;     // sprint-away duration
const float FLEE_RETURN_DUR = 4.5;  // walk-back duration after the hold

varying float v_shade;
varying float v_skin;

void vertex() {
	// Cower: the whole figure crouches as panic rises.
	VERTEX.y *= 1.0 - panic * 0.22;
	float t = TIME * (1.4 + INSTANCE_CUSTOM.y * 2.2) + INSTANCE_CUSTOM.x * 6.2832;
	float up = max(sin(t), 0.0);
	// A second, faster wave fades in with excitement — the crowd double-times
	// without rescaling TIME (a changing time multiplier would make the whole
	// animation scrub whenever the mood moves).
	up = max(up, max(sin(t * 1.93 + 1.7), 0.0) * excitement);
	// Hop off the step while cheering; calm spectators have hop amp 0, but
	// excitement pulls even the sitters up. Panic kills the hop...
	float hop = (INSTANCE_CUSTOM.z + excitement * 0.22) * (1.0 + excitement * 0.8) * (1.0 - panic);
	VERTEX.y += up * hop * 0.4;
	// ...and replaces it with a fast per-instance tremble.
	VERTEX.x += panic * sin(TIME * 21.0 + INSTANCE_CUSTOM.x * 47.0) * 0.045 * VERTEX.y;
	// Raise + spread the arms; cowering pulls them back down.
	float arm = UV2.x * (1.0 - panic);
	VERTEX.y += arm * up * 0.34;
	VERTEX.x += sign(VERTEX.x) * arm * up * 0.12;
	// Gentle idle sway so even sitters aren't statues.
	VERTEX.x += sin(t * 0.6) * 0.035 * VERTEX.y;
	// ---- flee from nearby blasts (coherent branch: free when idle) ----
	if (any(lessThan(flee_age, flee_hold + vec4(FLEE_RETURN_DUR)))) {
		vec3 seat = MODEL_MATRIX[3].xyz;
		vec2 disp = vec2(0.0);
		float run = 0.0;  // run-cycle intensity (only while actually moving)
		for (int i = 0; i < 4; i++) {
			float age = flee_age[i];
			float hold = flee_hold[i];
			if (age >= hold + FLEE_RETURN_DUR) {
				continue;
			}
			vec2 to_seat = seat.xz - flee_blast[i].xyz.xz;
			float reach = flee_blast[i].w * 2.6 + 2.0;
			float d = length(to_seat);
			if (d >= reach) {
				continue;
			}
			float prox = 1.0 - d / reach;
			// Rows run along the ring: flee tangentially, away from the blast.
			vec2 radial = normalize(seat.xz - ring_center);
			vec2 tang = vec2(-radial.y, radial.x);
			float side = dot(tang, to_seat) >= 0.0 ? 1.0 : -1.0;
			float outp = smoothstep(0.0, FLEE_OUT_END, age);
			float retp = smoothstep(hold, hold + FLEE_RETURN_DUR, age);
			float prof = outp * (1.0 - retp);
			float dist = prox * (3.0 + 5.0 * INSTANCE_CUSTOM.x) * prof;
			disp += tang * side * dist;
			// Moving during the sprint-out and the walk-back, still in between.
			run = max(run, prox * clamp(outp * (1.0 - outp) * 4.0 + retp * (1.0 - retp) * 4.0, 0.0, 1.0));
		}
		if (run > 0.001 || disp != vec2(0.0)) {
			// Sprint bob while in motion.
			VERTEX.y += abs(sin(TIME * 10.5 + INSTANCE_CUSTOM.x * 41.0)) * 0.17 * run;
			// World-space offset -> this instance's model space (yaw + uniform
			// scale basis: inverse = transpose / scale^2).
			vec3 world_off = vec3(disp.x, 0.0, disp.y);
			float s2 = dot(MODEL_MATRIX[0].xyz, MODEL_MATRIX[0].xyz);
			VERTEX += (world_off * mat3(MODEL_MATRIX)) / s2;
		}
	}
	v_shade = 0.6 + 0.4 * INSTANCE_CUSTOM.w;
	v_skin = UV2.y;
}

void fragment() {
	vec3 tunic = COLOR.rgb * v_shade;
	vec3 skin = vec3(0.68, 0.52, 0.40) * v_shade;
	ALBEDO = mix(tunic, skin, v_skin);
	ROUGHNESS = 1.0;
}
