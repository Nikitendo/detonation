local Debug = require("debug")

local Launcher = {}

Launcher.EXECUTOR = "real-launcher"
Launcher.FAMILY_STREAM = "launcher-stream"
Launcher.FAMILY_LINE = "launcher-line"
Launcher.FAMILY_COMPOSITE_BEAM = "launcher-composite-beam"

local HOST_CHARACTER = "detonation-invisible-character"
local SPAWN_DELAY = 1
local DEFAULT_FIRE_TICKS = 1
local DEFAULT_CLEANUP_TICKS = 2
local MAX_STARTS_PER_TICK = 1
local DISCOVERY_PREFERRED_DISTANCE = 6
local DISCOVERY_RANGE_MARGIN = 0.25
local STREAM_MIN_AIM_DISTANCE = 4.0
local STREAM_MIN_FIRE_TICKS = 20
local STREAM_MAX_FIRE_TICKS = 120
local STREAM_RETARGET_INTERVAL_TICKS = 5
local STREAM_RETARGET_MAX_ANGLE_OFFSET = math.pi * 10
local STREAM_RETARGET_MAX_DISTANCE_OFFSET = 2.0
local HOST_SEARCH_RADIUS = 1.5
local HOST_SEARCH_PRECISION = 0.25
local DEFAULT_QUALITY_NAME = "normal"
local DEFAULT_FORCE_NAME = "player"
local SEED_MODULUS = 2147483646
local GATE_DEFAULTS_VERSION = 3

local ENABLED_FAMILIES = {
  [Launcher.FAMILY_STREAM] = true,
  [Launcher.FAMILY_COMPOSITE_BEAM] = true,
  [Launcher.FAMILY_LINE] = true,
}

local catalog = nil
local candidates_by_category = nil

local function is_map_position(value)
  return type(value) == "table"
      and type(value.x) == "number"
      and type(value.y) == "number"
end

local function copy_position(pos)
  if not is_map_position(pos) then return nil end
  return { x = pos.x, y = pos.y }
end

local function is_valid_entity_reference(value)
  if value == nil then return false end
  local ok_valid, valid = pcall(function() return value.valid end)
  return ok_valid and valid == true
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

local function describe_position(pos)
  if is_map_position(pos) then
    local x = math.floor(pos.x * 10) / 10
    local y = math.floor(pos.y * 10) / 10
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
  return describe_position(target)
end

local function deterministic_seed(center, tick)
  local x = math.floor(center.x * 1000)
  local y = math.floor(center.y * 1000)
  local seed = x * 73856093 + y * 19349663 + tick * 83492791
  local r = seed % SEED_MODULUS
  return (r < 0 and r + SEED_MODULUS or r) + 1
end

local function normalize_random_seed(seed)
  local normalized = math.floor(seed or 1)
  local wrapped = normalized % SEED_MODULUS
  if wrapped < 0 then wrapped = wrapped + SEED_MODULUS end
  return wrapped + 1
end

local function accepts_position_target(family)
  return family == Launcher.FAMILY_STREAM or family == Launcher.FAMILY_LINE
end

local function default_enabled_families()
  local enabled = {}
  for family, value in pairs(ENABLED_FAMILIES) do
    enabled[family] = value == true
  end
  return enabled
end

function Launcher.initialize_storage()
  storage.launcher_jobs = storage.launcher_jobs or {}
  storage.real_launcher_enabled_families = storage.real_launcher_enabled_families or default_enabled_families()

  local defaults_version = storage.real_launcher_gate_defaults_version or 0
  if defaults_version < GATE_DEFAULTS_VERSION then
    for family in pairs(ENABLED_FAMILIES) do
      storage.real_launcher_enabled_families[family] = true
    end
    storage.real_launcher_gate_defaults_version = GATE_DEFAULTS_VERSION
  end
end

function Launcher.reset_jobs()
  Launcher.initialize_storage()
  storage.launcher_jobs = {}
end

function Launcher.has_pending_jobs()
  if not storage then return false end
  local jobs = storage.launcher_jobs
  return jobs ~= nil and #jobs > 0
end

function Launcher.queued_count()
  return storage and storage.launcher_jobs and #storage.launcher_jobs or 0
end

function Launcher.is_family_enabled(family)
  local enabled = storage and storage.real_launcher_enabled_families
  if type(enabled) == "table" and enabled[family] ~= nil then
    return enabled[family] == true
  end
  return ENABLED_FAMILIES[family] == true
end

function Launcher.set_family_enabled(family, enabled)
  Launcher.initialize_storage()
  storage.real_launcher_enabled_families[family] = enabled == true
end

function Launcher.family_names()
  return {
    Launcher.FAMILY_COMPOSITE_BEAM,
    Launcher.FAMILY_STREAM,
    Launcher.FAMILY_LINE,
  }
end

local function destroy_entity(entity)
  if entity and entity.valid then
    pcall(function() entity.destroy() end)
  end
end

local function set_host_flags(entity)
  pcall(function() entity.destructible = false end)
  pcall(function() entity.operable = false end)
  pcall(function() entity.minable = false end)
end

local function is_hidden_item_prototype(prototype)
  local ok_hidden, hidden = pcall(function() return prototype.has_flag("hidden") end)
  if ok_hidden then return hidden == true end
  local ok_fallback, fallback = pcall(function() return prototype.hidden end)
  return ok_fallback and fallback == true
end

local function compare_candidates(a, b)
  if a.hidden ~= b.hidden then return not a.hidden end
  return a.name < b.name
end

local function read_attack_parameters(prototype)
  local ok, attack = pcall(function() return prototype.attack_parameters end)
  if not ok or type(attack) ~= "table" then return nil end
  if type(attack.ammo_categories) ~= "table" then return nil end
  if type(attack.range) ~= "number" then return nil end
  return attack
end

local function build_candidate_index(required_ammo_items)
  local requested = {}
  local index = {}

  for ammo_category in pairs(required_ammo_items or {}) do
    requested[ammo_category] = true
    index[ammo_category] = {}
  end

  for item_name, prototype in pairs(prototypes.item) do
    local attack = read_attack_parameters(prototype)
    if attack then
      for i = 1, #attack.ammo_categories do
        local ammo_category = normalize_id_name(attack.ammo_categories[i]) or attack.ammo_categories[i]
        local candidates = requested[ammo_category] and index[ammo_category] or nil
        if candidates then
          candidates[#candidates + 1] = {
            name = item_name,
            hidden = is_hidden_item_prototype(prototype),
            attack_type = attack.type,
            min_range = type(attack.min_range) == "number" and attack.min_range or 0,
            range = attack.range,
          }
        end
      end
    end
  end

  for _, candidates in pairs(index) do
    table.sort(candidates, compare_candidates)
  end

  return index
end

local function find_discovery_surface()
  local surface = game.get_surface(1)
  if surface then return surface end
  for _, candidate in pairs(game.surfaces) do return candidate end
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
  if inventory and inventory.valid then
    pcall(function() inventory.clear() end)
  end
end

local function try_can_shoot(launcher, family, target_entity, target_position)
  if not (launcher and launcher.valid and is_map_position(target_position)) then return false end

  if target_entity then
    local ok, can_shoot = pcall(function()
      return launcher.can_shoot(target_entity, target_position)
    end)
    return ok and can_shoot == true
  end

  if not accepts_position_target(family) then return false end

  local ok, can_shoot = pcall(function()
    return launcher.can_shoot(nil, target_position)
  end)
  if ok and can_shoot then return true end
  if family ~= Launcher.FAMILY_STREAM then return false end

  ok, can_shoot = pcall(function()
    return launcher.can_shoot(launcher, target_position)
  end)
  return ok and can_shoot == true
end

local function destroy_discovery_context(context)
  if not context then return end
  clear_inventory_safe(context.guns)
  clear_inventory_safe(context.ammo)
  destroy_entity(context.launcher)
  destroy_entity(context.target)
end

local function create_discovery_context(surface, force)
  if not surface then return nil, "missing surface" end
  if not (force and force.valid) then return nil, "missing force" end

  local host_position = find_non_colliding_position_safe(surface, HOST_CHARACTER, { x = 0, y = 0 }, 128, 0.5)
  if not host_position then return nil, "host position unavailable" end

  local ok_launcher, launcher = pcall(function()
    return surface.create_entity {
      name = HOST_CHARACTER,
      position = host_position,
      force = force,
      create_build_effect_smoke = false,
    }
  end)
  if not ok_launcher or not launcher then
    return nil, "discovery launcher create failed"
  end

  set_host_flags(launcher)

  local guns = launcher.get_inventory(defines.inventory.character_guns)
  local ammo = launcher.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo) then
    destroy_entity(launcher)
    return nil, "discovery inventories unavailable"
  end

  return {
    surface = surface,
    launcher = launcher,
    target = nil,
    guns = guns,
    ammo = ammo,
  }
end

local function resolve_ammo_range_modifier(ammo_item_name)
  local prototype = prototypes.item[ammo_item_name]
  if not prototype then return 1 end

  local ok, ammo_type = pcall(function() return prototype.get_ammo_type("player") end)
  if not ok or not ammo_type then
    ok, ammo_type = pcall(function() return prototype.get_ammo_type() end)
  end
  if not ok or not ammo_type then return 1 end

  local modifier = ammo_type.range_modifier
  if type(modifier) ~= "number" then return 1 end
  return math.max(0, modifier)
end

local function resolve_candidate_range(candidate, ammo_range_modifier)
  local min_distance = math.max(0, candidate.min_range or 0)
  local max_distance = math.max(0, (candidate.range or 0) * ammo_range_modifier)
  return min_distance, max_distance
end

local function resolve_probe_distance(min_distance, max_distance)
  if max_distance <= 0 then return nil end

  local lower = min_distance + DISCOVERY_RANGE_MARGIN
  local upper = max_distance - DISCOVERY_RANGE_MARGIN
  if upper < lower then
    return math.max(0, math.min(max_distance, (min_distance + max_distance) * 0.5))
  end

  return math.max(lower, math.min(DISCOVERY_PREFERRED_DISTANCE, upper))
end

local function create_discovery_target(context, probe_distance)
  destroy_entity(context.target)
  context.target = nil

  local source_position = copy_position(context.launcher.position)
  if not source_position then return nil end

  local desired_position = {
    x = source_position.x + probe_distance,
    y = source_position.y,
  }
  local target_position = find_non_colliding_position_safe(
    context.surface,
    "steel-chest",
    desired_position,
    2,
    0.25
  ) or desired_position

  local ok, target = pcall(function()
    return context.surface.create_entity {
      name = "steel-chest",
      position = target_position,
      force = game.forces.enemy or game.forces.neutral,
      create_build_effect_smoke = false,
    }
  end)
  if not ok or not target then return nil end

  context.target = target
  pcall(function() target.destructible = false end)
  pcall(function() target.minable = false end)
  return target
end

local function discover(surface, force, ammo_item_name, ammo_category, family)
  if not candidates_by_category or not candidates_by_category[ammo_category] then
    local built = build_candidate_index {
      [ammo_category] = {
        item_name = ammo_item_name,
        family = family,
      },
    }
    candidates_by_category = candidates_by_category or {}
    candidates_by_category[ammo_category] = built[ammo_category] or {}
  end

  local context, reason = create_discovery_context(surface, force)
  if not context then
    Debug.log("[DETONATION][LAUNCHER][DISCOVER][ERROR] ammo=" .. tostring(ammo_item_name)
      .. " category=" .. tostring(ammo_category) .. " reason=" .. tostring(reason))
    return nil
  end

  local ammo_range_modifier = resolve_ammo_range_modifier(ammo_item_name)
  local candidates = candidates_by_category and candidates_by_category[ammo_category] or {}
  local best

  for i = 1, #candidates do
    local candidate = candidates[i]
    clear_inventory_safe(context.guns)
    clear_inventory_safe(context.ammo)

    local min_distance, max_distance = resolve_candidate_range(candidate, ammo_range_modifier)
    local probe_distance = resolve_probe_distance(min_distance, max_distance)
    local target = probe_distance and create_discovery_target(context, probe_distance) or nil
    local ok_can_insert, can_insert = pcall(function()
      return context.guns.can_insert { name = candidate.name, count = 1 }
    end)
    if target and ok_can_insert and can_insert then
      local inserted_gun = context.guns.insert { name = candidate.name, count = 1 }
      local inserted_ammo = context.ammo.insert { name = ammo_item_name, count = 1 }
      if inserted_gun > 0 and inserted_ammo > 0 then
        local ok_selected = pcall(function() context.launcher.selected_gun_index = 1 end)
        local ok_can_shoot, can_shoot = pcall(function()
          return context.launcher.can_shoot(target, target.position)
        end)
        if ok_selected and ok_can_shoot and can_shoot then
          best = {
            name = candidate.name,
            hidden = candidate.hidden,
            attack_type = candidate.attack_type,
            min_range = candidate.min_range,
            range = candidate.range,
            min_distance = min_distance,
            max_distance = max_distance,
          }
          break
        end
      end
    end
  end

  destroy_discovery_context(context)
  if best then
    Debug.log("[DETONATION][LAUNCHER][DISCOVER][OK] ammo=" .. tostring(ammo_item_name)
      .. " category=" .. tostring(ammo_category)
      .. " launcher=" .. tostring(best.name)
      .. " attack_type=" .. tostring(best.attack_type)
      .. (best.max_distance and (" range=" .. tostring(best.min_distance or "?")
        .. "-" .. tostring(best.max_distance)) or ""))
  else
    Debug.log("[DETONATION][LAUNCHER][DISCOVER][MISS] ammo=" .. tostring(ammo_item_name)
      .. " category=" .. tostring(ammo_category))
  end
  return best
end

function Launcher.build_catalog(required_ammo_items)
  catalog = {}
  candidates_by_category = build_candidate_index(required_ammo_items)
  local surface = find_discovery_surface()
  local force = game.forces[DEFAULT_FORCE_NAME]

  for ammo_category, request in pairs(required_ammo_items or {}) do
    local ammo_item_name = type(request) == "table" and request.item_name or request
    local family = type(request) == "table" and request.family or nil
    local launcher = discover(surface, force, ammo_item_name, ammo_category, family)
    if launcher then
      catalog[ammo_category] = launcher
    else
      Debug.log("[DETONATION][LAUNCHER][DISCOVER][UNRESOLVED] ammo=" .. tostring(ammo_item_name)
        .. " category=" .. tostring(ammo_category))
    end
  end
  return catalog
end

function Launcher.resolve_range(launcher, ammo_item_name)
  if not launcher then return nil, nil end
  return resolve_candidate_range(launcher, resolve_ammo_range_modifier(ammo_item_name))
end

local function apply_catalog_entry(spec, launcher, ammo_item_name)
  if not (spec and launcher) then return end
  if launcher.name then spec.launcher_prototype = launcher.name end
  local min_distance, max_distance = Launcher.resolve_range(launcher, ammo_item_name)
  if type(min_distance) == "number" then spec.launcher_min_distance = min_distance end
  if type(max_distance) == "number" then spec.launcher_max_distance = max_distance end
end

function Launcher.resolve_prototype(surface, force, node, item_specs)
  if node.target_executor ~= Launcher.EXECUTOR then return nil end
  if not node.ammo_category or not node.item_name then return nil end
  if not (surface and force) then return node.launcher_prototype end

  local launcher = catalog and catalog[node.ammo_category]
  if not launcher then
    launcher = discover(surface, force, node.item_name, node.ammo_category, node.family)
    if launcher then
      catalog = catalog or {}
      catalog[node.ammo_category] = launcher
    end
  end

  if launcher then
    apply_catalog_entry(node, launcher, node.item_name)
    apply_catalog_entry(item_specs and item_specs[node.item_name], launcher, node.item_name)
  end
  return node.launcher_prototype
end

local function resolve_stream_aim_limits(node)
  local launcher_min = type(node and node.launcher_min_distance) == "number" and node.launcher_min_distance or 0
  local launcher_max = type(node and node.launcher_max_distance) == "number" and node.launcher_max_distance or nil
  local min_aim = math.max(STREAM_MIN_AIM_DISTANCE, launcher_min)
  if launcher_max and launcher_max < min_aim then launcher_max = min_aim end
  return min_aim, launcher_max
end

local function resolve_stream_direction(source_position, target_position, rng)
  local dx = target_position.x - source_position.x
  local dy = target_position.y - source_position.y
  local distance = math.sqrt(dx * dx + dy * dy)
  if distance <= 0.001 then
    local angle = rng() * 2 * math.pi
    return math.cos(angle), math.sin(angle), 0
  end
  return dx / distance, dy / distance, distance
end

local function sample_uniform_annulus_distance(min_aim, max_aim, rng)
  if type(max_aim) ~= "number" or max_aim <= min_aim then return min_aim end
  return math.sqrt(min_aim * min_aim + rng() * (max_aim * max_aim - min_aim * min_aim))
end

local function build_stream_target_position(source_position, direction_x, direction_y, aim_distance)
  return {
    x = source_position.x + direction_x * aim_distance,
    y = source_position.y + direction_y * aim_distance,
  }
end

function Launcher.resolve_target(node, center, sampled_target, sampled_distance, rng)
  if node.family ~= Launcher.FAMILY_STREAM then return nil end

  local source_position = copy_position(center)
  local target_position = copy_position(sampled_target)
  if not source_position or not target_position then return sampled_target, sampled_distance end

  local min_aim, max_aim = resolve_stream_aim_limits(node)
  local direction_x, direction_y = resolve_stream_direction(source_position, target_position, rng)
  local aim_distance = sample_uniform_annulus_distance(min_aim, max_aim, rng)
  return build_stream_target_position(source_position, direction_x, direction_y, aim_distance), aim_distance
end

function Launcher.can_queue(node, target)
  if node.target_executor ~= Launcher.EXECUTOR then return false end
  if not Launcher.is_family_enabled(node.family) then return false end
  if not node.launcher_prototype or not node.item_name then return false end
  if is_valid_entity_reference(target) then return true end
  return accepts_position_target(node.family) and is_map_position(target)
end

function Launcher.explain_skip(node, target)
  if node.target_executor ~= Launcher.EXECUTOR then return "not a real-launcher family" end
  if not Launcher.is_family_enabled(node.family) then return "family gate disabled" end
  if not node.launcher_prototype then return "launcher prototype missing" end
  if not node.item_name then return "source item missing" end
  if is_valid_entity_reference(target) then return "enqueue rejected" end
  if accepts_position_target(node.family) and is_map_position(target) then return "enqueue rejected" end
  return "target is neither a valid entity nor a supported position"
end

function Launcher.resolve_charge_count(node)
  if node.family == Launcher.FAMILY_STREAM and node.target_executor == Launcher.EXECUTOR then
    return math.max(1, node.real_launcher_charge_size or 1)
  end
  return 1
end

local function resolve_fire_ticks(node, charge_count)
  if node.family == Launcher.FAMILY_STREAM then
    return math.min(STREAM_MAX_FIRE_TICKS, math.max(STREAM_MIN_FIRE_TICKS, charge_count))
  end
  return DEFAULT_FIRE_TICKS
end

local function compute_stream_retarget_seed(job, tick)
  local seed = deterministic_seed(job.source_position or job.target_position or { x = 0, y = 0 }, tick)
  if job.target_position then
    seed = seed + math.floor(job.target_position.x * 1000) * 19349663
    seed = seed + math.floor(job.target_position.y * 1000) * 83492791
  end
  return normalize_random_seed(seed)
end

local function sample_stream_retarget_position(job, tick)
  local source_position = copy_position(job.source_position)
  if not source_position then return nil end

  local min_aim = job.stream_min_distance or STREAM_MIN_AIM_DISTANCE
  local max_aim = job.stream_max_distance
  local distance_span = type(max_aim) == "number" and math.max(0, max_aim - min_aim) or 0
  local max_distance_offset = math.min(STREAM_RETARGET_MAX_DISTANCE_OFFSET, distance_span * 0.5)
  local rng = game.create_random_generator(compute_stream_retarget_seed(job, tick))
  local angle_offset = (rng() * 2 - 1) * STREAM_RETARGET_MAX_ANGLE_OFFSET
  local distance_offset = (rng() * 2 - 1) * max_distance_offset
  local cos_offset = math.cos(angle_offset)
  local sin_offset = math.sin(angle_offset)
  local base_x = job.stream_direction_x or 1
  local base_y = job.stream_direction_y or 0
  local direction_x = base_x * cos_offset - base_y * sin_offset
  local direction_y = base_x * sin_offset + base_y * cos_offset
  local aim_distance = math.max(min_aim, (job.stream_distance or min_aim) + distance_offset)
  if max_aim then aim_distance = math.min(aim_distance, max_aim) end

  return build_stream_target_position(source_position, direction_x, direction_y, aim_distance),
      aim_distance, direction_x, direction_y
end

function Launcher.enqueue(surface, center, target, distance, node, speed, force, cause, charge_count, ensure_tick_handler)
  Launcher.initialize_storage()

  local target_position = copy_position(target and target.position) or copy_position(target)
  if not target_position then return false end

  local queued_charge_count = math.max(1, charge_count or 1)
  local stream_min, stream_max = resolve_stream_aim_limits(node)
  local direction_x, direction_y, stream_distance = 1, 0, stream_min
  if node.family == Launcher.FAMILY_STREAM then
    direction_x, direction_y, stream_distance = resolve_stream_direction(
      center,
      target_position,
      game.create_random_generator(compute_stream_retarget_seed({
        source_position = center,
        target_position = target_position,
      }, game.tick))
    )
    stream_distance = math.max(stream_min, stream_distance)
    if stream_max then stream_distance = math.min(stream_distance, stream_max) end
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
    fire_ticks = resolve_fire_ticks(node, queued_charge_count),
    cleanup_delay = DEFAULT_CLEANUP_TICKS,
    spawn_tick = game.tick + SPAWN_DELAY,
    state = "pending",
    stream_min_distance = stream_min,
    stream_max_distance = stream_max,
    stream_direction_x = direction_x,
    stream_direction_y = direction_y,
    stream_distance = stream_distance,
  }

  ensure_tick_handler()
  return true
end

local function can_job_shoot(launcher, job, target_entity)
  if job.family == Launcher.FAMILY_LINE and not target_entity and is_map_position(job.target_position) then
    return true
  end
  return try_can_shoot(launcher, job.family, target_entity, job.target_position)
end

local function maybe_retarget_stream(job, tick)
  if job.family ~= Launcher.FAMILY_STREAM then return end
  if not (job.launcher and job.launcher.valid) then return end
  if not job.next_retarget_tick or tick < job.next_retarget_tick then return end
  job.next_retarget_tick = tick + STREAM_RETARGET_INTERVAL_TICKS

  local target_position, aim_distance, direction_x, direction_y = sample_stream_retarget_position(job, tick)
  if not target_position or not try_can_shoot(job.launcher, job.family, nil, target_position) then return end

  local ok = pcall(function()
    job.launcher.shooting_state = {
      state = defines.shooting.shooting_selected,
      position = target_position,
    }
  end)
  if not ok then return end

  job.target_position = target_position
  job.stream_distance = aim_distance
  job.stream_direction_x = direction_x
  job.stream_direction_y = direction_y
end

local function prepare_job(job)
  local surface = game.get_surface(job.surface_index)
  if not surface then return false, "missing surface" end
  if not job.target_position then return false, "missing target position" end

  local seed_position = copy_position(job.source_position)
  if not seed_position then return false, "host seed position unavailable" end

  local ok_pos, spawn_position = pcall(function()
    return surface.find_non_colliding_position(
      HOST_CHARACTER,
      seed_position,
      HOST_SEARCH_RADIUS,
      HOST_SEARCH_PRECISION
    )
  end)
  if not ok_pos then return false, "find_non_colliding_position failed" end
  spawn_position = spawn_position or seed_position

  local ok_create, launcher = pcall(function()
    return surface.create_entity {
      name = HOST_CHARACTER,
      position = spawn_position,
      force = job.force,
      create_build_effect_smoke = false,
    }
  end)
  if not ok_create or not launcher then return false, "launcher host create failed" end

  job.launcher = launcher
  set_host_flags(launcher)
  local guns = launcher.get_inventory(defines.inventory.character_guns)
  local ammo = launcher.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo) then
    destroy_entity(launcher)
    job.launcher = nil
    return false, "launcher inventories unavailable"
  end

  local gun_inserted = guns.insert { name = job.launcher_prototype, count = 1 }
  local ammo_inserted = ammo.insert(item_stack_definition(job.ammo_item_name, job.ammo_count or 1, job.item_quality))
  if gun_inserted < 1 or ammo_inserted < 1 then
    destroy_entity(launcher)
    job.launcher = nil
    return false, "launcher inventory insert failed"
  end

  local ok_selected = pcall(function() launcher.selected_gun_index = 1 end)
  local target_entity = is_valid_entity_reference(job.target) and job.target or nil
  if not ok_selected or not can_job_shoot(launcher, job, target_entity) then
    destroy_entity(launcher)
    job.launcher = nil
    return false, "launcher cannot shoot target"
  end

  if target_entity then pcall(function() launcher.selected = target_entity end) end
  local ok_shooting = pcall(function()
    launcher.shooting_state = {
      state = defines.shooting.shooting_selected,
      position = job.target_position,
    }
  end)
  if not ok_shooting then
    destroy_entity(launcher)
    job.launcher = nil
    return false, "shooting_state write failed"
  end

  if Debug.enabled() then
    Debug.log("[DETONATION][LAUNCHER][START] family=" .. tostring(job.family)
      .. " projectile=" .. tostring(job.projectile_name)
      .. " launcher=" .. tostring(job.launcher_prototype)
      .. " ammo=" .. tostring(job.ammo_category)
      .. " quality=" .. tostring(job.item_quality)
      .. " charges=" .. tostring(job.charge_count)
      .. " fire_ticks=" .. tostring(job.fire_ticks)
      .. " force=" .. tostring(job.force and job.force.name)
      .. " host=" .. describe_entity(launcher)
      .. " source=" .. describe_position(job.source_position)
      .. " target=" .. describe_target(job.target or job.target_position))
  end

  job.release_tick = game.tick + math.max(1, job.fire_ticks or DEFAULT_FIRE_TICKS)
  job.cleanup_tick = job.release_tick + math.max(1, job.cleanup_delay or DEFAULT_CLEANUP_TICKS)
  if job.family == Launcher.FAMILY_STREAM then
    job.next_retarget_tick = game.tick + STREAM_RETARGET_INTERVAL_TICKS
  end
  job.state = "firing"
  return true
end

function Launcher.process_jobs(event, fallback)
  local jobs = storage and storage.launcher_jobs
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
        maybe_retarget_stream(job, event.tick)
      end
    elseif job.state == "cleanup" and event.tick >= job.cleanup_tick then
      destroy_entity(job.launcher)
      table.remove(jobs, i)
    end
  end

  if #jobs == 0 then return end

  local starts_remaining = MAX_STARTS_PER_TICK
  local failed_indices
  for i = 1, #jobs do
    if starts_remaining <= 0 then break end
    local job = jobs[i]
    if job.state == "pending" and event.tick >= job.spawn_tick then
      local ok, reason = prepare_job(job)
      if ok then
        starts_remaining = starts_remaining - 1
      else
        fallback(job, reason)
        failed_indices = failed_indices or {}
        failed_indices[#failed_indices + 1] = i
      end
    end
  end

  if failed_indices then
    for i = #failed_indices, 1, -1 do
      table.remove(jobs, failed_indices[i])
    end
  end
end

return Launcher
