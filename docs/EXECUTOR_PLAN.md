# Executor Plan

## Goal
- Keep the current direct-spawn path for vanilla items that already behave correctly.
- Move only launcher-sensitive families to a real runtime launcher path.
- Avoid data stage combat execution and avoid manual damage top-ups. The runtime
  launcher host uses one hidden helper `character` prototype so the real shots do
  not briefly show a fake player character.

## Constraints
- Runtime-only combat execution.
- Prefer Factorio engine behavior over hand-simulated launcher semantics.
- Roll out by family, not by ad hoc item exceptions.

## Practical Matrix
| item | family | current executor | target executor | launcher prototype |
| --- | --- | --- | --- | --- |
| firearm-magazine | out-of-scope-projectile | skipped | out-of-scope | n/a |
| piercing-rounds-magazine | out-of-scope-projectile | skipped | out-of-scope | n/a |
| uranium-rounds-magazine | out-of-scope-projectile | skipped | out-of-scope | n/a |
| shotgun-shell | out-of-scope-projectile | skipped | out-of-scope | n/a |
| piercing-shotgun-shell | out-of-scope-projectile | skipped | out-of-scope | n/a |
| cannon-shell | direct-projectile | direct-spawn | direct-spawn | n/a |
| explosive-cannon-shell | direct-projectile | direct-spawn | direct-spawn | n/a |
| uranium-cannon-shell | direct-projectile | direct-spawn | direct-spawn | n/a |
| explosive-uranium-cannon-shell | direct-projectile | direct-spawn | direct-spawn | n/a |
| artillery-shell | direct-projectile | direct-spawn | direct-spawn | n/a |
| explosive-rocket | direct-projectile | direct-spawn | direct-spawn | n/a |
| atomic-bomb | direct-projectile | direct-spawn | direct-spawn | n/a |
| grenade | capsule-projectile | direct-spawn | direct-spawn | n/a |
| cluster-grenade | capsule-projectile | direct-spawn | direct-spawn | n/a |
| poison-capsule | capsule-projectile | direct-spawn | direct-spawn | n/a |
| slowdown-capsule | capsule-projectile | direct-spawn | direct-spawn | n/a |
| defender-capsule | capsule-projectile | direct-spawn | direct-spawn | n/a |
| distractor-capsule | capsule-projectile | direct-spawn | direct-spawn | n/a |
| destroyer-capsule | capsule-projectile | direct-spawn | direct-spawn | n/a |
| flamethrower-ammo | launcher-stream | direct-spawn | real-launcher | flamethrower |
| railgun-ammo | launcher-line | skipped | real-launcher | railgun |
| tesla-ammo | launcher-composite-beam | direct-spawn | real-launcher | teslagun |

## Family Notes
- `direct-projectile`
  - Safe to keep on `surface.create_entity{ name = projectile }` because the projectile prototype already carries the important behavior.
- `capsule-projectile`
  - Capsule usage collapses to a thrown projectile in the detonation case, so the current direct-spawn path is acceptable.
  - Future improvement path exists through `LuaItemStack.use_capsule(...)` if a capsule family ever needs true runtime item-use semantics.
- `launcher-stream`
  - Stream families need launcher semantics for correct runtime behavior and future damage-tech handling.
- `launcher-line`
  - `line` actions do not map onto the current leaf-entity extraction and need a real launcher.
  - Empty terrain shots must stay as position/direction targets instead of requiring a nearby entity.
- `launcher-composite-beam`
  - Composite launcher actions such as tesla `chain + beam` must be executed by a real launcher, not reduced to a single beam entity.

## Rollout Plan
1. Add explicit `family`, `current_executor`, `target_executor`, and `launcher_prototype` metadata to compiled item specs.
2. Keep the current direct-spawn path as the stable executor for `direct-projectile` and `capsule-projectile`.
3. Build a runtime launcher catalog dynamically by asking Factorio which items fit `character_guns` and can actually `can_shoot(...)` with the ammo item.
4. Introduce a real launcher executor behind family gates, starting with:
   - `tesla-ammo`
   - `flamethrower-ammo`
   - `railgun-ammo`
5. Convert one family at a time and leave the green-path families untouched during that rollout.

## Runtime Launcher State Machine
1. `emit_payload` decides per scheduled shot whether to stay on direct spawn or queue a runtime launcher job.
2. A launcher job stores:
   - `family`
   - `launcher_prototype`
   - source ammo item name
   - source position
   - target entity and target position
   - force/cause
   - direct-spawn fallback data
3. On the next tick, the launcher job tries to:
   - create a temporary `character`
   - insert the launcher gun into `character_guns`
   - insert the ammo item into `character_ammo`
   - set `selected_gun_index = 1`
   - select the target entity
   - set `shooting_state`
4. If launcher setup fails, the job falls back to the current direct-spawn executor for that shot.
5. If launcher setup succeeds, the host is released and destroyed a few ticks later.

## Runtime Module Boundary
- `control.lua` owns payload compilation, detonation scheduling, executor
  selection, and the direct-spawn fallback.
- `runtime/launcher.lua` owns only launcher-sensitive behavior:
  - family gates and launcher job storage;
  - empirical launcher discovery and the launcher catalog;
  - stream target normalization and retargeting;
  - temporary launcher-host creation, firing, and cleanup.
- The launcher module does not call the direct-spawn executor. When a delayed
  launcher job fails, it returns the stored job to `control.lua` through a
  callback so the existing fallback path remains the single owner of direct
  projectile creation.
- This extraction is intentionally behavior-preserving. Replacing empirical
  discovery with `LuaItemPrototype::attack_parameters` is a separate follow-up
  change after the three launcher families are verified in game.

## Runtime Launcher Discovery
- Runtime docs do not expose gun `attack_parameters` on `LuaItemPrototype`, so launcher discovery can not be metadata-only.
- Discovery therefore uses a temporary `character` plus temporary inventories:
  - try candidate items in `character_guns`
  - insert the ammo item into `character_ammo`
  - accept the candidate only if Factorio reports `can_shoot(...) == true`
- For position-targeted stream families, discovery can also probe outward
  distances and retain the empirical shootable envelope for that launcher.
- This keeps launcher selection runtime-only and compatible with modded guns that behave like normal character weapons.

## Current Implementation Target
- Runtime-launcher host entity strategy: temporary hidden
  `detonation-invisible-character`
- Status:
  - `tesla-ammo` verified in game; jumps and research bonus confirmed
  - `railgun-ammo` verified in game; `launcher-line` is enabled by default
  - `flamethrower-ammo` verified in game; `launcher-stream` is enabled by default
- `launcher-stream`, `launcher-composite-beam`, and `launcher-line` are enabled by default; family gates remain available for explicit rollback during testing

## Flamethrower Focus
- `flamethrower-ammo` is a `launcher-stream` family item with `target_type = "position"`.
- Discovery must use a dummy target beyond the vanilla `flamethrower` minimum range.
- Runtime shots should keep the aim target as a position projected outward from
  the blast center instead of snapping to nearby entities around the center.
- The stream executor needs a minimum aim distance so small blast spreads still
  produce a shootable target for the real launcher path.
- The stream executor should also clamp aim distance to the empirically
  discovered launcher max range so large detonation bursts do not flood the queue
  with guaranteed `launcher cannot shoot target` fallbacks.
- Delayed fallbacks should omit invalid `cause` entities before
  `surface.create_entity{...}` to avoid next-tick invalid-reference errors.

## Runtime Toggle Commands
- `/detonation_launcher_status`
  - Prints the current family-level launcher gates.
- `/detonation_launcher_enable launcher-composite-beam`
  - Enables the tesla-family runtime launcher path for testing.
- `/detonation_launcher_disable launcher-composite-beam`
  - Disables the tesla-family runtime launcher path and returns that family to the current direct-spawn path.
