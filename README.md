# More Rounds

**Download for free on Itch.io**

- Fast paced Multiplayer FPS.
- Last man standing, new map every round.
- Losers of the round get to pick power-ups that stack.
- Abilities:
  - Left click is your gun, gets better / crazier depending on cards (more ammo, accuracy, power, explosions)
  - Right click does "special", can be replaced by cards
  - Space jump, double jump, can jump against walls (jumps further / higher than regular double jump)
  - Shift dash, reloads 1s. Dashes in direction player is walking
  - f = melee, instakill when hit from behind

## Development & Deployment

### Headless Compile & Export

To re-compile and export the project for macOS (e.g. for sharing with colleagues):

```bash
tools/build_release.sh         # builds mac + win → build/{macos,windows}/MoreRounds.zip
tools/build_release.sh mac     # macOS only
```

### Remote Playtesting

The build is exported to `build/macos/MoreRounds.zip`. This archive contains the `.app` bundle which can be distributed to other players on the local network.

- **Hosting:** Use the "HOST MATCH" button in the main menu.
- **Joining:** Colleagues can use the auto-discovery list or join via IP using the "JOIN BY IP" field.
- **Solo Play:** Use "VS BOT" to test mechanics without other players.
