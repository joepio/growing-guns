# Growing Guns — feature roadmap

Brainstorm picks from design session. Work **top-to-bottom, one slice at a time**.
Check boxes when shipped; add notes under each item if scope changes.

---

## Phase 1 — Cards, dice pickup, weapon names _(done)_

### Cards (permanent stackers)

- [x] **BOUNCY CASTLE** — bullets ricochet off your body (per stack)
- [x] **LAST BULLET** — final round in mag deals 5× damage (stacks multiply)
- [x] **SILENCER** — no muzzle flash / tracers / laser streak; −10% damage per stack
- [x] **DICE** (sky pickup, round-only) — one random stat ×2, another ×0.5

### Weapon name generator

- [x] `scripts/weapon_name.gd` — procedural name from card stack + standout stats
- [x] **Tab overlay** — show generated name under each player row
- [x] **Round start** — brief local banner with your loadout name (if you have cards)

---

## Phase 2 — Round / arena modifiers _(done — round modifiers; arena geometry still Phase 3)_

Server picks **one modifier per round**, announced like `LAVA LEAK` at round start.
Implement `scripts/round_modifiers.gd` registry + `Game.current_round_modifier`.

| ID               | Announce       | Effect                                                          |
| ---------------- | -------------- | --------------------------------------------------------------- |
| `low_gravity`    | LOW GRAVITY    | Higher jumps, floatier bullets (−40% gravity, −40% bullet drop) |
| `fog`            | FOG            | Short view distance (~35 m)                                     |
| `supply_storm`   | SUPPLY STORM   | Pickup spawn rate ×3                                            |
| `sudden_death`   | SUDDEN DEATH   | Lava starts immediately                                         |
| `headshots_only` | HEADSHOTS ONLY | Body damage ×0.25                                               |
| `boom_boom`      | BOOM BOOM      | Explosive rounds for everyone                                   |
| `brrrrt`         | BRRRRT         | 10x fire rate and 10x ammo for everyone                         |

- [x] Modifier registry + server pick in `_start_round_now`
- [x] Hook gravity / bullet drop / fog / etc. per modifier
- [x] All modifiers: `low_gravity`, `fog`, `supply_storm`, `sudden_death`, `headshots_only`, `boom_boom`, `brrrrt`

---

## Phase 3 — Arena geometry

### Moving platforms

- [ ] Shuttle nodes in `arena_generator.gd` — slow back-and-forth between two points
- [ ] Spawnpoints on platforms (optional)
- [ ] Sync transform on all peers (server-driven `AnimatableBody3D` or tween)

### Cracking floor

- [ ] Tile health per floor segment (N bullet hits → temporary hole)
- [ ] Visual crack overlay + collision disable for ~8 s, then repair
- [ ] Skip lava tiles / spawn safe zones

---

## Phase 4 — More pickups & juice (backlog)

- [ ] Magnet, shield bubble, shrink ray, hot potato, etc.
- [ ] Overheal HP gold color in HUD
- [ ] Pickup compass ping toward nearest drop
- [ ] Card synergy hint on pick UI

---

## Implementation notes

- **Cards** mutate `Weapon` only; gameplay reads getters / derived fields.
- **Round-only pickup buffs** cleared via `rebuild_weapon_from_cards()` at round start; dice rolls are lost.
- **Round modifiers** should be server-authoritative static flags on `Game`, not per-weapon state.
- **Weapon names** are cosmetic — derived from `applied_cards` order + key stats; must be deterministic across peers.
