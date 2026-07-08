# GROWING GUNS — Lore Bible

The steering document for tone, naming, and flavor. When adding content
(cards, SFX, announcer lines, arena dressing), check it against the tone
rules below.

## The premise

You're dead. Not damned — **drafted**.

The afterlife discovered long ago that punishing souls is inefficient;
letting them entertain each other is self-sustaining. The underworld's
biggest export is now live combat broadcasting, and its flagship show is
**MORE ROUNDS!** — an eternal last-man-standing format shot live from a
kitschy replica castle (the "Medieval Package" — the venue has others).

The rules of the show are the rules of the game:

| Mechanic | In-fiction |
|---|---|
| Respawning | You're already dead; the venue just reprints you. Death is the applause line, not the tragedy. |
| Loser picks a card | The House arms whoever's losing. Not mercy — **a boring fight is the only sin here**. One-sided matches empty seats, so the format guarantees nobody is ever weak enough to stop fighting or strong enough to stop needing to. That's the hell part. |
| Guns grow / turn fleshy | Weapons are bound demon larvae, armory-grown. Every card feeds yours; a fully-grown gun has a spine, teeth, and an eye that watches its wielder. The best-armed fighter is by definition the one who's lost the most. |
| Coop wave mode | Feral, unbound gun-larvae breach the arena floor. House rules suspend the deathmatch — even gladiators defend the venue. The crowd loves these episodes most. |
| Ion cannon / air strikes | Sponsor activations. The stadium's own halftime hardware. |
| Stone castle + energy weapons | Deliberate set dressing. Demons find medieval Europe kitschy the way we find Vegas pyramids kitschy. |
| Winning a match | Promotion. The league ladder ascends plane by plane toward nicer venues, better seats, and an exit that may or may not exist. Purgatory has a ladder, and every rung is a stadium. |

## Tone rules — how we avoid Generic Hell™

The underworld here is **vibrant, enthusiastic, and municipal** — an
entertainment district with a fandom problem, not a torture pit.

**DO:**
- Carnival and sports-broadcast energy: foam claws, vendor trays, halftime
  shows, betting boards, chant prompts.
- Saturated color: teal, magenta, gold, lime, cyan. Demons *love* color —
  eternal gray is what they're all escaping.
- Mundane bureaucracy jokes: the reprint desk, seating complaints,
  "sponsored by" everything, demons with day jobs and lanyards.
- Polite, chipper menace. The scariest thing anyone says is cheerful.
- Demons with mundane names (Bill, Susan, Gorlax from Accounting).

**DON'T:**
- Red + black palettes, pentagram iconography, gothic fonts, screaming
  skulls, edgy-metal grimdark. If it would fit on a van airbrushed in 1986,
  cut it.
- Fire and brimstone as decoration. Lava exists (it's load-bearing floor
  hazard) but it's treated like a pool feature, not a mood.
- Torture framing. Nobody here is being punished; they're being *scheduled*.

**The one red rule:** in the arena, the only red things are **you** — blood
and gun-flesh. Everything else trends colorful. This makes the gore and the
living guns pop as the show's special effect, which is exactly how the
crowd treats them (gore = pyrotechnics, not horror).

## Glossary

- **MORE ROUNDS!** — the show. Also the crowd's chant, and why respawn
  exists: there are always more rounds.
- **The Venue** — the colosseum. Current set: the Medieval Package.
- **The Management** — hell's entertainment arm. Immortal impresarios.
  Never seen, always credited.
- **The House** — the card system personified. "The House provides."
- **Gun-larvae** — what weapons are. Bound ones are guns; feral ones are
  the coop enemies. Same species.
- **Reprint** — respawning. Handled by the Complaints Department.
- **The Ladder** — the league structure of afterlife planes. Winning
  promotes; the top rung is unverified.

## Flavor conventions

**Card flavor text** — one dry line, sponsor-brand optional, references
feeding the gun where it fits:
- BIG MAG — *"Brought to you by Mag-Nificent™. It was hungry anyway."*
- GROW — *"It remembered your last three deaths fondly."*
- EXPLOSIVE ROUNDS — *"Sponsor activation! (Sponsor: OUCH!™)"*

**Announcer register** (future announcer demon): local sports radio, not
Satan. "He's down! He's up! That's the beauty of this place, folks!"

**Chants**: the crowd loves a good loser (a good loser is about to get
scary). "MORE ROUNDS! MORE ROUNDS!" is the universal one.

**Sponsor brands** (reusable): Mag-Nificent™, Barrel Bros., OUCH!™,
Soul-Dogs ("probably meat"), Styx Premium Ferry Lounge, Reprints-R-Us.

## Content backlog in this theme (cheap → big)

1. **Stadium TVs / jumbotrons** — shader-drawn broadcast screens on the
   stands (see banner.gdshader for the pattern): LIVE bug, scanlines,
   rotating odds/ads/chant prompts, "LOSER'S NEW TOY: <card>" after picks.
2. **Kill confetti** — a burst of colored quads mixed into the gore on
   kills; the crowd treats death as pyrotechnics, so should the VFX.
3. **Card pick screen as game show** — "THE HOUSE PROVIDES" header,
   sponsor stinger per card, ka-ching SFX.
4. **Crowd sections in team colors** — sections "bet on" players and cheer
   their picks (crowd shader already has enthusiasm/reaction hooks).
5. **Betting odds board** — tracks actual round wins; odds visibly shift
   after upsets.
6. **Announcer demon** — procedural gibberish voice (Animalese-style) with
   subtitles; hooks off existing CrowdAudio reaction events.
7. **Growth squelch SFX** — wet, cheerful sound synced to the card-growth
   morph; the gun purrs on reload when corruption is high.
8. **Vendor props** — Soul-Dog stands and foam-claw stalls in the stands.
9. **Halftime events** — mid-round sponsor moments: pickup rain, ion
   cannon "light show".
10. **The Ladder meta** — venue palette/dressing gets fancier as a match
    progresses (higher planes for later rounds); the final round is played
    in the Skybox.
