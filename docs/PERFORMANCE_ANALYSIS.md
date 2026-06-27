# Performance analysis

Scope: only performance costs introduced by this mod's runtime logic.

Out of scope:

- Cost of Factorio processing the resulting entities, projectiles, streams,
  explosions, fire, stickers, damage, pathfinding, sounds, particles, or corpse
  destruction.
- Cost that naturally follows from "the mod asked Factorio to create thousands
  of expensive vanilla effects".

This document is a static code-level analysis. It does not replace an in-game
UPS profile, but it identifies the places where the mod itself can create avoidable
work before Factorio's own projectile/effect simulation even starts.

## Summary

The current hot path has three main mod-side risks:

1. Real-launcher jobs are stored in one array that is fully scanned every tick.
   Large pending queues can become effectively quadratic.
2. Every emitted non-stream shot can perform a local entity search around the
   selected impact point.
3. Every detonation builds a full per-shot schedule table and sorts it, even when
   the detonation is immediate and does not need delayed scheduling.

These are independent from Factorio's own cost of executing the created effects.
They are costs paid by the mod's Lua logic.

## Priority 0: correctness issue that can become a performance leak

### P0.1. Rebuild/reset can orphan temporary launcher hosts

Relevant code:

- `runtime/launcher.lua`: `Launcher.reset_jobs()`
- `runtime/launcher.lua`: temporary host creation and cleanup in launcher jobs
- `control.lua`: `rebuild_runtime_state()`
- `/detonation_rebuild`
- `script.on_configuration_changed`

Current risk:

- `Launcher.reset_jobs()` clears `storage.launcher_jobs`.
- If active jobs already created temporary launcher host entities, clearing the
  job list removes the only cleanup reference.
- Those hidden characters can remain on the map permanently.

Why this affects performance:

- Orphaned hidden characters are real runtime entities.
- Even if they are invisible and non-interactive, they still exist in surfaces,
  saves, entity lists, and possibly force/entity bookkeeping.
- Repeating rebuilds during testing or after mod changes can accumulate leaked
  entities.

Suggested fix:

- Replace blind reset with cleanup reset:
  - iterate existing `storage.launcher_jobs`;
  - destroy `job.launcher` when valid;
  - clear stream retarget state related to those jobs;
  - then replace the job table.

Expected impact:

- Does not improve normal detonation hot path directly.
- Prevents permanent UPS/save pollution after rebuilds or configuration changes.

Verification:

- Start a launcher-sensitive detonation with delayed or sustained jobs.
- Run `/detonation_rebuild`.
- Check that hidden launcher hosts are destroyed.
- Confirm no invalid-job errors appear.

## Priority 1: major hot-path costs

### P1.1. Real-launcher queue scans all jobs every tick

Relevant code:

- `runtime/launcher.lua`: `Launcher.enqueue()`
- `runtime/launcher.lua`: `Launcher.process_jobs()`
- Constant: `MAX_STARTS_PER_TICK = 1`

Current behavior:

- Launcher jobs are appended into `storage.launcher_jobs`.
- `Launcher.process_jobs()` scans the whole array every tick.
- It starts at most one pending job per tick.
- Failed jobs are removed with `table.remove`, which shifts the rest of the
  array.

Why this is bad:

- Pending jobs remain in the array for many ticks.
- Because only one job starts per tick, a burst of `N` pending launcher jobs
  causes repeated scans of almost the same pending list.
- In the worst case this trends toward `O(N²)` Lua work before all jobs are
  even started.

Example:

- 10,000 launcher jobs.
- `MAX_STARTS_PER_TICK = 1`.
- The pending list is scanned across roughly 10,000 ticks.
- Total pending-job checks can be on the order of tens of millions.

This cost is caused by the mod, not by Factorio projectiles.

Suggested fix:

- Split launcher jobs into separate structures:
  - pending FIFO queue with a head index;
  - active jobs array for jobs that already created a temporary host;
  - optional delayed buckets keyed by start tick if launcher jobs can be delayed.
- Process only:
  - the next pending jobs up to the per-tick start budget;
  - currently active jobs that need firing/retargeting/cleanup.
- Avoid `table.remove` on large ordered arrays.
  - Use head index for FIFO pending queue.
  - Use swap-remove for unordered active arrays.

Expected impact:

- Large launcher bursts become roughly linear in number of jobs.
- Per-tick cost becomes bounded by:
  - start budget;
  - number of active launcher hosts;
  - stream retarget cadence.

Tradeoff:

- Slightly more storage schema complexity.
- Needs migration/backward compatibility for existing `storage.launcher_jobs`.

Verification:

- Add temporary profiling counters:
  - pending queue length;
  - active job count;
  - jobs inspected per tick;
  - jobs started per tick.
- Compare a large launcher-sensitive detonation before/after.
- Confirm deterministic behavior in multiplayer-sensitive code paths.

### P1.2. Per-shot local entity search in target snapping

Relevant code:

- `control.lua`: `resolve_final_target()`
- `control.lua`: `resolve_emit_target()`
- `control.lua`: hot path through `execute_emit_job()`

Current behavior:

- For each non-stream shot, the mod chooses a target position.
- Then it searches entities around that point with:
  - `surface.find_entities_filtered { position = ..., radius = 3 }`
- It builds a list of valid target entities.
- It may call health checks through protected calls.
- It chooses one nearby entity as the final target when possible.

Why this is expensive:

- Entity search is not free.
- The result table allocation is not free.
- Filtering and building `valid_targets` adds more Lua work.
- This happens once per emitted shot, not once per detonation.

Why it exists:

- Rocket-like projectiles may need a real entity target near the chosen impact
  point to reproduce damage reliably.
- The current method preserves the sampled landing point first, then only snaps
  locally, which avoids biasing the whole salvo toward dense entity clusters.

Suggested fixes:

Option A: restrict snapping by executor/family.

- Only call entity snapping for payload families that actually need entity
  targets.
- Position-safe families should use the chosen position directly.
- This requires careful classification and in-game validation.

Option B: cache local snap results within one detonation.

- Quantize target positions into small cells.
- Reuse the nearest valid entity result for shots landing in the same cell.
- Keep the cache local to one detonation execution.

Option C: batch entity discovery around the blast.

- Query candidate entities once for the relevant blast area.
- Select local candidates in Lua by distance to each sampled point.
- This can be better when there are many shots and not too many nearby entities.
- It can be worse in dense bases if the blast area contains many entities.

Expected impact:

- Large direct-spawn detonations with many non-stream shots should spend less
  time in Lua and surface queries.

Tradeoff:

- Too aggressive removal of snapping can regress rocket-like damage behavior.
- Any optimization must preserve "sample position first, snap locally second".

Verification:

- Test rocket-like direct-spawn ammo against:
  - isolated entity;
  - dense entity cluster;
  - empty terrain near entities;
  - mixed modded entities.
- Confirm impact spread remains unbiased.

### P1.3. Full per-shot schedule allocation and sort for immediate detonations

Relevant code:

- `control.lua`: `build_emit_schedule()`
- `control.lua`: `emit_payload()`
- `control.lua`: `enqueue_staggered_emit_job()`
- `control.lua`: `process_staggered_emit_jobs()`

Current behavior:

- A schedule entry is created for every shot.
- The schedule is sorted.
- Then entries are either executed immediately or stored as delayed jobs.

Why this is expensive:

- For `N` shots, this creates `N` Lua tables.
- Sorting costs `O(N log N)`.
- Immediate detonations do not need a persisted schedule.
- If there is only one payload node, sorting gives no useful interleave benefit.

This is purely mod-side overhead before any Factorio projectile/effect cost.

Suggested fix:

- Add fast paths:
  - no stagger and no initial delay: execute directly without creating schedule
    entries;
  - one payload node: loop count directly, no sort;
  - stagger disabled: preserve deterministic order without full schedule when
    visual interleaving is not required.
- Keep the existing schedule path for:
  - positive stagger;
  - positive initial delay;
  - cases where deterministic mixed-ammo interleave is intentionally needed.

Expected impact:

- Large immediate detonations avoid thousands of short-lived Lua tables and a
  sort.

Tradeoff:

- Need to preserve deterministic multiplayer behavior.
- Visual mixed-ammo ordering can change if the fast path bypasses the jittered
  interleave.

Verification:

- Compare output counts before/after for:
  - one ammo type;
  - mixed ammo types;
  - stagger off;
  - stagger on;
  - initial delay on/off.
- Confirm delayed jobs still execute at the same ticks when stagger is enabled.

## Priority 2: high-value optimizations

### P2.1. Per-shot table churn in emission path

Relevant code:

- `control.lua`: `copy_emit_node()`
- `control.lua`: `emit_payload()`
- `control.lua`: `execute_emit_job()`
- `control.lua`: `spawn_projectile()`
- `control.lua`: `execute_real_launcher_fallback()`
- `runtime/launcher.lua`: `Launcher.enqueue()`

Current behavior:

The hot path allocates many small tables per shot, including:

- schedule entry;
- copied payload node;
- emit job;
- copied center position;
- copied target position;
- `create_entity` params;
- projectile/launcher target positions;
- launcher job tables.

Why this matters:

- Lua allocation and garbage collection become visible during large detonations.
- Even if each table is cheap, thousands of shots make it measurable.

Suggested fixes:

- Avoid copying immutable node data for immediate execution.
- Pass stable node references through immediate paths.
- Allocate storage-safe copies only when a job crosses a tick boundary.
- Reuse local position tables where safe inside a single function.
- Precompute per-node fields once per detonation.

Expected impact:

- Less GC pressure and shorter same-tick spikes.

Tradeoff:

- Must not store references to mutable or invalid future state in `storage`.
- Delayed jobs still need safe copied data.

Verification:

- Add profiling around same-tick direct detonations.
- Check saved delayed jobs after save/load.

### P2.2. Staggered emit jobs store one job per shot

Relevant code:

- `control.lua`: `enqueue_staggered_emit_job()`
- `control.lua`: `process_staggered_emit_jobs()`
- `storage.emit_jobs`

Current behavior:

- With stagger or initial delay enabled, every scheduled shot becomes a stored
  job in `storage.emit_jobs`.

Why this matters:

- Large inventories create large storage tables.
- Save size and GC pressure increase.
- Processing future ticks still needs iterating job buckets.

Suggested fixes:

- Store compressed batch jobs where possible:
  - node reference/copy;
  - count;
  - deterministic RNG seed or precomputed compact sequence metadata;
  - execution tick range.
- Expand only the shots due on the current tick.

Expected impact:

- Much lower memory and save pressure for staggered bursts.

Tradeoff:

- More complex deterministic scheduling.
- Must preserve exact multiplayer determinism.

Verification:

- Compare emitted shot counts and tick distribution before/after with a fixed
  seed scenario.
- Test save/load during an active staggered detonation.

### P2.3. Negative launcher discovery is not cached

Relevant code:

- `runtime/launcher.lua`: launcher catalog/discovery functions
- `runtime/launcher.lua`: `Launcher.resolve_prototype()`
- `control.lua`: launcher-sensitive fallback path

Current behavior:

- Positive launcher discoveries are cached by category/item-related catalog data.
- Failed discoveries can be retried repeatedly.

Why this matters:

- If a launcher-sensitive family has no compatible runtime launcher, every shot
  can pay discovery/validation cost again.
- This is especially bad for modded ammo where dynamic discovery fails.

Suggested fix:

- Add negative cache entries:
  - by ammo category where appropriate;
  - by ammo item if item-specific range/type compatibility matters.
- Invalidate on configuration change/rebuild.

Expected impact:

- Failed launcher-sensitive paths become cheap after first failure.

Tradeoff:

- Cache key must include enough context to avoid hiding a valid item-specific
  launcher.

Verification:

- Test an ammo category with no compatible gun.
- Confirm discovery runs once per relevant key after rebuild, not per shot.

### P2.4. Launcher prototype resolution repeats per emitted shot

Relevant code:

- `control.lua`: `execute_real_launcher_fallback()`
- `runtime/launcher.lua`: `Launcher.resolve_prototype()`
- `runtime/launcher.lua`: effective range calculation

Current behavior:

- Launcher prototype resolution is called during emission.
- Some range/ammo-type work can repeat per shot even when the node is the same.

Why this matters:

- For many shots from one ammo node, the launcher decision is identical.
- Recomputing it per shot adds avoidable Lua work.

Suggested fix:

- Resolve launcher execution data once per payload node per detonation:
  - launcher prototype name;
  - effective min range;
  - effective max range;
  - family-specific targeting mode;
  - whether direct fallback should be used.
- Store that in a local per-detonation execution descriptor.

Expected impact:

- Lower overhead for large counts of the same ammo item/quality.

Tradeoff:

- Must keep item-specific range modifiers correct.
- Must not assume all ammo in one category has the same range modifier.

Verification:

- Test two ammo items in the same category with different range modifiers.
- Confirm each item keeps its own effective range.

## Priority 3: medium-risk or situational costs

### P3.1. Directional distribution can retry up to 16 times per shot

Relevant code:

- `distribution.lua`: directional sampler

Current behavior:

- Directional mode uses rejection sampling.
- It can attempt up to 16 samples per shot.

Why this matters:

- Normally acceptable.
- Becomes visible when combined with very large shot counts.

Suggested fix:

- Keep current behavior unless profiling shows directional mode is a significant
  contributor.
- If needed, replace rejection sampling with direct weighted sampling or a
  cheaper approximation.

Expected impact:

- Small to moderate improvement only when directional blasts are enabled.

Tradeoff:

- Any distribution change affects blast feel and should be tested visually.

### P3.2. Random speed uses expensive math per shot

Relevant code:

- `control.lua`: random projectile speed generation

Current behavior:

- Speed variation uses a Box-Muller-like path with functions such as `log`,
  `sqrt`, and `cos`.
- It can retry several times.

Why this matters:

- Expensive math per shot can add up.
- Usually smaller than schedule/entity-search costs.

Suggested fixes:

- Precompute a small deterministic table of normalized values per detonation or
  globally.
- Use a cheaper distribution if exact normal-like behavior is not important.

Expected impact:

- Moderate improvement for huge direct-spawn projectile bursts.

Tradeoff:

- Distribution shape may change slightly.
- Determinism must be preserved.

### P3.3. Damage modifiers are computed per projectile

Relevant code:

- `control.lua`: projectile spawn params
- `control.lua`: force/ammo damage modifier handling

Current behavior:

- Quality and research damage modifiers are attached per projectile.
- Some modifier lookup/composition can repeat for every shot.

Why this matters:

- Repeated force modifier lookup and table construction is avoidable for shots
  from the same payload node.

Suggested fix:

- Precompute modifier tables per payload node:
  - base quality modifier;
  - bonus research modifier;
  - immutable params fragment where safe.

Expected impact:

- Lower Lua work and table churn in direct projectile path.

Tradeoff:

- Do not reuse a table if Factorio mutates it internally.
- Safer approach: precompute scalar values, construct final params only when
  needed.

### P3.4. Stream retargeting work scales with active stream jobs

Relevant code:

- `runtime/launcher.lua`: stream retargeting
- `runtime/launcher.lua`: active launcher job processing

Current behavior:

- Active stream launcher jobs periodically rewrite `shooting_state`.
- Retargeting includes RNG/trig/range decisions and may call shooting validation.

Why this matters:

- This is intentional for sustained streams.
- Cost scales with number of active stream launcher hosts.

Suggested fixes:

- Keep active stream count bounded.
- Consider retarget cadence proportional to stream duration or job count.
- Avoid validation calls when the retarget point is already generated inside a
  previously validated safe envelope.

Expected impact:

- Helps flamethrower-like bursts with many simultaneous stream jobs.

Tradeoff:

- Too little retargeting makes streams visually static.
- Too much batching can change visual density.

### P3.5. Debug logs can become unbounded

Relevant code:

- `debug.lua`: `DEBUG_LOGS`
- `debug.lua`: `write_log()`

Current behavior:

- Debug entries are accumulated.
- When debug output is enabled, messages can be broadcast to players.

Why this matters:

- Debug mode can create heavy string allocation and UI/log spam.
- If unbounded, retained logs grow memory usage.

Suggested fix:

- Use a ring buffer with a fixed max size.
- Throttle repeated per-shot messages.
- Keep detailed per-shot logs behind a stronger debug level.

Expected impact:

- Debug mode becomes safer during large detonations.

Tradeoff:

- Old debug entries are dropped.

## Priority 4: load-time or command-time costs

### P4.1. Payload spec build scans prototypes and trigger trees

Relevant code:

- `control.lua`: payload spec building
- `runtime/launcher.lua`: launcher catalog build
- `data.lua`: data-stage generated helper prototypes

Current behavior:

- Runtime state rebuild scans relevant prototypes and recursively inspects trigger
  structures.
- Launcher catalog discovery scans gun/ammo-related prototypes.

Why this matters:

- This can hitch during:
  - mod init;
  - configuration change;
  - `/detonation_rebuild`.
- It is not steady-state UPS cost.

Suggested fix:

- Leave as lower priority unless rebuild hitches become a real issue.
- If needed, split rebuild into staged work across ticks.

Expected impact:

- Smoother rebuild command/config-change behavior.
- No meaningful improvement during normal gameplay after state is built.

### P4.2. Inventory and transport-line collection is mostly proportional

Relevant code:

- `control.lua`: entity inventory collection
- `control.lua`: transport line item collection/removal

Current behavior:

- The mod inspects inventories/transport lines for explosive payload items.
- Work is proportional to inventories, transport lines, and distinct item-quality
  entries.

Why this is acceptable:

- This is the core job of the mod.
- It is not obviously wasteful compared with the required behavior.

Suggested fix:

- No immediate optimization unless profiling identifies a specific container or
  belt path as hot.
- Keep quality-aware removal and avoid broad destructive operations.

## Suggested implementation order

1. Fix launcher reset cleanup.
   - Low complexity.
   - Prevents permanent leaked entities.
2. Replace launcher job storage with pending/active queues.
   - Highest risk reduction for launcher-sensitive families.
3. Add immediate detonation fast path that skips full schedule build/sort.
   - Highest value for direct-spawn bursts.
4. Restrict or cache `resolve_final_target()` entity snapping.
   - High value, but needs careful gameplay validation.
5. Precompute per-node launcher resolution and damage modifiers.
   - Good cleanup after the main architecture is stable.
6. Add negative launcher discovery cache.
   - Useful for mod compatibility and failed dynamic discovery.
7. Add debug ring buffer.
   - Low risk, useful during testing.

## Profiling counters worth adding temporarily

These counters should be development/debug-only and not kept as noisy normal
runtime output.

Per detonation:

- payload nodes count;
- total scheduled shots;
- immediate shots;
- delayed emit jobs created;
- schedule entries allocated;
- schedule sort size;
- target snap calls;
- target snap entities scanned;
- direct projectile creates requested;
- launcher jobs enqueued.

Per tick:

- pending launcher jobs;
- active launcher jobs;
- launcher jobs inspected;
- launcher jobs started;
- launcher jobs cleaned;
- stream retargets attempted;
- stream retargets applied;
- emit job buckets processed;
- emit jobs executed.

Useful derived metrics:

- Lua work per emitted shot.
- Launcher queue inspections per launcher job.
- Target snap calls per detonation.
- Stored jobs per source item.

## Definition of "done" for performance work

A performance change should be considered complete only when:

- It preserves multiplayer determinism.
- It preserves quality-aware payload behavior.
- It preserves modded prototype compatibility.
- It does not replace Factorio's real mechanics with manually patched damage.
- It does not rely on hardcoded vanilla item/entity names when dynamic detection
  is practical.
- It is verified with:
  - Lua language-server diagnostics;
  - representative in-game tests by the maintainer;
  - at least one large direct-spawn detonation;
  - at least one large launcher-sensitive detonation;
  - save/load during delayed or sustained jobs if storage format changed.

