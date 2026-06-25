# Coop Wave Mode Improvements

Living checklist for coop wave features and related fixes.

## Status

| Item | Status |
|------|--------|
| Lifesteal on all damage (incl. explosions) | Done |
| Player join/leave/death announcements | Done |
| Pickup despawn sync across peers | Done |
| Coop enemy archetypes (grenadier, fragger, slenderman sniper) | Done |
| Bot jump frequency reduced | Done |
| Coop downed state (no instant match loss) | Done |
| Teammate revive (3s on body) | Done |
| Coop downed spectator (invisible + revive cross) | Done |
| Revive sky drop above corpse | Done |
| Gun visible after revive | Done |
| Team blue / enemy per-archetype colors | Done |
| Floor 3 blocks thick | Done |
| Revive progress UI for reviver (optional) | Skipped |

---

## Coop downed + revive (done)

- Human dies in coop without Phoenix charge → **downed**, not eliminated (if an ally is still standing).
- Match fails only when **no standing humans** remain.
- Downed player: invisible body, free-look spectator cam, subtle white fade.
- Allies see a **bouncing glowing cross + light** at the corpse.
- Ally within 1.4m for 3s → Phoenix ascension → sky drop above corpse (+60m Y).
- Phoenix card still auto-revives on death when charged.

---

## Floor 3 blocks thick (done)

In `arena_generator.gd` `_build_floor`: three separate 1m destructible layers (y=0..-3). Lava pool moved to y=-3.

---

## Test plan

1. Lifesteal + explosive rounds: shooting floor/wall near enemies heals per splash victim.
2. Lifesteal + grenade: throwing grenade into pack heals thrower.
3. Announcements: join/leave/death show on round banner for humans.
4. Pickups: one player collects → gone for everyone.
5. Coop duo: A dies, B alive → A spectates; cross visible to B; B revives → A drops from sky above corpse.
6. All down: both dead → wave failed.
7. Gun visible immediately after landing from revive.
8. Humans blue, enemies colored per archetype.
9. Floor survives more explosions before lava shows.
