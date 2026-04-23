# Rounds FPS

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
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release "macOS LAN Debug" ./JumpShoot.zip
```

### Remote Playtesting

The build is exported to `JumpShoot.zip`. This archive contains the `.app` bundle which can be distributed to other players on the local network.

- **Hosting:** Use the "HOST MATCH" button in the main menu.
- **Joining:** Colleagues can use the auto-discovery list or join via IP using the "JOIN BY IP" field.
- **Solo Play:** Use "VS BOT" to test mechanics without other players.
