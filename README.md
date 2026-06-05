[![Release](https://github.com/Nikitendo/detonation/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/Nikitendo/detonation/actions/workflows/release.yml)

# Detonation: When Ammo Blows Up

Storage is no longer safe.

Detonation is a Factorio 2.0 mod that makes explosive contents matter. When an
entity containing explosive ammunition or capsules is destroyed, the stored
payload detonates at that location instead of simply disappearing.

## Links

- GitHub: <https://github.com/Nikitendo/detonation>
- Factorio Mod Portal: <https://mods.factorio.com/mod/detonation>

## What it does

- Detonates explosive inventories when containers, machines, vehicles, belts, and
  other supported entities die.
- Handles player death before the corpse is created, so explosive items carried
  by the character can detonate once instead of being duplicated into the corpse.
- Preserves item quality when consuming and detonating payloads.
- Applies force/research damage bonuses where the runtime projectile path
  supports them.
- Uses deterministic spread and scheduling so multiplayer saves stay in lockstep.
- Supports direct projectile payloads such as rockets, cannon shells, artillery
  shells, grenades, capsules, and atomic bombs.
- Uses real runtime launcher shots for launcher-sensitive families such as
  flamethrower streams, railgun lines, and tesla chains/beams.

The mod discovers explosive behavior from runtime prototypes where possible
instead of relying on a fixed vanilla-only item list, which helps compatibility
with modded ammunition and weapons.

## Runtime settings

- **Maximum explosions per entity detonation**: caps the number of scheduled
  shots from one destroyed entity.
- **Average speed of detonated projectiles**: controls how fast spawned
  projectiles travel.
- **Directional explosions**: biases the payload away from the attacker while
  still allowing side and rear scatter.
- **Detonation duration**: spreads large payloads across multiple ticks instead
  of executing every shot on the same tick.
- **Delay before detonation**: waits before the first scheduled detonation shot.
- **Debug mode**: enables extra logging and debug UI; this can affect
  performance.

## Console commands

- `/detonation_stats` prints runtime cache and queue statistics.
- `/detonation_rebuild` rebuilds detonation payload mappings.
- `/detonation_launcher_status` prints real-launcher family gate states.
- `/detonation_launcher_enable <family>` enables a real-launcher family gate.
- `/detonation_launcher_disable <family>` disables a real-launcher family gate.
- `/detonation-debug` opens the debug log window.
- `/detonation-toggle-debug` toggles debug mode.

Launcher families currently used by the gate commands:

- `launcher-stream`
- `launcher-line`
- `launcher-composite-beam`

## Development notes

- Factorio version: 2.0
- Mod name: `detonation`
- License: MIT
- Release automation uses `semantic-release` and
  `semantic-release-factorio`.
- The release zip is built from `git archive`; files marked `export-ignore` in
  `.gitattributes` are excluded.

To package a local archive manually:

```sh
git archive --format zip --prefix detonation_[VERSION]/ --worktree-attributes --output detonation_[VERSION].zip HEAD
```

Use conventional commits when preparing release commits so the changelog and
version bump can be generated correctly.
