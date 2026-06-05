-- ============================================================================
-- Detonation: When Ammo Blows Up
-- Data-driven payload compiler + pluggable distribution strategies
-- ============================================================================

local Debug = require("debug")
local Distribution = require("distribution")
local debug_enabled = Debug.enabled

local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_log = math.log
local math_cos = math.cos
local math_sin = math.sin
local math_sqrt = math.sqrt
local table_sort = table.sort
local TWO_PI = 2 * math.pi

local DEFAULT_PROJECTILE_DAMAGE = 50
local DEFAULT_FORCE_NAME = "player"
local DEFAULT_QUALITY_NAME = "normal"
local SEED_MODULUS = 2147483646
local DEFAULT_AVERAGE_PROJECTILE_SPEED = 0.55
local MIN_PROJECTILE_SPEED = 0.1
local MAX_PROJECTILE_SPEED = 2.0
local PROJECTILE_SPEED_SIGMA = (MAX_PROJECTILE_SPEED - MIN_PROJECTILE_SPEED) / 6
local EMIT_SCHEDULE_JITTER_SCALE = 100000

local EXECUTOR_DIRECT_SPAWN = "direct-spawn"
local EXECUTOR_REAL_LAUNCHER = "real-launcher"
local EXECUTOR_SKIPPED = "skipped"

local FAMILY_DIRECT_PROJECTILE = "direct-projectile"
local FAMILY_CAPSULE_PROJECTILE = "capsule-projectile"
local FAMILY_LAUNCHER_STREAM = "launcher-stream"
local FAMILY_LAUNCHER_LINE = "launcher-line"
local FAMILY_LAUNCHER_COMPOSITE_BEAM = "launcher-composite-beam"
local FAMILY_UNKNOWN = "unknown"

local REAL_LAUNCHER_HOST_CHARACTER = "detonation-invisible-character"
local REAL_LAUNCHER_SPAWN_DELAY = 1
local REAL_LAUNCHER_DEFAULT_FIRE_TICKS = 1
local REAL_LAUNCHER_DEFAULT_CLEANUP_TICKS = 2
local REAL_LAUNCHER_MAX_STARTS_PER_TICK = 1
local REAL_LAUNCHER_DISCOVERY_TARGET_OFFSET = 6
local REAL_LAUNCHER_STREAM_MIN_AIM_DISTANCE = 4.0
local REAL_LAUNCHER_STREAM_MIN_FIRE_TICKS = 20
local REAL_LAUNCHER_STREAM_MAX_FIRE_TICKS = 120
local REAL_LAUNCHER_STREAM_RETARGET_INTERVAL_TICKS = 5
local REAL_LAUNCHER_STREAM_RETARGET_MAX_ANGLE_OFFSET = math.pi * 10
local REAL_LAUNCHER_STREAM_RETARGET_MAX_DISTANCE_OFFSET = 2.0
local REAL_LAUNCHER_RANGE_PROBE_MAX_DISTANCE = 64
local REAL_LAUNCHER_HOST_SEARCH_RADIUS = 1.5
local REAL_LAUNCHER_HOST_SEARCH_PRECISION = 0.25

local REAL_LAUNCHER_ENABLED_FAMILIES = {
  [FAMILY_LAUNCHER_STREAM] = true,
  [FAMILY_LAUNCHER_COMPOSITE_BEAM] = true,
  [FAMILY_LAUNCHER_LINE] = true,
}

local REAL_LAUNCHER_GATE_DEFAULTS_VERSION = 3

local MANUAL_ITEM_SPECS = {
  ["explosives"]       = { projectile = "cluster-grenade", ammo_category = "grenade" },
  ["cliff-explosives"] = { projectile = "explosive-rocket" },
}

local DELIVERY_SCAN_KEYS = {
  "action",
  "actions",
  "action_delivery",
  "action_deliveries",
  "target_effects",
  "source_effects",
  "effects",
  "final_action",
  "attack_result",
  "created_effect",
  "trigger_effect",
  "repeat_action",
  "inner_action",
  "result",
}

local ITEM_SPECS = nil
local PROJECTILE_SPECS = nil
local ENTITY_CAPS = nil
local LAUNCHER_CATALOG = nil
local find_damage_in_action
local process_tick
local ensure_tick_handler
local refresh_tick_handler
local tick_handler_registered = false
local destroy_real_launcher_entity
local set_real_launcher_flags

-- NOTE FOR FUTURE MAINTAINERS (verified against local Factorio docs 2.0.73):
-- LuaInventory::get_contents() and LuaTransportLine::get_contents() return
-- ItemWithQualityCounts = array[ItemWithQualityCount], where each record has:
--   { name = string, quality = string, count = ItemCountType }
local function for_each_item_count(contents, callback)
  if type(contents) ~= "table" then return end

  for i = 1, #contents do
    local item = contents[i]
    if item and item.name and item.count and item.count > 0 then
      callback(item.name, item.count, item.quality)
    end
  end
end

local function deterministic_seed(center, tick)
  local x    = math_floor(center.x * 1000)
  local y    = math_floor(center.y * 1000)
  local seed = x * 73856093 + y * 19349663 + tick * 83492791
  local r    = seed % SEED_MODULUS
  return (r < 0 and r + SEED_MODULUS or r) + 1
end

local function resolve_entity_force(entity)
  if not (entity and entity.valid) then return nil end

  local ok, force = pcall(function() return entity.force end)
  if ok and force and force.valid then return force end

  return nil
end

local function resolve_default_force()
  return game.forces[DEFAULT_FORCE_NAME]
end

local function normalize_id_name(value)
  if type(value) == "string" then return value end
  if value == nil then return nil end

  local ok, name = pcall(function() return value.name end)
  if ok and type(name) == "string" then return name end

  return nil
end

local function normalize_quality_name(quality)
  return normalize_id_name(quality) or DEFAULT_QUALITY_NAME
end

local function item_stack_definition(item_name, item_count, quality)
  return {
    name = item_name,
    count = item_count,
    quality = normalize_quality_name(quality),
  }
end

local function payload_key(payload_name, quality)
  return payload_name .. "\n" .. normalize_quality_name(quality)
end

local function describe_position(pos)
  if type(pos) == "table" and type(pos.x) == "number" and type(pos.y) == "number" then
    local x = math_floor(pos.x * 10) / 10
    local y = math_floor(pos.y * 10) / 10
    return "(" .. x .. "," .. y .. ")"
  end
  return tostring(pos)
end

local function describe_entity(entity)
  if entity == nil then return "nil" end

  local ok_valid, valid = pcall(function() return entity.valid end)
  if ok_valid and valid == false then return "invalid-entity" end

  local ok_name, name = pcall(function() return entity.name end)
  local ok_type, entity_type = pcall(function() return entity.type end)
  local ok_unit, unit = pcall(function() return entity.unit_number end)

  return tostring(ok_name and name or "entity")
      .. "[" .. tostring(ok_type and entity_type or "?") .. "]"
      .. "#" .. tostring(ok_unit and unit or "?")
end

local function describe_target(target)
  if target == nil then return "nil" end

  local ok_valid, valid = pcall(function() return target.valid end)
  if ok_valid and valid ~= nil then
    if valid == false then return "invalid-target-entity" end
    return describe_entity(target)
  end

  if type(target) == "table" and type(target.x) == "number" and type(target.y) == "number" then
    return describe_position(target)
  end

  return tostring(target)
end

local function is_map_position(value)
  return type(value) == "table"
      and type(value.x) == "number"
      and type(value.y) == "number"
end

local function is_valid_entity_reference(value)
  if value == nil then return false end
  local ok_valid, valid = pcall(function() return value.valid end)
  return ok_valid and valid == true
end

local function real_launcher_family_accepts_position_target(family)
  return family == FAMILY_LAUNCHER_STREAM
      or family == FAMILY_LAUNCHER_LINE
end

local function sanitize_entity_reference(value)
  if not is_valid_entity_reference(value) then return nil end
  return value
end

local function copy_position(pos)
  if not is_map_position(pos) then return nil end
  local x = pos.x
  local y = pos.y
  return { x = x, y = y }
end

local function describe_direction(direction)
  if not direction then return "nil" end
  local x = math_floor(direction.x * 100) / 100
  local y = math_floor(direction.y * 100) / 100
  return "(" .. x .. "," .. y .. ")"
end

local function is_directional_blast_enabled()
  local setting = settings.global["detonation-directional-blasts"]
  return setting and setting.value == true
end

local function resolve_impact_direction(entity, cause)
  if not is_directional_blast_enabled() then return nil end
  if not (entity and entity.valid and cause and cause.valid) then return nil end

  local source_position = copy_position(cause.position)
  local center = copy_position(entity.position)
  if not source_position or not center then return nil end

  local dx = center.x - source_position.x
  local dy = center.y - source_position.y
  local length = math_sqrt(dx * dx + dy * dy)
  if length <= 0.001 then return nil end

  return {
    x = dx / length,
    y = dy / length,
  }
end

local function normalize_random_seed(seed)
  local normalized = math_floor(seed or 1)
  local wrapped = normalized % SEED_MODULUS
  if wrapped < 0 then
    wrapped = wrapped + SEED_MODULUS
  end
  return wrapped + 1
end

local function default_real_launcher_enabled_families()
  local enabled = {}
  for family, value in pairs(REAL_LAUNCHER_ENABLED_FAMILIES) do
    enabled[family] = value == true
  end
  return enabled
end

local function initialize_runtime_storage()
  storage.launcher_jobs = storage.launcher_jobs or {}
  storage.emit_jobs = storage.emit_jobs or {}
  storage.emit_job_count = storage.emit_job_count or 0
  storage.real_launcher_enabled_families = storage.real_launcher_enabled_families or
      default_real_launcher_enabled_families()

  local defaults_version = storage.real_launcher_gate_defaults_version or 0
  if defaults_version < REAL_LAUNCHER_GATE_DEFAULTS_VERSION then
    storage.real_launcher_enabled_families[FAMILY_LAUNCHER_STREAM] = true
    storage.real_launcher_enabled_families[FAMILY_LAUNCHER_COMPOSITE_BEAM] = true
    storage.real_launcher_enabled_families[FAMILY_LAUNCHER_LINE] = true
    storage.real_launcher_gate_defaults_version = REAL_LAUNCHER_GATE_DEFAULTS_VERSION
  end
end

local function has_pending_emit_jobs()
  if not storage then return false end
  if (storage.emit_job_count or 0) > 0 then return true end

  local jobs = storage.emit_jobs
  if not jobs then return false end
  for _, bucket in pairs(jobs) do
    if bucket and #bucket > 0 then return true end
  end

  return false
end

local function has_pending_launcher_jobs()
  if not storage then return false end

  local jobs = storage.launcher_jobs
  return jobs ~= nil and #jobs > 0
end

local function has_pending_tick_work()
  return has_pending_emit_jobs() or has_pending_launcher_jobs()
end

ensure_tick_handler = function()
  if tick_handler_registered or not process_tick then return end
  script.on_event(defines.events.on_tick, process_tick)
  tick_handler_registered = true
end

refresh_tick_handler = function()
  if has_pending_tick_work() then
    ensure_tick_handler()
  elseif tick_handler_registered then
    script.on_event(defines.events.on_tick, nil)
    tick_handler_registered = false
  end
end

local function get_real_launcher_enabled_families()
  local enabled = storage.real_launcher_enabled_families
  if type(enabled) == "table" then return enabled end
  return REAL_LAUNCHER_ENABLED_FAMILIES
end

local function is_real_launcher_family_enabled(family)
  local enabled = get_real_launcher_enabled_families()
  if enabled and enabled[family] ~= nil then
    return enabled[family] == true
  end
  return REAL_LAUNCHER_ENABLED_FAMILIES[family] == true
end

local function resolve_projectile_cause_entity(entity)
  if not (entity and entity.valid) then return nil end

  local ok, last_user = pcall(function() return entity.last_user end)
  if ok and last_user then
    local character = last_user.character
    if character and character.valid then return character end
  end

  return entity
end

local function extract_ammo_category(prototype, manual)
  if manual and manual.ammo_category then
    return manual.ammo_category
  end

  local direct_ammo_category = normalize_id_name(prototype.ammo_category)
  if direct_ammo_category then return direct_ammo_category end

  local ok_capsule_action, capsule_action = pcall(function() return prototype.capsule_action end)
  if ok_capsule_action and capsule_action and capsule_action.attack_parameters then
    local ammo_categories = capsule_action.attack_parameters.ammo_categories
    if type(ammo_categories) == "table" then
      for i = 1, #ammo_categories do
        local cat = normalize_id_name(ammo_categories[i]) or ammo_categories[i]
        if type(cat) == "string" then return cat end
      end
    end
  end

  local ok, ammo_type = pcall(function() return prototype.get_ammo_type() end)
  if ok and ammo_type then
    return normalize_id_name(ammo_type.category)
        or normalize_id_name(ammo_type.ammo_category)
        or ammo_type.category
        or ammo_type.ammo_category
  end

  return nil
end

local function get_projectile_damage_modifiers(force, ammo_category)
  if not (force and force.valid) then return nil end
  if not ammo_category then return nil end

  local ok, bonus = pcall(function() return force.get_ammo_damage_modifier(ammo_category) end)
  if not ok or type(bonus) ~= "number" then return nil end
  if not bonus or bonus <= 0 then return nil end

  return { damage_modifier = 1 + bonus }
end

local function get_projectile_quality_modifiers(quality)
  local quality_name = normalize_quality_name(quality)
  if quality_name == DEFAULT_QUALITY_NAME then return nil end

  local prototype = prototypes.quality and prototypes.quality[quality_name] or nil
  if not prototype then return nil end

  local ok, multiplier = pcall(function() return prototype.default_multiplier end)
  if not ok or type(multiplier) ~= "number" or multiplier <= 0 then return nil end
  if multiplier == 1 then return nil end

  return { damage_modifier = multiplier }
end

local function extract_item_action_root(prototype)
  local ok_capsule_action, capsule_action = pcall(function() return prototype.capsule_action end)
  if ok_capsule_action and capsule_action then
    return capsule_action, "capsule_action"
  end

  local ok, ammo_type = pcall(function() return prototype.get_ammo_type() end)
  if ok and ammo_type and ammo_type.action then
    return ammo_type.action, "ammo_type.action"
  end

  return nil, "none"
end

local function safe_table_index(node, key)
  local ok, value = pcall(function() return node[key] end)
  if not ok then return nil end
  return value
end

local find_delivery_entity_in_table

local function scan_action_features(node, depth, seen, features)
  if depth > 18 or type(node) ~= "table" then return features end

  seen = seen or {}
  if seen[node] then return features end
  seen[node] = true

  features = features or {
    has_projectile = false,
    has_stream = false,
    has_beam = false,
    has_chain = false,
    has_line = false,
    has_nested_result = false,
  }

  local node_type = safe_table_index(node, "type")
  if node_type == "line" then
    features.has_line = true
  elseif node_type == "nested-result" then
    features.has_nested_result = true
  end

  if type(safe_table_index(node, "projectile")) == "string" then features.has_projectile = true end
  if type(safe_table_index(node, "stream")) == "string" then features.has_stream = true end
  if type(safe_table_index(node, "beam")) == "string" then features.has_beam = true end
  if type(safe_table_index(node, "chain")) == "string" then features.has_chain = true end

  for i = 1, 64 do
    local child = safe_table_index(node, i)
    if child == nil then break end
    scan_action_features(child, depth + 1, seen, features)
  end

  for i = 1, #DELIVERY_SCAN_KEYS do
    local child = safe_table_index(node, DELIVERY_SCAN_KEYS[i])
    if child ~= nil then
      scan_action_features(child, depth + 1, seen, features)
    end
  end

  for key, value in pairs(node) do
    if type(key) ~= "number" then
      scan_action_features(value, depth + 1, seen, features)
    end
  end

  return features
end

local function new_action_features()
  return {
    has_projectile = false,
    has_stream = false,
    has_beam = false,
    has_chain = false,
    has_line = false,
    has_nested_result = false,
  }
end

local function is_hidden_item_prototype(prototype)
  local ok_hidden, hidden = pcall(function() return prototype.has_flag("hidden") end)
  if ok_hidden then return hidden == true end
  return safe_table_index(prototype, "hidden") == true
end

local function choose_launcher_catalog_entry(existing, item_name, prototype, min_distance, max_distance)
  local hidden = is_hidden_item_prototype(prototype)
  if not existing
      or (existing.hidden and not hidden)
      or (existing.hidden == hidden and item_name < existing.name)
  then
    return {
      name = item_name,
      hidden = hidden,
      min_distance = min_distance,
      max_distance = max_distance,
    }
  end

  return existing
end

local function find_launcher_discovery_surface()
  local surface = game.get_surface(1)
  if surface then return surface end

  for _, candidate in pairs(game.surfaces) do
    return candidate
  end

  return nil
end

local function find_non_colliding_position_safe(surface, entity_name, position, radius, precision)
  local ok_pos, found = pcall(function()
    return surface.find_non_colliding_position(entity_name, position, radius, precision)
  end)
  if not ok_pos then return nil end
  return found
end

local function clear_inventory_safe(inventory)
  if not (inventory and inventory.valid) then return end
  pcall(function() inventory.clear() end)
end

local function destroy_launcher_discovery_context(context)
  if not context then return end
  clear_inventory_safe(context.guns)
  clear_inventory_safe(context.ammo)
  destroy_real_launcher_entity(context.launcher)
  destroy_real_launcher_entity(context.target)
end

local function try_real_launcher_can_shoot(launcher, family, target_entity, target_position)
  if not (launcher and launcher.valid and is_map_position(target_position)) then return false end

  if target_entity then
    local ok_can_shoot, can_shoot = pcall(function()
      return launcher.can_shoot(target_entity, target_position)
    end)
    return ok_can_shoot and can_shoot == true
  end

  if not real_launcher_family_accepts_position_target(family) then return false end

  local ok_can_shoot, can_shoot = pcall(function()
    return launcher.can_shoot(nil, target_position)
  end)
  if ok_can_shoot and can_shoot then
    return true
  end

  if family ~= FAMILY_LAUNCHER_STREAM then
    return false
  end

  ok_can_shoot, can_shoot = pcall(function()
    return launcher.can_shoot(launcher, target_position)
  end)
  return ok_can_shoot and can_shoot == true
end

local function create_launcher_discovery_context(surface, force)
  if not surface then return nil, "missing surface" end
  if not (force and force.valid) then return nil, "missing force" end

  local host_position = find_non_colliding_position_safe(surface, REAL_LAUNCHER_HOST_CHARACTER, { x = 0, y = 0 }, 128,
    0.5)
  if not host_position then return nil, "host position unavailable" end

  local target_position = find_non_colliding_position_safe(
    surface,
    "steel-chest",
    { x = host_position.x + REAL_LAUNCHER_DISCOVERY_TARGET_OFFSET, y = host_position.y },
    16,
    0.5
  )
  if not target_position then return nil, "target position unavailable" end

  local ok_target, target = pcall(function()
    return surface.create_entity {
      name = "steel-chest",
      position = target_position,
      force = game.forces.enemy or game.forces.neutral,
      create_build_effect_smoke = false,
    }
  end)
  if not ok_target or not target then
    return nil, "discovery target create failed"
  end

  local ok_launcher, launcher = pcall(function()
    return surface.create_entity {
      name = REAL_LAUNCHER_HOST_CHARACTER,
      position = host_position,
      force = force,
      create_build_effect_smoke = false,
    }
  end)
  if not ok_launcher or not launcher then
    destroy_real_launcher_entity(target)
    return nil, "discovery launcher create failed"
  end

  set_real_launcher_flags(launcher)
  pcall(function() target.destructible = false end)
  pcall(function() target.minable = false end)

  local guns = launcher.get_inventory(defines.inventory.character_guns)
  local ammo = launcher.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo) then
    destroy_real_launcher_entity(launcher)
    destroy_real_launcher_entity(target)
    return nil, "discovery inventories unavailable"
  end

  return {
    launcher = launcher,
    target = target,
    guns = guns,
    ammo = ammo,
  }
end

local function measure_real_launcher_range(context, family)
  if family ~= FAMILY_LAUNCHER_STREAM then return nil, nil end
  if not (context and context.launcher and context.launcher.valid) then return nil, nil end

  local source_position = copy_position(context.launcher.position)
  if not source_position then return nil, nil end

  local min_distance = nil
  local max_distance = nil

  for probe_distance = 1, REAL_LAUNCHER_RANGE_PROBE_MAX_DISTANCE do
    local probe_position = {
      x = source_position.x + probe_distance,
      y = source_position.y,
    }
    if try_real_launcher_can_shoot(context.launcher, family, nil, probe_position) then
      min_distance = min_distance or probe_distance
      max_distance = probe_distance
    end
  end

  return min_distance, max_distance
end

local function discover_launcher_for_ammo_item(surface, force, ammo_item_name, ammo_category, family)
  local context, reason = create_launcher_discovery_context(surface, force)
  if not context then
    Debug.log(
      "[DETONATION][LAUNCHER][DISCOVER][ERROR] ammo=" .. tostring(ammo_item_name)
      .. " category=" .. tostring(ammo_category)
      .. " reason=" .. tostring(reason)
    )
    return nil
  end

  local best = nil

  for item_name, prototype in pairs(prototypes.item) do
    clear_inventory_safe(context.guns)
    clear_inventory_safe(context.ammo)

    local ok_can_insert, can_insert = pcall(function()
      return context.guns.can_insert { name = item_name, count = 1 }
    end)
    if ok_can_insert and can_insert then
      local inserted_gun = context.guns.insert { name = item_name, count = 1 }
      local inserted_ammo = context.ammo.insert { name = ammo_item_name, count = 1 }
      if inserted_gun > 0 and inserted_ammo > 0 then
        local ok_selected = pcall(function() context.launcher.selected_gun_index = 1 end)
        local ok_can_shoot, can_shoot = pcall(function()
          return context.launcher.can_shoot(context.target, context.target.position)
        end)
        if ok_selected and ok_can_shoot and can_shoot then
          local min_distance, max_distance = measure_real_launcher_range(context, family)
          best = choose_launcher_catalog_entry(best, item_name, prototype, min_distance, max_distance)
        end
      end
    end
  end

  destroy_launcher_discovery_context(context)

  if best then
    Debug.log(
      "[DETONATION][LAUNCHER][DISCOVER][OK] ammo=" .. tostring(ammo_item_name)
      .. " category=" .. tostring(ammo_category)
      .. " launcher=" .. tostring(best.name)
      .. (best.max_distance and (" range=" .. tostring(best.min_distance or "?") .. "-" .. tostring(best.max_distance)) or "")
    )
  else
    Debug.log(
      "[DETONATION][LAUNCHER][DISCOVER][MISS] ammo=" .. tostring(ammo_item_name)
      .. " category=" .. tostring(ammo_category)
    )
  end

  return best
end

local function build_launcher_catalog(required_ammo_items)
  local catalog = {}
  local surface = find_launcher_discovery_surface()
  local force = resolve_default_force()

  for ammo_category, launcher_request in pairs(required_ammo_items or {}) do
    local ammo_item_name = type(launcher_request) == "table" and launcher_request.item_name or launcher_request
    local family = type(launcher_request) == "table" and launcher_request.family or nil
    local launcher = discover_launcher_for_ammo_item(surface, force, ammo_item_name, ammo_category, family)
    if launcher then
      catalog[ammo_category] = launcher
    else
      Debug.log(
        "[DETONATION][LAUNCHER][DISCOVER][UNRESOLVED] ammo=" .. tostring(ammo_item_name)
        .. " category=" .. tostring(ammo_category)
      )
    end
  end

  return catalog
end

local function apply_launcher_catalog_entry(spec, launcher)
  if not (spec and launcher) then return end
  if launcher.name then
    spec.launcher_prototype = launcher.name
  end
  if type(launcher.min_distance) == "number" then
    spec.launcher_min_distance = launcher.min_distance
  end
  if type(launcher.max_distance) == "number" then
    spec.launcher_max_distance = launcher.max_distance
  end
end

local function resolve_launcher_prototype_for_node(surface, force, node)
  if node.target_executor ~= EXECUTOR_REAL_LAUNCHER then return nil end
  if not node.ammo_category or not node.item_name then return nil end
  if not (surface and force) then return node.launcher_prototype end

  local launcher = LAUNCHER_CATALOG and LAUNCHER_CATALOG[node.ammo_category] or nil
  if not launcher then
    launcher = discover_launcher_for_ammo_item(surface, force, node.item_name, node.ammo_category, node.family)
    if launcher then
      LAUNCHER_CATALOG = LAUNCHER_CATALOG or {}
      LAUNCHER_CATALOG[node.ammo_category] = launcher
    end
  end

  if launcher then
    apply_launcher_catalog_entry(node, launcher)
    apply_launcher_catalog_entry(ITEM_SPECS and ITEM_SPECS[node.item_name] or nil, launcher)
  end

  return node.launcher_prototype
end

local function classify_item_family(prototype, projectile_name, delivery_kind, features)
  if features.has_line then return FAMILY_LAUNCHER_LINE end
  if features.has_chain or (features.has_beam and features.has_nested_result) then
    return FAMILY_LAUNCHER_COMPOSITE_BEAM
  end
  if delivery_kind == "stream" or features.has_stream then return FAMILY_LAUNCHER_STREAM end
  if safe_table_index(prototype, "capsule_action") then return FAMILY_CAPSULE_PROJECTILE end
  if projectile_name then return FAMILY_DIRECT_PROJECTILE end
  return FAMILY_UNKNOWN
end

local function determine_target_executor(family)
  if family == FAMILY_LAUNCHER_STREAM
      or family == FAMILY_LAUNCHER_LINE
      or family == FAMILY_LAUNCHER_COMPOSITE_BEAM
  then
    return EXECUTOR_REAL_LAUNCHER
  end

  return EXECUTOR_DIRECT_SPAWN
end

local function determine_current_executor(projectile_name)
  if projectile_name then return EXECUTOR_DIRECT_SPAWN end
  return EXECUTOR_SKIPPED
end

local function compile_action_delivery_spec(action_root, family, delivery_kind)
  local damage = action_root and find_damage_in_action(action_root, 0) or DEFAULT_PROJECTILE_DAMAGE
  if type(damage) ~= "number" or damage <= 0 then
    damage = DEFAULT_PROJECTILE_DAMAGE
  end

  local resolved_delivery_kind = delivery_kind
  if not resolved_delivery_kind and family == FAMILY_LAUNCHER_LINE then
    resolved_delivery_kind = "line"
  end

  local radius_scale = 1.0
  if family ~= FAMILY_LAUNCHER_LINE then
    radius_scale = 0.6 + (math_sqrt(damage) * 0.09)
  end

  return {
    damage = damage,
    radius_scale = radius_scale,
    delivery_kind = resolved_delivery_kind or "projectile",
  }
end

local function resolve_delivery_from_chain(chain_name, depth, seen, path)
  if type(chain_name) ~= "string" then return nil, nil, nil end

  local ok_triggers, triggers = pcall(function() return prototypes.active_trigger end)
  if not ok_triggers or not triggers then return nil, nil, nil end

  local ok_chain, chain_trigger = pcall(function() return triggers[chain_name] end)
  if not ok_chain or not chain_trigger then return nil, nil, nil end

  local chain_action = safe_table_index(chain_trigger, "action")
  if not chain_action then return nil, nil, nil end

  local entity_name, delivery_kind, matched_path = find_delivery_entity_in_table(chain_action, depth + 1, seen,
    path .. ".chain(" .. chain_name .. ").action")
  if entity_name then return entity_name, delivery_kind, matched_path end

  return nil, nil, nil
end

find_delivery_entity_in_table = function(node, depth, seen, path)
  if depth > 12 or type(node) ~= "table" then return nil, nil, nil end
  path = path or "$"

  seen = seen or {}
  if seen[node] then return nil, nil, nil end
  seen[node] = true

  local projectile_name = safe_table_index(node, "projectile")
  if type(projectile_name) == "string" then return projectile_name, "projectile", path .. ".projectile" end

  local stream_name = safe_table_index(node, "stream")
  if type(stream_name) == "string" then return stream_name, "stream", path .. ".stream" end

  local beam_name = safe_table_index(node, "beam")
  if type(beam_name) == "string" then return beam_name, "beam", path .. ".beam" end

  local chain_name = safe_table_index(node, "chain")
  local chained_entity, chained_kind, chained_path = resolve_delivery_from_chain(chain_name, depth, seen, path)
  if chained_entity then return chained_entity, chained_kind, chained_path end

  for i = 1, 64 do
    local child = safe_table_index(node, i)
    if child == nil then break end

    local entity_name, delivery_kind, matched_path = find_delivery_entity_in_table(child, depth + 1, seen,
      path .. "[" .. i .. "]")
    if entity_name then return entity_name, delivery_kind, matched_path end
  end

  for i = 1, #DELIVERY_SCAN_KEYS do
    local key = DELIVERY_SCAN_KEYS[i]
    local child = safe_table_index(node, key)
    if child ~= nil then
      local entity_name, delivery_kind, matched_path = find_delivery_entity_in_table(child, depth + 1, seen,
        path .. "." .. key)
      if entity_name then return entity_name, delivery_kind, matched_path end
    end
  end

  for key, value in pairs(node) do
    if type(key) ~= "number" then
      local entity_name, delivery_kind, matched_path = find_delivery_entity_in_table(value, depth + 1, seen,
        path .. "." .. tostring(key))
      if entity_name then return entity_name, delivery_kind, matched_path end
    end
  end

  return nil, nil, nil
end

find_damage_in_action = function(node, depth, seen)
  if depth > 15 or type(node) ~= "table" then return 0 end

  seen = seen or {}
  if seen[node] then return 0 end
  seen[node] = true

  local total_damage = 0

  if type(node.damage) == "number" then
    total_damage = total_damage + node.damage
  elseif type(node.damage) == "table" then
    if node.damage.amount then
      total_damage = total_damage + node.damage.amount
    end

    for i = 1, #node.damage do
      local damage_entry = node.damage[i]
      if type(damage_entry) == "table" and damage_entry.amount then
        total_damage = total_damage + damage_entry.amount
      end
    end
  end

  for _, value in pairs(node) do
    total_damage = total_damage + find_damage_in_action(value, depth + 1, seen)
  end

  return total_damage
end

local function compile_projectile_spec(projectile_name, delivery_kind)
  local cached = PROJECTILE_SPECS[projectile_name]
  if cached then return cached end

  local damage = DEFAULT_PROJECTILE_DAMAGE
  local resolved_delivery_kind = delivery_kind or "projectile"

  local ok, prototype = pcall(function() return prototypes.entity[projectile_name] end)
  if ok and prototype then
    if prototype.type == "stream" then
      resolved_delivery_kind = "stream"
    elseif prototype.type == "beam" then
      resolved_delivery_kind = "beam"
    elseif prototype.type == "projectile" then
      resolved_delivery_kind = "projectile"
    end

    local total_damage = 0

    for _, field_name in ipairs({ "action", "final_action", "attack_result", "created_effect", "trigger_effect" }) do
      local has_field, field_value = pcall(function() return prototype[field_name] end)
      if has_field and type(field_value) == "table" then
        local found_damage = find_damage_in_action(field_value, 0)
        if found_damage > 0 then total_damage = total_damage + found_damage end
      end
    end

    if total_damage > 0 then damage = total_damage end
  else
    Debug.log("[DETONATION] Missing projectile prototype: " .. projectile_name)
  end

  local spec = {
    damage        = damage,
    radius_scale  = 0.6 + (math_sqrt(damage) * 0.09),
    delivery_kind = resolved_delivery_kind,
  }

  PROJECTILE_SPECS[projectile_name] = spec
  return spec
end

local function extract_projectile_from_item(item_name, prototype)
  local manual = MANUAL_ITEM_SPECS[item_name]
  if manual then return manual.projectile, manual, manual.delivery_kind, "manual" end

  local action_root, action_source = extract_item_action_root(prototype)
  if action_root then
    local projectile, delivery_kind, matched_path = find_delivery_entity_in_table(action_root, 0, nil, action_source)
    if projectile then return projectile, nil, delivery_kind, tostring(matched_path) end
  end

  return nil, nil, nil, "none"
end

local function resolve_item_magazine_size(prototype, manual)
  if manual and manual.magazine_size and manual.magazine_size > 0 then
    return manual.magazine_size
  end

  if prototype.magazine_size and prototype.magazine_size > 0 then
    return prototype.magazine_size
  end

  return 1
end

local function compute_item_charges(prototype, manual, family)
  if family == FAMILY_LAUNCHER_STREAM then
    return 1
  end

  if manual and manual.magazine_size and manual.magazine_size > 0 then
    return manual.magazine_size
  end

  if prototype.magazine_size and prototype.magazine_size > 0 then
    return math_max(1, math_floor(math_sqrt(prototype.magazine_size)))
  end

  return 1
end

local function scan_item_runtime_metadata(item_name, prototype)
  local action_root = extract_item_action_root(prototype)
  local projectile_name, manual, delivery_kind = extract_projectile_from_item(item_name, prototype)
  local features = action_root and scan_action_features(action_root, 0) or new_action_features()
  if not delivery_kind and features.has_line then
    delivery_kind = "line"
  end
  local family = classify_item_family(prototype, projectile_name, delivery_kind, features)
  local current_executor = determine_current_executor(projectile_name)
  local target_executor = determine_target_executor(family)
  local ammo_category = projectile_name and extract_ammo_category(prototype, manual) or
      normalize_id_name(prototype.ammo_category)

  return {
    item_name = item_name,
    prototype = prototype,
    action_root = action_root,
    projectile_name = projectile_name,
    manual = manual,
    ammo_category = ammo_category,
    family = family,
    current_executor = current_executor,
    target_executor = target_executor,
    delivery_kind = delivery_kind,
  }
end

local function build_payload_specs()
  ITEM_SPECS = {}
  PROJECTILE_SPECS = {}

  local scanned_specs = {}
  local required_launcher_items = {}

  for item_name, prototype in pairs(prototypes.item) do
    local scanned = scan_item_runtime_metadata(item_name, prototype)
    scanned_specs[#scanned_specs + 1] = scanned

    if scanned.target_executor == EXECUTOR_REAL_LAUNCHER
        and scanned.ammo_category
        and not required_launcher_items[scanned.ammo_category]
    then
      required_launcher_items[scanned.ammo_category] = {
        item_name = scanned.item_name,
        family = scanned.family,
      }
    end
  end

  LAUNCHER_CATALOG = build_launcher_catalog(required_launcher_items)

  for i = 1, #scanned_specs do
    local scanned = scanned_specs[i]
    local item_name = scanned.item_name
    local prototype = scanned.prototype

    if scanned.projectile_name or scanned.target_executor == EXECUTOR_REAL_LAUNCHER then
      local delivery_spec = scanned.projectile_name
          and compile_projectile_spec(scanned.projectile_name, scanned.delivery_kind)
          or compile_action_delivery_spec(scanned.action_root, scanned.family, scanned.delivery_kind)
      local launcher = scanned.ammo_category and LAUNCHER_CATALOG[scanned.ammo_category]
      local magazine_size = resolve_item_magazine_size(prototype, scanned.manual)
      local charges = compute_item_charges(prototype, scanned.manual, scanned.family)
      ITEM_SPECS[item_name] = {
        item_name                 = item_name,
        projectile                = scanned.projectile_name,
        payload_name              = scanned.projectile_name or item_name,
        charges                   = charges,
        real_launcher_charge_size = scanned.family == FAMILY_LAUNCHER_STREAM and magazine_size or 1,
        ammo_category             = scanned.ammo_category,
        damage                    = delivery_spec.damage,
        radius_scale              = delivery_spec.radius_scale,
        delivery_kind             = delivery_spec.delivery_kind,
        family                    = scanned.family,
        current_executor          = scanned.current_executor,
        target_executor           = scanned.target_executor,
        launcher_prototype        = launcher and launcher.name or nil,
        launcher_min_distance     = launcher and launcher.min_distance or nil,
        launcher_max_distance     = launcher and launcher.max_distance or nil,
      }

      if not scanned.ammo_category then
        Debug.log("[DETONATION] Missing ammo category for item " .. item_name .. " -> " .. scanned.projectile_name)
      end

      if scanned.target_executor == EXECUTOR_REAL_LAUNCHER and not ITEM_SPECS[item_name].launcher_prototype then
        Debug.log("[DETONATION] Missing launcher prototype for runtime launcher family item " .. item_name)
      end
    end
  end

  Debug.log("[DETONATION] Compiled " .. table_size(ITEM_SPECS) .. " explosive item specs")
  Debug.log("[DETONATION] Compiled " .. table_size(PROJECTILE_SPECS) .. " projectile specs")
end

local function detect_entity_caps(entity)
  local entity_type = entity.type
  local cached = ENTITY_CAPS[entity_type]
  if cached then return cached end

  local caps = {
    inventories     = entity_type == "character",
    transport_lines = false,
    held_stack      = false,
  }

  local ok_inv, max_inventory_index = pcall(entity.get_max_inventory_index, entity)
  if ok_inv and max_inventory_index and max_inventory_index > 0 then
    caps.inventories = true
  end

  local ok_lines, max_line_index = pcall(entity.get_max_transport_line_index, entity)
  if ok_lines and max_line_index and max_line_index > 0 then
    caps.transport_lines = true
  end

  local ok_held, held_stack = pcall(function() return entity.held_stack end)
  caps.held_stack = ok_held and held_stack ~= nil

  ENTITY_CAPS[entity_type] = caps
  return caps
end

local function new_payload()
  return {
    total_count   = 0,
    by_projectile = {},
  }
end

local function add_item_to_payload(payload, item_name, item_count, item_quality)
  local item_spec = ITEM_SPECS[item_name]
  if not item_spec then return nil, nil end

  local payload_name  = item_spec.payload_name
  local quality_name  = normalize_quality_name(item_quality)
  local virtual_count = item_count * item_spec.charges
  local node_key      = payload_key(payload_name, quality_name)

  local node          = payload.by_projectile[node_key]
  if not node then
    node = {
      payload_key               = node_key,
      item_name                 = item_spec.item_name,
      item_quality              = quality_name,
      projectile_name           = payload_name,
      spawn_entity_name         = item_spec.projectile,
      ammo_category             = item_spec.ammo_category,
      exact_count               = 0,
      damage                    = item_spec.damage,
      radius_scale              = item_spec.radius_scale,
      delivery_kind             = item_spec.delivery_kind,
      family                    = item_spec.family,
      current_executor          = item_spec.current_executor,
      target_executor           = item_spec.target_executor,
      source_item_count         = 0,
      real_launcher_charge_size = item_spec.real_launcher_charge_size,
      launcher_prototype        = item_spec.launcher_prototype,
      launcher_min_distance     = item_spec.launcher_min_distance,
      launcher_max_distance     = item_spec.launcher_max_distance,
    }
    payload.by_projectile[node_key] = node
  end

  node.exact_count       = node.exact_count + virtual_count
  node.source_item_count = node.source_item_count + item_count
  payload.total_count    = payload.total_count + virtual_count

  return node, virtual_count
end

local function collect_from_inventory(payload, inventory, consume)
  if not (inventory and inventory.valid) then return end
  local ok_empty, is_empty = pcall(function() return inventory.is_empty() end)
  if not ok_empty or is_empty then return end

  local removals = consume and {} or nil
  local contents = inventory.get_contents()

  for_each_item_count(contents, function(item_name, item_count, item_quality)
    local node = add_item_to_payload(payload, item_name, item_count, item_quality)
    if node and removals then
      removals[#removals + 1] = item_stack_definition(item_name, item_count, item_quality)
    end
  end)

  if removals and #removals > 0 then
    for i = 1, #removals do
      pcall(function() inventory.remove(removals[i]) end)
    end
  end
end

local function collect_from_transport_lines(entity, payload, consume)
  local ok, max_line_index = pcall(entity.get_max_transport_line_index, entity)
  if not ok or not max_line_index or max_line_index <= 0 then return end

  for line_index = 1, max_line_index do
    local line = entity.get_transport_line(line_index)
    if line and line.valid then
      local removals = consume and {} or nil
      local contents = line.get_contents()

      for_each_item_count(contents, function(item_name, item_count, item_quality)
        local node = add_item_to_payload(payload, item_name, item_count, item_quality)
        if node and removals then
          removals[#removals + 1] = item_stack_definition(item_name, item_count, item_quality)
        end
      end)

      if removals and #removals > 0 then
        for i = 1, #removals do
          pcall(function() line.remove_item(removals[i]) end)
        end
      end
    end
  end
end

local function collect_from_stack(payload, get_stack, consume)
  local ok, stack = pcall(get_stack)
  if not ok or not stack or not stack.valid_for_read then return end

  local quality = nil
  local ok_quality, stack_quality = pcall(function() return stack.quality end)
  if ok_quality then quality = stack_quality end

  local node = add_item_to_payload(payload, stack.name, stack.count, quality)
  if node then
    if consume then
      pcall(function() stack.clear() end)
    end
  end
end

local function collect_from_entity(payload, entity, options)
  options = options or {}
  local caps = detect_entity_caps(entity)
  local debug = debug_enabled()
  local before_total = debug and payload.total_count or 0

  if debug then
    Debug.log(
      "[DETONATION][COLLECT][ENTITY] begin " .. describe_entity(entity)
      .. " caps={inv=" .. tostring(caps.inventories)
      .. ",lines=" .. tostring(caps.transport_lines)
      .. ",held=" .. tostring(caps.held_stack) .. "}"
      .. " consume={inv=" .. tostring(options.consume_inventories)
      .. ",lines=" .. tostring(options.consume_transport_lines)
      .. ",held=" .. tostring(options.consume_held_stack) .. "}"
    )
  end

  if caps.inventories then
    local ok, max_inventory_index = pcall(entity.get_max_inventory_index, entity)
    if ok and max_inventory_index and max_inventory_index > 0 then
      for inventory_index = 1, max_inventory_index do
        local inventory = entity.get_inventory(inventory_index)
        collect_from_inventory(payload, inventory, options.consume_inventories)
      end
    end
  end

  if caps.transport_lines then
    collect_from_transport_lines(entity, payload, options.consume_transport_lines)
  end

  if caps.held_stack then
    collect_from_stack(payload, function() return entity.held_stack end, options.consume_held_stack)
  end

  if debug then
    Debug.log(
      "[DETONATION][COLLECT][ENTITY] end " .. describe_entity(entity)
      .. " added_virtual=" .. tostring(payload.total_count - before_total)
      .. " payload_total=" .. tostring(payload.total_count)
    )
  end
end

local function sorted_payload_nodes(payload)
  local nodes = {}
  for _, node in pairs(payload.by_projectile) do
    nodes[#nodes + 1] = node
  end

  table_sort(nodes, function(a, b)
    if a.projectile_name == b.projectile_name then
      return normalize_quality_name(a.item_quality) < normalize_quality_name(b.item_quality)
    end
    return a.projectile_name < b.projectile_name
  end)

  return nodes
end

local function log_payload_details(tag, payload)
  if not debug_enabled() then return end

  local nodes = sorted_payload_nodes(payload)
  Debug.log("[DETONATION][" .. tag .. "] payload_total=" .. tostring(payload.total_count) .. " nodes=" .. tostring(#nodes))

  for i = 1, #nodes do
    local node = nodes[i]
    Debug.log(
      "[DETONATION][" .. tag .. "] node=" .. node.projectile_name
      .. " kind=" .. tostring(node.delivery_kind)
      .. " family=" .. tostring(node.family)
      .. " current=" .. tostring(node.current_executor)
      .. " target=" .. tostring(node.target_executor)
      .. " launcher=" .. tostring(node.launcher_prototype)
      .. " ammo=" .. tostring(node.ammo_category)
      .. " quality=" .. tostring(node.item_quality)
      .. " exact_count=" .. tostring(node.exact_count)
      .. " damage=" .. tostring(node.damage)
      .. " radius_scale=" .. tostring(node.radius_scale)
    )
  end
end

local function uses_stream_job_budget(node)
  return node.family == FAMILY_LAUNCHER_STREAM
      and node.target_executor == EXECUTOR_REAL_LAUNCHER
      and (node.real_launcher_charge_size or 1) > 1
end

local function resolve_budget_unit_count(node)
  if uses_stream_job_budget(node) then
    if node.source_item_count and node.source_item_count > 0 then
      return node.source_item_count
    end

    local charge_size = math_max(1, node.real_launcher_charge_size or 1)
    return math_max(1, math_floor((node.exact_count + charge_size - 1) / charge_size))
  end

  return node.exact_count
end

local function allocate_spawn_budget(payload, limit)
  local nodes = sorted_payload_nodes(payload)
  local budget = {}

  if payload.total_count <= limit then
    for i = 1, #nodes do
      local node = nodes[i]
      budget[node.payload_key] = resolve_budget_unit_count(node)
    end
    return nodes, budget
  end

  local remaining      = limit
  local reserve_counts = {}

  if remaining >= #nodes then
    for i = 1, #nodes do
      local node                       = nodes[i]
      local budget_units               = resolve_budget_unit_count(node)
      budget[node.payload_key]         = 1
      reserve_counts[node.payload_key] = math_max(0, budget_units - 1)
      remaining                        = remaining - 1
    end
  else
    for i = 1, #nodes do
      local node                       = nodes[i]
      budget[node.payload_key]         = 0
      reserve_counts[node.payload_key] = resolve_budget_unit_count(node)
    end
  end

  local total_reserve_weight = 0
  for i = 1, #nodes do
    local node = nodes[i]
    local reserve = reserve_counts[node.payload_key]
    node.reserve_weight = reserve * node.damage
    total_reserve_weight = total_reserve_weight + node.reserve_weight
  end

  if remaining <= 0 or total_reserve_weight <= 0 then
    return nodes, budget
  end

  local used      = 0
  local fractions = {}

  for i = 1, #nodes do
    local node    = nodes[i]
    local reserve = reserve_counts[node.payload_key]
    if reserve > 0 and node.reserve_weight > 0 then
      local ideal = (node.reserve_weight / total_reserve_weight) * remaining
      local extra = math_min(reserve, math_floor(ideal))
      budget[node.payload_key] = budget[node.payload_key] + extra
      used = used + extra
      fractions[#fractions + 1] = {
        payload_key     = node.payload_key,
        projectile_name = node.projectile_name,
        item_quality    = node.item_quality,
        fraction        = ideal - extra,
      }
    end
  end

  local leftovers = remaining - used
  if leftovers > 0 then
    table_sort(fractions, function(a, b)
      if a.fraction == b.fraction then
        if a.projectile_name == b.projectile_name then
          return normalize_quality_name(a.item_quality) < normalize_quality_name(b.item_quality)
        end
        return a.projectile_name < b.projectile_name
      end
      return a.fraction > b.fraction
    end)

    local fraction_count = #fractions
    local cursor = 1
    local stalled = 0

    while leftovers > 0 and fraction_count > 0 do
      local entry = fractions[cursor]
      local node  = payload.by_projectile[entry.payload_key]
      if budget[entry.payload_key] < resolve_budget_unit_count(node) then
        budget[entry.payload_key] = budget[entry.payload_key] + 1
        leftovers = leftovers - 1
        stalled = 0
      else
        stalled = stalled + 1
        if stalled >= fraction_count then break end
      end

      cursor = cursor + 1
      if cursor > fraction_count then cursor = 1 end
    end
  end

  for i = 1, #nodes do nodes[i].reserve_weight = nil end

  return nodes, budget
end

local function compare_emit_schedule_entries(a, b)
  local left = a.key_numerator * b.key_denominator
  local right = b.key_numerator * a.key_denominator
  if left ~= right then return left < right end
  if a.tie_breaker ~= b.tie_breaker then return a.tie_breaker < b.tie_breaker end
  if a.node_index ~= b.node_index then return a.node_index < b.node_index end
  return a.unit_index < b.unit_index
end

local function build_emit_schedule(nodes, budget, rng)
  local schedule = {}

  for node_index = 1, #nodes do
    local node = nodes[node_index]
    local count = math_floor(budget[node.payload_key] or 0)
    if count > 0 then
      for unit_index = 1, count do
        schedule[#schedule + 1] = {
          node = node,
          node_index = node_index,
          unit_index = unit_index,
          key_numerator = (unit_index - 1) * EMIT_SCHEDULE_JITTER_SCALE + rng(EMIT_SCHEDULE_JITTER_SCALE) - 1,
          key_denominator = count,
          tie_breaker = rng(EMIT_SCHEDULE_JITTER_SCALE),
        }
      end
    end
  end

  table_sort(schedule, compare_emit_schedule_entries)
  return schedule
end

local function can_use_as_projectile_target(candidate, excluded_entity)
  if not (candidate and candidate.valid) then return false end
  if excluded_entity and candidate == excluded_entity then return false end

  local ok, health = pcall(function() return candidate.health end)
  return ok and health ~= nil
end

local function resolve_final_target(surface, target_pos, rng, excluded_entity)
  local nearby = surface.find_entities_filtered { position = target_pos, radius = 3 }

  local valid_targets = {}
  for i = 1, #nearby do
    local candidate = nearby[i]
    if can_use_as_projectile_target(candidate, excluded_entity) then
      valid_targets[#valid_targets + 1] = candidate
    end
  end

  if #valid_targets > 0 then return valid_targets[rng(#valid_targets)] end

  return target_pos
end

local function resolve_stream_aim_limits(node)
  local launcher_min_distance = type(node and node.launcher_min_distance) == "number" and node.launcher_min_distance or 0
  local launcher_max_distance = type(node and node.launcher_max_distance) == "number" and node.launcher_max_distance or
      nil
  local min_aim_distance = math_max(REAL_LAUNCHER_STREAM_MIN_AIM_DISTANCE, launcher_min_distance)
  if launcher_max_distance and launcher_max_distance < min_aim_distance then
    launcher_max_distance = min_aim_distance
  end
  return min_aim_distance, launcher_max_distance
end

local function resolve_stream_direction(source_position, target_position, rng)
  local dx = target_position.x - source_position.x
  local dy = target_position.y - source_position.y
  local distance = math_sqrt(dx * dx + dy * dy)
  if distance <= 0.001 then
    local angle = rng() * TWO_PI
    return math_cos(angle), math_sin(angle), 0
  end
  return dx / distance, dy / distance, distance
end

local function sample_uniform_annulus_distance(min_aim_distance, max_aim_distance, rng)
  if type(max_aim_distance) ~= "number" or max_aim_distance <= min_aim_distance then
    return min_aim_distance
  end

  local min_sq = min_aim_distance * min_aim_distance
  local max_sq = max_aim_distance * max_aim_distance
  return math_sqrt(min_sq + rng() * (max_sq - min_sq))
end

local function build_stream_target_position(source_position, direction_x, direction_y, aim_distance)
  return {
    x = source_position.x + direction_x * aim_distance,
    y = source_position.y + direction_y * aim_distance,
  }
end

local function resolve_stream_target(node, center, sampled_target, sampled_distance, rng)
  local source_position = copy_position(center)
  local target_position = copy_position(sampled_target)
  if not source_position or not target_position then
    return sampled_target, sampled_distance
  end

  local min_aim_distance, max_aim_distance = resolve_stream_aim_limits(node)
  local direction_x, direction_y = resolve_stream_direction(source_position, target_position, rng)
  local aim_distance = sample_uniform_annulus_distance(min_aim_distance, max_aim_distance, rng)

  return build_stream_target_position(source_position, direction_x, direction_y, aim_distance), aim_distance
end

local function resolve_emit_target(node, surface, center, sampled_target, sampled_distance, rng, excluded_entity)
  if node.family == FAMILY_LAUNCHER_STREAM then
    return resolve_stream_target(node, center, sampled_target, sampled_distance, rng)
  end

  return resolve_final_target(surface, sampled_target, rng, excluded_entity), sampled_distance
end

local function spawn_projectile(surface, center, target, distance, node, speed, force, cause)
  local delivery_kind = node.delivery_kind or "projectile"
  local spawn_entity_name = node.spawn_entity_name or node.projectile_name
  if not spawn_entity_name then
    Debug.log(
      "[DETONATION][SPAWN][SKIP] projectile=" .. tostring(node.projectile_name)
      .. " kind=" .. tostring(delivery_kind)
      .. " reason=no spawn entity name"
    )
    return
  end
  local params = {
    name     = spawn_entity_name,
    position = center,
    target   = target,
    force    = force,
  }
  local valid_cause = sanitize_entity_reference(cause)
  if valid_cause then
    params.cause = valid_cause
  end

  if delivery_kind == "stream" then
    params.source    = center
    params.max_range = distance + 5
  elseif delivery_kind == "beam" then
    -- Beam emitters need a source and typically operate in short bursts.
    params.source     = center
    params.max_length = math_max(1, math_floor(distance + 5))
    params.duration   = 30
  else
    params.speed = speed
    params.base_damage_modifiers = get_projectile_quality_modifiers(node.item_quality)
    params.bonus_damage_modifiers = get_projectile_damage_modifiers(force, node.ammo_category)
  end

  local ok, created_or_error = pcall(function() return surface.create_entity(params) end)
  if not ok then
    Debug.log(
      "[DETONATION][SPAWN][ERROR] projectile=" .. node.projectile_name
      .. " kind=" .. tostring(delivery_kind)
      .. " target=" .. describe_target(target)
      .. " error=" .. tostring(created_or_error)
    )
    return
  end

  if not created_or_error then
    Debug.log(
      "[DETONATION][SPAWN][NIL] projectile=" .. node.projectile_name
      .. " kind=" .. tostring(delivery_kind)
      .. " target=" .. describe_target(target)
      .. " create_entity returned nil"
    )
    return
  end
end

local function can_queue_real_launcher(node, target)
  if node.target_executor ~= EXECUTOR_REAL_LAUNCHER then return false end
  if not is_real_launcher_family_enabled(node.family) then return false end
  if not node.launcher_prototype or not node.item_name then return false end

  if is_valid_entity_reference(target) then return true end
  if real_launcher_family_accepts_position_target(node.family) and is_map_position(target) then return true end
  return false
end

local function explain_real_launcher_skip(node, target)
  if node.target_executor ~= EXECUTOR_REAL_LAUNCHER then
    return "not a real-launcher family"
  end
  if not is_real_launcher_family_enabled(node.family) then
    return "family gate disabled"
  end
  if not node.launcher_prototype then
    return "launcher prototype missing"
  end
  if not node.item_name then
    return "source item missing"
  end

  if is_valid_entity_reference(target) then
    return "enqueue rejected"
  end

  if real_launcher_family_accepts_position_target(node.family) and is_map_position(target) then
    return "enqueue rejected"
  end

  return "target is neither a valid entity nor a supported position"
end

local function resolve_real_launcher_charge_count(node)
  if uses_stream_job_budget(node) then
    return math_max(1, node.real_launcher_charge_size or 1)
  end

  return 1
end

local function resolve_real_launcher_fire_ticks(node, charge_count)
  if node.family == FAMILY_LAUNCHER_STREAM then
    return math_min(
      REAL_LAUNCHER_STREAM_MAX_FIRE_TICKS,
      math_max(REAL_LAUNCHER_STREAM_MIN_FIRE_TICKS, charge_count)
    )
  end

  return REAL_LAUNCHER_DEFAULT_FIRE_TICKS
end

local function compute_stream_retarget_seed(job, tick)
  local seed = deterministic_seed(job.source_position or job.target_position or { x = 0, y = 0 }, tick)
  if job.target_position then
    seed = seed + math_floor(job.target_position.x * 1000) * 19349663
    seed = seed + math_floor(job.target_position.y * 1000) * 83492791
  end
  return normalize_random_seed(seed)
end

local function sample_stream_retarget_position(job, tick)
  local source_position = copy_position(job.source_position)
  if not source_position then return nil end

  local min_aim_distance = job.stream_min_distance or REAL_LAUNCHER_STREAM_MIN_AIM_DISTANCE
  local max_aim_distance = job.stream_max_distance
  local distance_span = type(max_aim_distance) == "number" and math_max(0, max_aim_distance - min_aim_distance) or 0
  local max_distance_offset = math_min(REAL_LAUNCHER_STREAM_RETARGET_MAX_DISTANCE_OFFSET, distance_span * 0.5)
  local rng = game.create_random_generator(compute_stream_retarget_seed(job, tick))

  local angle_offset = (rng() * 2 - 1) * REAL_LAUNCHER_STREAM_RETARGET_MAX_ANGLE_OFFSET
  local distance_offset = (rng() * 2 - 1) * max_distance_offset
  local cos_offset = math_cos(angle_offset)
  local sin_offset = math_sin(angle_offset)
  local base_direction_x = job.stream_direction_x or 1
  local base_direction_y = job.stream_direction_y or 0
  local direction_x = base_direction_x * cos_offset - base_direction_y * sin_offset
  local direction_y = base_direction_x * sin_offset + base_direction_y * cos_offset
  local aim_distance = math_max(min_aim_distance, (job.stream_distance or min_aim_distance) + distance_offset)
  if max_aim_distance then
    aim_distance = math_min(aim_distance, max_aim_distance)
  end

  return build_stream_target_position(source_position, direction_x, direction_y, aim_distance), aim_distance, direction_x,
      direction_y
end

local function enqueue_real_launcher_job(surface, center, target, distance, node, speed, force, cause, charge_count)
  initialize_runtime_storage()

  local target_position = copy_position(target and target.position) or copy_position(target)
  if not target_position then return false end

  local queued_charge_count = math_max(1, charge_count or 1)
  local stream_min_distance, stream_max_distance = resolve_stream_aim_limits(node)
  local stream_direction_x, stream_direction_y, stream_distance = 1, 0, stream_min_distance
  if node.family == FAMILY_LAUNCHER_STREAM then
    stream_direction_x, stream_direction_y, stream_distance = resolve_stream_direction(center, target_position,
      game.create_random_generator(compute_stream_retarget_seed({
        source_position = center,
        target_position = target_position,
      }, game.tick)))
    stream_distance = math_max(stream_min_distance, stream_distance)
    if stream_max_distance then
      stream_distance = math_min(stream_distance, stream_max_distance)
    end
  end

  storage.launcher_jobs[#storage.launcher_jobs + 1] = {
    family = node.family,
    launcher_prototype = node.launcher_prototype,
    ammo_item_name = node.item_name,
    item_quality = normalize_quality_name(node.item_quality),
    surface_index = surface.index,
    source_position = copy_position(center),
    target = target,
    target_position = target_position,
    force = force,
    cause = cause,
    projectile_name = node.projectile_name,
    spawn_entity_name = node.spawn_entity_name,
    delivery_kind = node.delivery_kind,
    ammo_category = node.ammo_category,
    current_executor = node.current_executor,
    distance = distance,
    speed = speed,
    charge_count = queued_charge_count,
    ammo_count = 1,
    fire_ticks = resolve_real_launcher_fire_ticks(node, queued_charge_count),
    cleanup_delay = REAL_LAUNCHER_DEFAULT_CLEANUP_TICKS,
    spawn_tick = game.tick + REAL_LAUNCHER_SPAWN_DELAY,
    next_retarget_tick = nil,
    release_tick = nil,
    cleanup_tick = nil,
    state = "pending",
    launcher = nil,
    stream_min_distance = stream_min_distance,
    stream_max_distance = stream_max_distance,
    stream_direction_x = stream_direction_x,
    stream_direction_y = stream_direction_y,
    stream_distance = stream_distance,
  }

  ensure_tick_handler()
  return true
end

local function compute_real_launcher_host_seed_position(job)
  local source_position = copy_position(job.source_position)
  if not source_position then return nil, REAL_LAUNCHER_HOST_SEARCH_RADIUS end
  return source_position, REAL_LAUNCHER_HOST_SEARCH_RADIUS
end

destroy_real_launcher_entity = function(entity)
  if entity and entity.valid then
    pcall(function() entity.destroy() end)
  end
end

set_real_launcher_flags = function(entity)
  pcall(function() entity.destructible = false end)
  pcall(function() entity.operable = false end)
  pcall(function() entity.minable = false end)
end

local function execute_real_launcher_fallback(job, reason)
  local surface = game.get_surface(job.surface_index)
  if not surface then return end

  if debug_enabled() then
    Debug.log(
      "[DETONATION][LAUNCHER][FALLBACK] family=" .. tostring(job.family)
      .. " projectile=" .. tostring(job.projectile_name)
      .. " launcher=" .. tostring(job.launcher_prototype)
      .. " charges=" .. tostring(job.charge_count)
      .. " quality=" .. tostring(job.item_quality)
      .. " reason=" .. tostring(reason)
    )
  end

  if job.current_executor ~= EXECUTOR_DIRECT_SPAWN or not job.spawn_entity_name then
    if debug_enabled() then
      Debug.log(
        "[DETONATION][LAUNCHER][ABORT] family=" .. tostring(job.family)
        .. " projectile=" .. tostring(job.projectile_name)
        .. " reason=no direct-spawn fallback available"
      )
    end
    return
  end

  local target = is_valid_entity_reference(job.target) and job.target or job.target_position
  local fallback_node = {
    projectile_name = job.projectile_name,
    spawn_entity_name = job.spawn_entity_name,
    delivery_kind = job.delivery_kind,
    ammo_category = job.ammo_category,
    item_quality = job.item_quality,
  }
  for _ = 1, math_max(1, job.charge_count or 1) do
    spawn_projectile(surface, job.source_position, target, job.distance, fallback_node, job.speed, job.force, job.cause)
  end
end

local function can_real_launcher_shoot(launcher, job, target_entity)
  if job.family == FAMILY_LAUNCHER_LINE and not target_entity and is_map_position(job.target_position) then
    return true
  end

  return try_real_launcher_can_shoot(launcher, job.family, target_entity, job.target_position)
end

local function maybe_retarget_stream_launcher(job, tick)
  if job.family ~= FAMILY_LAUNCHER_STREAM then return end
  if not (job.launcher and job.launcher.valid) then return end
  if not job.next_retarget_tick or tick < job.next_retarget_tick then return end

  job.next_retarget_tick = tick + REAL_LAUNCHER_STREAM_RETARGET_INTERVAL_TICKS

  local target_position, aim_distance, direction_x, direction_y = sample_stream_retarget_position(job, tick)
  if not target_position then return end
  if not try_real_launcher_can_shoot(job.launcher, job.family, nil, target_position) then return end

  local ok_shooting_state = pcall(function()
    job.launcher.shooting_state = {
      state = defines.shooting.shooting_selected,
      position = target_position,
    }
  end)
  if not ok_shooting_state then return end

  job.target_position = target_position
  job.stream_distance = aim_distance
  job.stream_direction_x = direction_x
  job.stream_direction_y = direction_y
end

local function prepare_real_launcher_job(job)
  local surface = game.get_surface(job.surface_index)
  if not surface then return false, "missing surface" end
  if not job.target_position then return false, "missing target position" end

  local seed_position, search_radius = compute_real_launcher_host_seed_position(job)
  if not seed_position then return false, "host seed position unavailable" end
  local ok_pos, spawn_position = pcall(function()
    return surface.find_non_colliding_position(
      REAL_LAUNCHER_HOST_CHARACTER,
      seed_position,
      search_radius,
      REAL_LAUNCHER_HOST_SEARCH_PRECISION
    )
  end)
  if not ok_pos then return false, "find_non_colliding_position failed" end
  spawn_position = spawn_position or seed_position

  local ok_create, launcher = pcall(function()
    return surface.create_entity {
      name = REAL_LAUNCHER_HOST_CHARACTER,
      position = spawn_position,
      force = job.force,
      create_build_effect_smoke = false,
    }
  end)
  if not ok_create or not launcher then
    return false, "launcher host create failed"
  end

  job.launcher = launcher
  set_real_launcher_flags(launcher)

  local guns = launcher.get_inventory(defines.inventory.character_guns)
  local ammo = launcher.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo) then
    destroy_real_launcher_entity(launcher)
    job.launcher = nil
    return false, "launcher inventories unavailable"
  end

  local gun_inserted = guns.insert { name = job.launcher_prototype, count = 1 }
  local ammo_inserted = ammo.insert(item_stack_definition(job.ammo_item_name, job.ammo_count or 1, job.item_quality))
  if gun_inserted < 1 or ammo_inserted < 1 then
    destroy_real_launcher_entity(launcher)
    job.launcher = nil
    return false, "launcher inventory insert failed"
  end

  local ok_selected_gun = pcall(function() launcher.selected_gun_index = 1 end)
  local target_entity = is_valid_entity_reference(job.target) and job.target or nil
  if not ok_selected_gun or not can_real_launcher_shoot(launcher, job, target_entity) then
    destroy_real_launcher_entity(launcher)
    job.launcher = nil
    return false, "launcher cannot shoot target"
  end

  if target_entity then
    pcall(function() launcher.selected = target_entity end)
  end
  local ok_shooting_state = pcall(function()
    launcher.shooting_state = {
      state = defines.shooting.shooting_selected,
      position = job.target_position,
    }
  end)
  if not ok_shooting_state then
    destroy_real_launcher_entity(launcher)
    job.launcher = nil
    return false, "shooting_state write failed"
  end

  if debug_enabled() then
    Debug.log(
      "[DETONATION][LAUNCHER][START] family=" .. tostring(job.family)
      .. " projectile=" .. tostring(job.projectile_name)
      .. " launcher=" .. tostring(job.launcher_prototype)
      .. " ammo=" .. tostring(job.ammo_category)
      .. " quality=" .. tostring(job.item_quality)
      .. " charges=" .. tostring(job.charge_count)
      .. " fire_ticks=" .. tostring(job.fire_ticks)
      .. " force=" .. tostring(job.force and job.force.name)
      .. " host=" .. describe_entity(launcher)
      .. " source=" .. describe_position(job.source_position)
      .. " target=" .. describe_target(job.target or job.target_position)
    )
  end

  job.release_tick = game.tick + math_max(1, job.fire_ticks or REAL_LAUNCHER_DEFAULT_FIRE_TICKS)
  job.cleanup_tick = job.release_tick + math_max(1, job.cleanup_delay or REAL_LAUNCHER_DEFAULT_CLEANUP_TICKS)
  if job.family == FAMILY_LAUNCHER_STREAM then
    job.next_retarget_tick = game.tick + REAL_LAUNCHER_STREAM_RETARGET_INTERVAL_TICKS
  end
  job.state = "firing"
  return true
end

local function process_real_launcher_jobs(event)
  local jobs = storage.launcher_jobs
  if not jobs or #jobs == 0 then return end

  for i = #jobs, 1, -1 do
    local job = jobs[i]
    if job.state == "firing" then
      if event.tick >= job.release_tick then
        if job.launcher and job.launcher.valid then
          pcall(function()
            job.launcher.shooting_state = {
              state = defines.shooting.not_shooting,
              position = job.target_position,
            }
          end)
        end
        job.state = "cleanup"
      else
        maybe_retarget_stream_launcher(job, event.tick)
      end
    elseif job.state == "cleanup" and event.tick >= job.cleanup_tick then
      destroy_real_launcher_entity(job.launcher)
      table.remove(jobs, i)
    end
  end

  if #jobs == 0 then return end

  local starts_remaining = REAL_LAUNCHER_MAX_STARTS_PER_TICK
  local failed_indices = nil

  for i = 1, #jobs do
    if starts_remaining <= 0 then break end

    local job = jobs[i]
    if job.state == "pending" and event.tick >= job.spawn_tick then
      local ok, reason = prepare_real_launcher_job(job)
      if ok then
        starts_remaining = starts_remaining - 1
      else
        execute_real_launcher_fallback(job, reason)
        failed_indices = failed_indices or {}
        failed_indices[#failed_indices + 1] = i
      end
    end
  end

  if not failed_indices then return end

  for i = #failed_indices, 1, -1 do
    table.remove(jobs, failed_indices[i])
  end
end

local function resolve_average_projectile_speed()
  local setting = settings.global["detonation-average-speed"]
  local value = setting and setting.value

  if type(value) ~= "number" then
    Debug.log("[DETONATION] Invalid detonation-average-speed value: " ..
      tostring(value) .. ", defaulting to " .. DEFAULT_AVERAGE_PROJECTILE_SPEED)
    return DEFAULT_AVERAGE_PROJECTILE_SPEED
  end

  return value
end

local function sample_standard_normal(rng)
  local u1 = math_max(rng(), 1e-12)
  local u2 = rng()
  return math_sqrt(-2 * math_log(u1)) * math_cos(2 * math.pi * u2)
end

local function compute_projectile_speed(rng, average_speed)
  for _ = 1, 6 do
    local sampled = average_speed + sample_standard_normal(rng) * PROJECTILE_SPEED_SIGMA
    if sampled >= MIN_PROJECTILE_SPEED and sampled <= MAX_PROJECTILE_SPEED then
      return sampled
    end
  end

  local fallback = average_speed + sample_standard_normal(rng) * PROJECTILE_SPEED_SIGMA
  return math_min(MAX_PROJECTILE_SPEED, math_max(MIN_PROJECTILE_SPEED, fallback))
end

local function resolve_staggered_detonation_ticks()
  local setting = settings.global["detonation-staggered-detonations"]
  local value = setting and setting.value
  if type(value) ~= "number" then
    Debug.log("[DETONATION] Invalid detonation-staggered-detonations value: " ..
      tostring(value) .. ", defaulting to 0")
    return 0
  end

  return math_max(0, math_floor(value))
end

local function resolve_staggered_detonation_span(scheduled_count)
  local stagger_ticks = resolve_staggered_detonation_ticks()
  if stagger_ticks <= 0 then return 0 end
  if type(scheduled_count) ~= "number" or scheduled_count <= 0 then return 0 end
  return stagger_ticks + math_floor(math_sqrt(scheduled_count))
end

local function resolve_initial_detonation_delay_ticks()
  local setting = settings.global["detonation-initial-detonation-delay"]
  local value = setting and setting.value
  if type(value) ~= "number" then
    Debug.log("[DETONATION] Invalid detonation-initial-detonation-delay value: " ..
      tostring(value) .. ", defaulting to 0")
    return 0
  end

  return math_max(0, math_floor(value))
end

local function resolve_staggered_execute_tick(start_tick, emission_index, scheduled_count, span_ticks, initial_delay_ticks)
  initial_delay_ticks = math_max(0, math_floor(initial_delay_ticks or 0))
  if span_ticks <= 0 then
    if initial_delay_ticks > 0 then return start_tick + initial_delay_ticks end
    return nil
  end
  if scheduled_count <= 1 then return start_tick + initial_delay_ticks + span_ticks end
  local offset = math_floor(((emission_index - 1) * (span_ticks - 1)) / (scheduled_count - 1))
  return start_tick + initial_delay_ticks + 1 + offset
end

local function copy_emit_node(node)
  return {
    payload_key               = node.payload_key,
    item_name                 = node.item_name,
    item_quality              = node.item_quality,
    projectile_name           = node.projectile_name,
    spawn_entity_name         = node.spawn_entity_name,
    ammo_category             = node.ammo_category,
    exact_count               = node.exact_count,
    damage                    = node.damage,
    radius_scale              = node.radius_scale,
    delivery_kind             = node.delivery_kind,
    family                    = node.family,
    current_executor          = node.current_executor,
    target_executor           = node.target_executor,
    source_item_count         = node.source_item_count,
    real_launcher_charge_size = node.real_launcher_charge_size,
    launcher_prototype        = node.launcher_prototype,
    launcher_min_distance     = node.launcher_min_distance,
    launcher_max_distance     = node.launcher_max_distance,
  }
end

local function resolve_emit_job_target(job)
  if is_valid_entity_reference(job.target) then return job.target end
  return copy_position(job.target_position)
end

local function execute_emit_job(job)
  local surface = game.get_surface(job.surface_index)
  if not surface then return end

  local node = job.node
  local center = copy_position(job.center)
  local target = resolve_emit_job_target(job)
  local force = job.force or resolve_default_force()
  if not (node and center and target) then return end

  local can_queue = can_queue_real_launcher(node, target)
  if can_queue
      and enqueue_real_launcher_job(surface, center, target, job.distance, node, job.speed, force, job.cause,
        job.charge_count)
  then
    if debug_enabled() then
      Debug.log(
        "[DETONATION][LAUNCHER][QUEUE] family=" .. tostring(node.family)
        .. " projectile=" .. tostring(node.projectile_name)
        .. " launcher=" .. tostring(node.launcher_prototype)
        .. " ammo=" .. tostring(node.ammo_category)
        .. " quality=" .. tostring(node.item_quality)
        .. " charges=" .. tostring(job.charge_count)
        .. " target=" .. describe_target(target)
      )
    end
    return
  end

  if node.target_executor == EXECUTOR_REAL_LAUNCHER and debug_enabled() then
    Debug.log(
      "[DETONATION][LAUNCHER][SKIP] family=" .. tostring(node.family)
      .. " projectile=" .. tostring(node.projectile_name)
      .. " launcher=" .. tostring(node.launcher_prototype)
      .. " quality=" .. tostring(node.item_quality)
      .. " charges=" .. tostring(job.charge_count)
      .. " reason=" .. tostring(explain_real_launcher_skip(node, target))
      .. " target=" .. describe_target(target)
    )
  end

  if node.current_executor == EXECUTOR_DIRECT_SPAWN then
    spawn_projectile(surface, center, target, job.distance, node, job.speed, force, job.cause)
  end
end

local function enqueue_staggered_emit_job(job, execute_tick)
  initialize_runtime_storage()
  local jobs = storage.emit_jobs
  local bucket = jobs[execute_tick]
  if not bucket then
    bucket = {}
    jobs[execute_tick] = bucket
  end

  bucket[#bucket + 1] = job
  storage.emit_job_count = (storage.emit_job_count or 0) + 1
  ensure_tick_handler()
end

local function process_staggered_emit_jobs(event)
  local jobs = storage.emit_jobs
  if not jobs then return end

  local bucket = jobs[event.tick]
  if not bucket then return end
  jobs[event.tick] = nil
  storage.emit_job_count = math_max(0, (storage.emit_job_count or #bucket) - #bucket)

  for i = 1, #bucket do
    execute_emit_job(bucket[i])
  end
end

local function emit_payload(surface, center, payload, excluded_entity, force, cause, emission_direction)
  if payload.total_count <= 0 then return end

  local debug = debug_enabled()
  local setting_value = settings.global["detonation-max-explosions"].value
  if type(setting_value) ~= "number" or setting_value < 1 then
    Debug.log("[DETONATION] Invalid detonation-max-explosions value: " .. tostring(setting_value) .. ", defaulting to 1")
    setting_value = 1
  end
  local limit = math_min(payload.total_count, math_floor(setting_value))
  local nodes, budget = allocate_spawn_budget(payload, limit)

  local scheduled_count = 0
  for i = 1, #nodes do
    local node = nodes[i]
    scheduled_count = scheduled_count + (budget[node.payload_key] or 0)
  end
  local stagger_span = resolve_staggered_detonation_span(scheduled_count)
  local initial_delay_ticks = resolve_initial_detonation_delay_ticks()
  if debug then
    Debug.log(
      "[DETONATION][EMIT] center=" .. describe_position(center)
      .. " payload_total=" .. tostring(payload.total_count)
      .. " limit=" .. tostring(limit)
      .. " scheduled=" .. tostring(scheduled_count)
      .. " stagger_span=" .. tostring(stagger_span)
      .. " initial_delay=" .. tostring(initial_delay_ticks)
      .. " nodes=" .. tostring(#nodes)
      .. " excluded=" .. describe_entity(excluded_entity)
      .. " cause=" .. describe_entity(cause)
      .. " force=" .. tostring(force and force.name)
      .. " direction=" .. describe_direction(emission_direction)
    )
  end
  if scheduled_count <= 0 then
    Debug.log("[DETONATION][EMIT] scheduled_count=0; detonation aborted")
    return
  end

  if debug and payload.total_count >= 50 then
    local gps = "[gps=" .. math_floor(center.x) .. "," .. math_floor(center.y) .. "]"
    Debug.log("[DETONATION] Detonation of " .. payload.total_count .. " charges at " .. gps)
  end

  local emit_seed     = deterministic_seed(center, game.tick)
  local rng           = game.create_random_generator(emit_seed)
  local schedule_rng  = game.create_random_generator(
    normalize_random_seed(emit_seed + scheduled_count * 104729 + #nodes * 8191)
  )
  local schedule      = build_emit_schedule(nodes, budget, schedule_rng)
  local sampler       = Distribution.new(center, payload.total_count, rng, {
    direction = emission_direction,
  })
  local attack_force  = force or resolve_default_force()
  local average_speed = resolve_average_projectile_speed()

  if debug then
    for i = 1, #nodes do
      local node = nodes[i]
      local count = budget[node.payload_key] or 0
      Debug.log(
        "[DETONATION][EMIT][BUDGET] projectile=" .. node.projectile_name
        .. " kind=" .. tostring(node.delivery_kind)
        .. " family=" .. tostring(node.family)
        .. " current=" .. tostring(node.current_executor)
        .. " target=" .. tostring(node.target_executor)
        .. " launcher=" .. tostring(node.launcher_prototype)
        .. " ammo=" .. tostring(node.ammo_category)
        .. " quality=" .. tostring(node.item_quality)
        .. " exact=" .. tostring(node.exact_count)
        .. " scheduled=" .. tostring(count)
      )
    end
  end

  for emission_index = 1, #schedule do
    local node = schedule[emission_index].node
    local target, distance             = sampler(node.radius_scale)
    local final_target, final_distance = resolve_emit_target(node, surface, center, target, distance, rng,
      excluded_entity)
    local speed                        = compute_projectile_speed(rng, average_speed)
    local consumed_count               = 1
    resolve_launcher_prototype_for_node(surface, attack_force, node)
    local can_queue = can_queue_real_launcher(node, final_target)
    if can_queue then
      consumed_count = resolve_real_launcher_charge_count(node)
    end

    local job = {
      node = copy_emit_node(node),
      surface_index = surface.index,
      center = copy_position(center),
      target = is_valid_entity_reference(final_target) and final_target or nil,
      target_position = copy_position(final_target and final_target.position) or copy_position(final_target),
      distance = final_distance,
      speed = speed,
      force = attack_force,
      cause = cause,
      charge_count = consumed_count,
    }

    local execute_tick = resolve_staggered_execute_tick(
      game.tick,
      emission_index,
      scheduled_count,
      stagger_span,
      initial_delay_ticks
    )
    if execute_tick then
      enqueue_staggered_emit_job(job, execute_tick)
    else
      execute_emit_job(job)
    end
  end
end

local function rebuild_runtime_state()
  Debug.log("[DETONATION] Rebuilding runtime state")
  initialize_runtime_storage()
  storage.launcher_jobs = {}
  storage.emit_jobs = {}
  storage.emit_job_count = 0
  refresh_tick_handler()
  build_payload_specs()
  ENTITY_CAPS              = {}

  storage.item_specs       = ITEM_SPECS
  storage.projectile_specs = PROJECTILE_SPECS
  storage.entity_caps      = ENTITY_CAPS
end

local function load_runtime_state()
  ITEM_SPECS       = storage.item_specs or {}
  PROJECTILE_SPECS = storage.projectile_specs or {}
  ENTITY_CAPS      = storage.entity_caps or {}
end

local function on_pre_player_died(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local character = player.character
  if not (character and character.valid) then return end

  if debug_enabled() then
    Debug.log(
      "[DETONATION][EVENT] on_pre_player_died player=" .. tostring(player.name)
      .. " index=" .. tostring(event.player_index)
      .. " character=" .. describe_entity(character)
      .. " position=" .. describe_position(character.position)
    )
  end

  local payload = new_payload()
  collect_from_entity(payload, character, {
    consume_inventories = true,
    consume_held_stack  = true,
  })
  collect_from_stack(payload, function() return player.cursor_stack end, true)

  log_payload_details("PRE_PLAYER_DIED", payload)

  if payload.total_count > 0 then
    emit_payload(character.surface, character.position, payload, character, player.force, character)
  else
    Debug.log("[DETONATION][EVENT] on_pre_player_died: payload is empty, no detonation")
  end
end

local function on_entity_died(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.type == "character" then
    Debug.log("[DETONATION][EVENT] on_entity_died skipped character entity")
    return
  end

  if debug_enabled() then
    Debug.log(
      "[DETONATION][EVENT] on_entity_died entity=" .. describe_entity(entity)
      .. " position=" .. describe_position(entity.position)
      .. " killer=" .. describe_entity(event.cause)
    )
  end

  local payload = new_payload()
  collect_from_entity(payload, entity, {
    consume_transport_lines = true,
    consume_held_stack      = true,
  })

  log_payload_details("ENTITY_DIED", payload)

  if payload.total_count > 0 then
    local projectile_cause = resolve_projectile_cause_entity(entity)
    local emission_direction = resolve_impact_direction(entity, event.cause)
    emit_payload(
      entity.surface,
      entity.position,
      payload,
      entity,
      resolve_entity_force(entity) or resolve_default_force(),
      projectile_cause,
      emission_direction
    )
  else
    Debug.log("[DETONATION][EVENT] on_entity_died: payload is empty, no detonation")
  end
end

process_tick = function(event)
  process_staggered_emit_jobs(event)
  process_real_launcher_jobs(event)
  refresh_tick_handler()
end

local function register_events()
  script.on_event(defines.events.on_entity_died, on_entity_died)
  script.on_event(defines.events.on_pre_player_died, on_pre_player_died)
  refresh_tick_handler()
end

local function set_real_launcher_family_enabled(family, enabled)
  initialize_runtime_storage()
  storage.real_launcher_enabled_families[family] = enabled == true
end

script.on_init(function()
  rebuild_runtime_state()
  register_events()
end)

script.on_load(function()
  load_runtime_state()
  register_events()
end)

script.on_configuration_changed(function()
  rebuild_runtime_state()
  register_events()
end)

commands.add_command("detonation_rebuild", "Rebuild all detonation payload mappings", function()
  rebuild_runtime_state()
  game.print("Detonation: mappings rebuilt")
  game.print("Explosive items tracked: " .. table_size(ITEM_SPECS))
  game.print("Projectile specs cached: " .. table_size(PROJECTILE_SPECS))
end)

commands.add_command("detonation_stats", "Show detonation runtime statistics", function()
  game.print("=== Detonation Statistics ===")
  game.print("Explosive items tracked: " .. table_size(ITEM_SPECS))
  game.print("Projectile specs cached: " .. table_size(PROJECTILE_SPECS))
  game.print("Entity capability cache: " .. table_size(ENTITY_CAPS))
  game.print("Queued launcher jobs: " .. tostring(storage.launcher_jobs and #storage.launcher_jobs or 0))
  game.print("Queued staggered shots: " .. tostring(storage.emit_job_count or 0))

  local inventory_types  = 0
  local line_types       = 0
  local held_stack_types = 0

  for _, caps in pairs(ENTITY_CAPS) do
    if caps.inventories then inventory_types = inventory_types + 1 end
    if caps.transport_lines then line_types = line_types + 1 end
    if caps.held_stack then held_stack_types = held_stack_types + 1 end
  end

  game.print("Types with inventories: " .. inventory_types)
  game.print("Types with transport lines: " .. line_types)
  game.print("Types with held stacks: " .. held_stack_types)
end)

commands.add_command("detonation_launcher_status", "Show real-launcher family gates", function()
  game.print("=== Detonation Launcher Families ===")
  for _, family in ipairs({
    FAMILY_LAUNCHER_COMPOSITE_BEAM,
    FAMILY_LAUNCHER_STREAM,
    FAMILY_LAUNCHER_LINE,
  }) do
    game.print(family .. " = " .. tostring(is_real_launcher_family_enabled(family)))
  end
end)

commands.add_command("detonation_launcher_enable", "Enable a real-launcher family gate", function(event)
  local family = event.parameter
  if not family or family == "" then
    game.print("Usage: /detonation_launcher_enable <family>")
    return
  end
  set_real_launcher_family_enabled(family, true)
  game.print("Enabled real-launcher family: " .. family)
end)

commands.add_command("detonation_launcher_disable", "Disable a real-launcher family gate", function(event)
  local family = event.parameter
  if not family or family == "" then
    game.print("Usage: /detonation_launcher_disable <family>")
    return
  end
  set_real_launcher_family_enabled(family, false)
  game.print("Disabled real-launcher family: " .. family)
end)
