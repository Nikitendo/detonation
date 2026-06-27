# CODEX Notes

## Factorio API Facts (Verified)
- Source: local docs `D:\SteamLibrary\steamapps\common\Factorio\doc-html`
- Latest verification: `2.1.8`

### `get_contents()` return type in 2.0.76
- `LuaInventory::get_contents() -> ItemWithQualityCounts`
- `LuaTransportLine::get_contents() -> ItemWithQualityCounts`
- `ItemWithQualityCounts = array[ItemWithQualityCount]`
- `ItemWithQualityCount` fields:
  - `name: string`
  - `quality: string`
  - `count: ItemCountType`

Practical implication:
- Iterate via array records (e.g. `ipairs(contents)`), not dictionary `["item"]=count`.
- Preserve `quality` when removing consumed items from inventories or transport
  lines. `ItemStackDefinition.quality` defaults to `"normal"` when omitted, so
  omitting it can remove the wrong quality stack.

### Quality-aware detonation execution in 2.0.76
- `LuaItemStack::quality -> LuaQualityPrototype`
- `LuaQualityPrototype::default_multiplier` defaults to `1 + 0.3 * level`.
- `ItemStackDefinition` accepts `quality: string?`.
- `TriggerModifierData` accepts `damage_modifier`, `damage_addition`, and
  `radius_modifier`.

Practical implication:
- Treat quality as part of a payload node identity, not just display metadata.
- For real-launcher execution, insert the source ammo item with its original
  quality into the temporary character ammo inventory.
- For direct projectile execution, attach the quality damage scalar through
  `base_damage_modifiers = { damage_modifier = quality.default_multiplier }`.

### Projectile damage modifiers in 2.0.76
- `LuaSurface::create_entity{...}` for `projectile` accepts:
  - `base_damage_modifiers :: TriggerModifierData?` (for quality)
  - `bonus_damage_modifiers :: TriggerModifierData?` (research damage bonus)
- `LuaEntity` for projectile entities also exposes RW properties:
  - `base_damage_modifiers`
  - `bonus_damage_modifiers`

Practical implication:
- Prefer attaching research damage scaling directly to the spawned projectile via
  `bonus_damage_modifiers`.
- `LuaForce.get_ammo_damage_modifier(ammo)` returns the bonus part, so the
  projectile scalar must be `1 + bonus`, not just `bonus`.

Practical implication:
- If you need a protected call, wrap `force.get_ammo_damage_modifier(ammo)` in a
  closure for `pcall`.
- Do not call `pcall(force.get_ammo_damage_modifier, force, ammo)` because that
  over-passes the receiver and throws an arguments count error at runtime.

### `create_entity` target/source for beams in 2.0.76
- `LuaSurface::create_entity{...}` shared fields:
  - `target :: LuaEntity or MapPosition?`
  - `source :: LuaEntity or MapPosition?`
  - `cause :: LuaEntity?`
- `source` is explicitly documented as used for beams and projectiles.
- Beam-specific create params:
  - `target_position :: MapPosition?`
  - `source_position :: MapPosition?`
  - `max_length :: uint32?`
  - `duration :: uint32?`
  - `source_offset :: Vector?`

### Launcher-control facts in 2.1.8
- `LuaControl.shooting_state` is writable.
- `LuaControl.shooting_state.position` is the cursor/aim position being shot at.
- `LuaEntity.selected_gun_index` is writable for:
  - `Character`
  - `Car`
  - `SpiderVehicle`
- `LuaItemPrototype::attack_parameters -> AttackParameters?` is available for
  gun items at runtime.
- `AttackParameters` exposes:
  - `ammo_categories`
  - `type`
  - `min_range`
  - `range`
- `LuaItemPrototype::get_ammo_type("player")` exposes the player-specific
  `AmmoType`, including `range_modifier`.
- `LuaEntity::can_shoot(target, position)` is documented on `LuaEntity` and takes:
  - `target :: LuaEntity`
  - `position :: MapPosition`
- `LuaEntity` has no general `visible` runtime attribute.
- `LuaEntity::render_player` and `LuaEntity::render_to_forces` are documented for
  `simple-entity-with-owner`, `simple-entity-with-force`, and `highlight-box`, not
  for `Character`.
- The visibility/rendering facts above were checked against local docs `2.1.8`.

Practical implication:
- There is a possible runtime path where a temporary real launcher entity performs
  a vanilla shot instead of the mod recreating launcher semantics by hand.
- Launcher discovery first filters gun prototypes by
  `attack_parameters.ammo_categories`.
- Effective maximum range is `attack_parameters.range *
  ammo_type.range_modifier`; `min_range` is not affected by the ammo modifier.
- Cache launcher identity by ammo category, but calculate effective range per
  ammo item; different items in one category may have different range modifiers.
- The practical temporary-character `can_shoot(...)` check remains as final
  validation for inventory compatibility, target semantics, and modded weapons.
- Position-targeted launcher families still need practical runtime testing because
  the docs do not clarify whether `target` may be omitted when only position
  aiming matters.
- Vanilla `railgun-ammo` uses `target_type = "direction"`, `clamp_position = true`,
  and a `line` action. The detonation real-launcher path must allow a `MapPosition`
  target for `launcher-line`; otherwise empty terrain shots are skipped before
  the temporary character can reproduce the player's normal empty-tile shot.
- Do not require `LuaEntity::can_shoot(nil, position)` before a `launcher-line`
  empty-terrain shot. `can_shoot` is documented with a non-optional
  `target :: LuaEntity`; the real empty-terrain action is reproduced by writing
  `LuaControl.shooting_state.position`.
- To keep real launcher hosts invisible, use the hidden data-stage clone
  `detonation-invisible-character`; runtime-only flags can make a
  normal character non-interactive, but not reliably invisible.
- CharacterPrototype fields `mining_with_tool_particles_animation_positions`,
  `running_sound_animation_positions`, and `moving_sound_animation_positions`
  are required in 2.0.76, so the invisible host keeps the base values instead of
  deleting them.
- Alpha-tinting the base character sprites still leaves a faint visible
  silhouette. The invisible host uses a real transparent spritesheet
  (`graphics/invisible-character.png`) with the required character animation
  frame/direction counts.

### Flamethrower launcher notes
- Vanilla `flamethrower-ammo` uses `target_type = "position"` and `type = "stream"`.
- Vanilla `flamethrower` has `min_range = 3`.

Practical implication:
- Launcher discovery for `flamethrower-ammo` must not use a dummy target closer
  than 3 tiles or `can_shoot(...)` will reject the candidate even when the gun
  is otherwise valid.
- Stream-family launcher discovery reads the shootable envelope from
  `attack_parameters.min_range` and the ammo-adjusted maximum range, then uses
  `can_shoot(...)` once as final validation.
- Real runtime stream shots should prefer an outward position target from the
  blast center instead of snapping to a nearby entity, otherwise the flame can
  visibly originate around the blast and travel back inward.
- Stream families may need a family-level minimum aim distance even when the
  sampled blast spread is smaller than the weapon's real minimum range.
- Delayed direct-spawn fallbacks must sanitize `cause` before calling
  `surface.create_entity{...}` because the original destroyed entity may already
  be invalid on the next tick.
- When a launcher family graduates from opt-in testing to default-on behavior,
  bump the saved gate-defaults version so existing saves pick up the new family
  automatically instead of staying on the old fallback path.
- Real runtime flamethrower detonation should batch many virtual charges into a
  smaller number of sustained launcher jobs; spawning one temporary character
  per charge causes severe hitches and visually weak one-tick puffs.
- If stream ammo should map one source item to one visible stream, budget the
  limiter by source item count and keep the full `magazine_size` as the stream
  job charge size; otherwise the global virtual-charge cap collapses the burst
  back down to only a few streams.
- For `launcher-stream`, `payload_total` and per-node `exact_count` should also
  count source items, not `magazine_size`, or the blast gets inflated before
  the budget stage even runs.
- When a real stream launcher has a finite valid range window (for vanilla
  flamethrower roughly `4..15` after the family safety margin), clamping
  overshoot directly to `max_distance` creates a visible outer ring. Sampling
  distance uniformly over the reachable annulus keeps dense blasts spread over
  the whole valid area instead.
- Sustained real-launcher streams do not need to hold one fixed impact point for
  their whole lifetime; periodically rewriting `LuaControl.shooting_state`
  inside the already-valid aim envelope gives a more natural sweep without
  leaving the real `can_shoot(...)` range.

### Runtime gap for generic item use in 2.0.76
- No generic runtime API entry point was found for:
  - "use this capsule/item now"
  - "execute this active trigger now"
- `LuaSurface::create_entity{...}` exposes bonus damage modifiers for
  `projectile`, but not for `beam` or `stream`.

Practical implication:
- The direct-spawn path is a good fit for projectile-centric families.
- Launcher-sensitive families such as `stream`, `line`, or composite
  `chain + beam` should move toward a real runtime launcher path instead of
  partial beam/stream recreation.

### Capsule-use fact in 2.0.76
- `LuaItemStack::use_capsule(entity, target_position)` exists at runtime.

Practical implication:
- Capsule families can eventually move to a true runtime item-use path without
  data stage changes if the current direct projectile path ever becomes
  insufficient.

### Save/load stability rule for `storage`
- `on_load()` must not mutate `storage`.

Practical implication:
- Runtime-only caches and feature gates that live in `storage` must be
  initialized in write-allowed paths such as `on_init`,
  `on_configuration_changed`, commands, or normal gameplay events.
- `on_load()` should rebuild only local Lua references from existing `storage`
  state and fall back to read-only defaults when fields are absent.

## Mod Development Guardrails
- Prefer dynamic discovery over hardcoded prototype names.
- For belt-like entities, do not assume only vanilla belt types exist.
- Keep explosion logic deterministic for multiplayer.
- Directional blasts are an optional runtime setting. They use
  `on_entity_died.cause.position` only to bias the emission direction; if no valid
  cause position exists, keep the existing radial distribution.
- Directional blasts sample the full circle with a continuous forward-weighted
  angular distribution, not a cone-only bucket. The backward direction keeps a
  low non-zero weight so rear/side scatter remains possible, while the forward
  half gets most shots. Forward shots also get a smooth distance bonus so the
  biased mode still has visible reach.
- Staggered detonations use the integer runtime setting
  `detonation-staggered-detonations`. A value of `0` executes immediately.
  Positive values expand one inventory detonation into per-shot emit jobs keyed
  by future tick over `value + floor(sqrt(scheduled_count))` ticks, so large
  inventories become a configurable burst instead of one same-tick spike.
- Staggered emit order is a deterministic jittered interleave across sorted
  payload nodes, not grouped by item type. This keeps multiplayer lockstep while
  making mixed-ammo inventories visually mixed across the burst window.
- `detonation-initial-detonation-delay` adds a runtime-configurable tick
  offset before the first detonation. With stagger disabled, a positive value
  queues every shot for that delayed tick instead of executing immediately.

## Maintenance Checklist
- If upgrading Factorio version:
  1. Re-check `get_contents()` signatures in local docs.
  2. Re-check relevant concepts (`ItemWithQualityCounts`, `ItemWithQualityCount`).
  3. Update code comments and this file if API behavior changed.
