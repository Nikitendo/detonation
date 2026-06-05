# AGENTS.md

## Scope
- Work only inside this mod folder:
  - `C:\Users\NikitendoMBS\AppData\Roaming\Factorio\mods\detonation`

## Local Paths
- Factorio install:
  - `E:\SteamLibrary\steamapps\common\Factorio`
- Runtime/API docs:
  - `E:\SteamLibrary\steamapps\common\Factorio\doc-html`
- Base game data:
  - `E:\SteamLibrary\steamapps\common\Factorio\data`

## Mandatory Workflow
- Before changing API-related logic, check local docs in `doc-html`.
- For runtime scripting questions, prefer runtime docs in:
  - `doc-html\classes\*.html`
  - `doc-html\concepts\*.html`

## Project Notes
- Read this file before edits:
  - `docs/CODEX_NOTES.md`

## Codex Session Learnings
- `doc-html` is often minified into one long line. Do not start with broad searches across the whole docs tree unless necessary; prefer opening the exact class page and extracting a small substring around the anchor/method name.
- Event reference lives in `doc-html\events.html`, not in a separate `events\` folder. For event payloads like `on_pre_player_died`, search inside `events.html`.
- `on_pre_player_died` is useful when explosive items must be removed before a corpse is created. If using it, usually skip `character` in `on_entity_died` to avoid double-processing player deaths.
- `LuaTransportLine::remove_item(items)` exists in 2.0.73. Prefer it over `clear()` so belts do not lose unrelated items when only explosive items should be consumed.
- `LuaSurface::create_entity{...}` accepts both `MapPosition` and `LuaEntity` for `target`, and `MapPosition`/`LuaEntity` for `source`.
- Rocket-like projectiles may need a real nearby entity as `target` to reliably deal damage. Preserve the random landing point first, then only snap to entities in a small radius around that point; do not search the whole blast radius or the spread becomes biased toward buildings.
- `find_entities_filtered{position=..., radius=...}` is the right tool for that local snap because it searches around the already chosen impact point instead of steering the whole salvo toward the densest area.
- Do not solve launcher-specific damage gaps by manually adding missing damage on top of a partially working spawned entity. If a weapon family needs launcher semantics, move it toward a real runtime launcher path instead.
- Do not use data stage for detonation-ammo execution. Combat behavior must be reproduced at runtime through Factorio's own runtime mechanisms.
- Before large architectural changes, write the current executor matrix and rollout plan into a markdown file under `docs/` so the target behavior stays explicit.

## Compatibility Policy
- Avoid hardcoded entity/item name lists when dynamic detection is possible.
- Keep behavior compatible with modded entities and forces.
- If Factorio API format changed, update notes in `docs/CODEX_NOTES.md` and the related code comments.
