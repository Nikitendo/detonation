-- ============================================================================
-- Detonation: When Ammo Blows Up
-- Data-driven payload compiler + pluggable distribution strategies
-- ============================================================================

local Debug = require("debug")
local Distribution = require("distribution")
local Launcher = require("runtime.launcher")
local debug_enabled = Debug.enabled

local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_log = math.log
local math_cos = math.cos
local math_sqrt = math.sqrt
local table_sort = table.sort

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
local EXECUTOR_REAL_LAUNCHER = Launcher.EXECUTOR
local EXECUTOR_SKIPPED = "skipped"

local FAMILY_DIRECT_PROJECTILE = "direct-projectile"
local FAMILY_CAPSULE_PROJECTILE = "capsule-projectile"
local FAMILY_LAUNCHER_STREAM = Launcher.FAMILY_STREAM
local FAMILY_LAUNCHER_LINE = Launcher.FAMILY_LINE
local FAMILY_LAUNCHER_COMPOSITE_BEAM = Launcher.FAMILY_COMPOSITE_BEAM
local FAMILY_UNKNOWN = "unknown"

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
local find_damage_in_action
local process_tick
local ensure_tick_handler
local refresh_tick_handler
local tick_handler_registered = false

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

local function initialize_runtime_storage()
  Launcher.initialize_storage()
  storage.emit_jobs = storage.emit_jobs or {}
  storage.emit_job_count = storage.emit_job_count or 0
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

local function has_pending_tick_work()
  return has_pending_emit_jobs() or Launcher.has_pending_jobs()
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

  local launcher_catalog = Launcher.build_catalog(required_launcher_items)

  for i = 1, #scanned_specs do
    local scanned = scanned_specs[i]
    local item_name = scanned.item_name
    local prototype = scanned.prototype

    if scanned.projectile_name or scanned.target_executor == EXECUTOR_REAL_LAUNCHER then
      local delivery_spec = scanned.projectile_name
          and compile_projectile_spec(scanned.projectile_name, scanned.delivery_kind)
          or compile_action_delivery_spec(scanned.action_root, scanned.family, scanned.delivery_kind)
      local launcher = scanned.ammo_category and launcher_catalog[scanned.ammo_category]
      local launcher_min_distance, launcher_max_distance = Launcher.resolve_range(launcher, item_name)
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
        launcher_min_distance     = launcher_min_distance,
        launcher_max_distance     = launcher_max_distance,
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

local function resolve_emit_target(node, surface, center, sampled_target, sampled_distance, rng, excluded_entity)
  if node.family == FAMILY_LAUNCHER_STREAM then
    return Launcher.resolve_target(node, center, sampled_target, sampled_distance, rng)
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

  local can_queue = Launcher.can_queue(node, target)
  if can_queue
      and Launcher.enqueue(
        surface,
        center,
        target,
        job.distance,
        node,
        job.speed,
        force,
        job.cause,
        job.charge_count,
        ensure_tick_handler
      )
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
      .. " reason=" .. tostring(Launcher.explain_skip(node, target))
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
    Launcher.resolve_prototype(surface, attack_force, node, ITEM_SPECS)
    local can_queue = Launcher.can_queue(node, final_target)
    if can_queue then
      consumed_count = Launcher.resolve_charge_count(node)
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
  Launcher.reset_jobs()
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
  Launcher.process_jobs(event, execute_real_launcher_fallback)
  refresh_tick_handler()
end

local function register_events()
  script.on_event(defines.events.on_entity_died, on_entity_died)
  script.on_event(defines.events.on_pre_player_died, on_pre_player_died)
  refresh_tick_handler()
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
  game.print("Queued launcher jobs: " .. tostring(Launcher.queued_count()))
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
  for _, family in ipairs(Launcher.family_names()) do
    game.print(family .. " = " .. tostring(Launcher.is_family_enabled(family)))
  end
end)

commands.add_command("detonation_launcher_enable", "Enable a real-launcher family gate", function(event)
  local family = event.parameter
  if not family or family == "" then
    game.print("Usage: /detonation_launcher_enable <family>")
    return
  end
  Launcher.set_family_enabled(family, true)
  game.print("Enabled real-launcher family: " .. family)
end)

commands.add_command("detonation_launcher_disable", "Disable a real-launcher family gate", function(event)
  local family = event.parameter
  if not family or family == "" then
    game.print("Usage: /detonation_launcher_disable <family>")
    return
  end
  Launcher.set_family_enabled(family, false)
  game.print("Disabled real-launcher family: " .. family)
end)
