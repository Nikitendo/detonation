local CircuitDetonator = {}

local PROXY_ENTITY = "detonation-circuit-detonator-proxy"
local BLUEPRINT_TAG = "detonation-circuit-detonator"
local BLUEPRINT_TAG_VERSION = 1
local CIRCUIT_DETONATION_TECH = "detonation-circuit-detonation"
local CIRCUIT_DETONATION_SPRITE = "detonation-circuit-detonation-icon"
local CONTROLLED_CHEST_DETONATION_SETTING = "detonation-controlled-chest-detonation"

local GUI_FRAME = "detonation_circuit_detonator_frame"
local GUI_EXPAND = "detonation_circuit_detonator_expand"
local GUI_COLLAPSE = "detonation_circuit_detonator_collapse"
local GUI_CONDITION_SIGNAL = "detonation_circuit_detonator_condition_signal"
local GUI_CONDITION_COMPARATOR = "detonation_circuit_detonator_condition_comparator"
local GUI_CONDITION_SECOND_SIGNAL = "detonation_circuit_detonator_condition_second_signal"
local GUI_CONDITION_CONSTANT = "detonation_circuit_detonator_condition_constant"
local GUI_INPUT_RED = "detonation_circuit_detonator_input_red"
local GUI_INPUT_GREEN = "detonation_circuit_detonator_input_green"
local GUI_MIN_DISTANCE = "detonation_circuit_detonator_min_distance"
local GUI_DIRECTION_PREFIX = "detonation_circuit_detonator_direction_"
local GUI_APPLY = "detonation_circuit_detonator_apply"
local GUI_REMOVE = "detonation_circuit_detonator_remove"

local COMPARATORS = { ">", "<", "=", "≥", "≤", "≠" }
local DEFAULT_COMPARATOR = ">"
local DEFAULT_CONSTANT = 0
local DEFAULT_DIRECTIONAL_MIN_DISTANCE = 5
local DIRECTIONAL_CONE_ANGLE_DEGREES = 60

local DIRECTION_CHOICES = {
  { key = "north-west", sprite = "virtual-signal/up-left-arrow", x = -1, y = -1 },
  { key = "north", sprite = "virtual-signal/up-arrow", x = 0, y = -1 },
  { key = "north-east", sprite = "virtual-signal/up-right-arrow", x = 1, y = -1 },
  { key = "west", sprite = "virtual-signal/left-arrow", x = -1, y = 0 },
  { key = "none", sprite = "virtual-signal/signal-sun", x = 0, y = 0 },
  { key = "east", sprite = "virtual-signal/right-arrow", x = 1, y = 0 },
  { key = "south-west", sprite = "virtual-signal/down-left-arrow", x = -1, y = 1 },
  { key = "south", sprite = "virtual-signal/down-arrow", x = 0, y = 1 },
  { key = "south-east", sprite = "virtual-signal/down-right-arrow", x = 1, y = 1 },
}

local WIRE_CONNECTORS = {
  defines.wire_connector_id.circuit_red,
  defines.wire_connector_id.circuit_green,
}

local function ensure_storage()
  storage.circuit_detonators_by_chest = storage.circuit_detonators_by_chest or {}
  storage.circuit_detonators_by_proxy = storage.circuit_detonators_by_proxy or {}
  storage.circuit_detonator_gui_chest = storage.circuit_detonator_gui_chest or {}
  storage.circuit_detonator_gui_expanded = storage.circuit_detonator_gui_expanded or {}
  storage.circuit_detonator_forced_death_configs = storage.circuit_detonator_forced_death_configs or {}
  storage.circuit_detonator_pending_deaths = storage.circuit_detonator_pending_deaths or {}
  storage.circuit_detonator_pending_rebuilds = storage.circuit_detonator_pending_rebuilds or {}
  storage.circuit_detonator_pending_ghosts = storage.circuit_detonator_pending_ghosts or {}
  storage.circuit_detonator_condition_drafts = storage.circuit_detonator_condition_drafts or {}
  storage.circuit_detonator_pending_rearms = storage.circuit_detonator_pending_rearms or {}
  storage.circuit_detonator_input_network_version = storage.circuit_detonator_input_network_version or 0
end

local function get_player(player_index)
  if not player_index then return nil end
  return game.get_player(player_index)
end

local function controlled_chest_detonation_enabled()
  local setting = settings.startup[CONTROLLED_CHEST_DETONATION_SETTING]
  return not setting or setting.value ~= false
end

function CircuitDetonator.is_enabled()
  return controlled_chest_detonation_enabled()
end

local function get_chest_inventory(entity)
  if not (entity and entity.valid) then return nil end

  local ok, inventory = pcall(function()
    return entity.get_inventory(defines.inventory.chest)
  end)
  if ok and inventory and inventory.valid then return inventory end

  return nil
end

local function copy_table(value)
  if type(value) ~= "table" then return value end

  local result = {}
  for key, nested in pairs(value) do
    if key ~= "fulfilled" then
      result[key] = copy_table(nested)
    end
  end
  return result
end

local function normalize_comparator(comparator)
  if comparator == ">=" then return "≥" end
  if comparator == "<=" then return "≤" end
  if comparator == "!=" then return "≠" end

  for i = 1, #COMPARATORS do
    if comparator == COMPARATORS[i] then return comparator end
  end

  return DEFAULT_COMPARATOR
end

local function comparator_index(comparator)
  local normalized = normalize_comparator(comparator)
  for i = 1, #COMPARATORS do
    if COMPARATORS[i] == normalized then return i end
  end
  return 1
end

local function default_condition_draft()
  return {
    comparator = DEFAULT_COMPARATOR,
    constant = DEFAULT_CONSTANT,
    min_distance = DEFAULT_DIRECTIONAL_MIN_DISTANCE,
    input_red = true,
    input_green = false,
  }
end

local function normalize_constant(value)
  local number = tonumber(value)
  if not number then return DEFAULT_CONSTANT end
  return math.floor(number)
end

local function normalize_min_distance(value)
  local number = tonumber(value)
  if not number then return DEFAULT_DIRECTIONAL_MIN_DISTANCE end
  return math.max(0, math.floor(number))
end

local function normalize_direction(direction)
  if type(direction) ~= "table" then return nil end
  local x = tonumber(direction.x)
  local y = tonumber(direction.y)
  if not x or not y then return nil end
  x = x < 0 and -1 or (x > 0 and 1 or 0)
  y = y < 0 and -1 or (y > 0 and 1 or 0)
  if x == 0 and y == 0 then return nil end
  return { x = x, y = y }
end

local function direction_key(direction)
  local normalized = normalize_direction(direction)
  if not normalized then return "none" end
  for i = 1, #DIRECTION_CHOICES do
    local choice = DIRECTION_CHOICES[i]
    if choice.x == normalized.x and choice.y == normalized.y then return choice.key end
  end
  return "none"
end

local function direction_from_key(key)
  for i = 1, #DIRECTION_CHOICES do
    local choice = DIRECTION_CHOICES[i]
    if choice.key == key then return normalize_direction(choice) end
  end
  return nil
end

local function normalize_signal(signal)
  if type(signal) ~= "table" or type(signal.name) ~= "string" or signal.name == "" then return nil end
  return copy_table(signal)
end

local function normalize_condition_draft(draft)
  if type(draft) ~= "table" then return default_condition_draft() end

  return {
    first_signal = normalize_signal(draft.first_signal),
    comparator = normalize_comparator(draft.comparator),
    second_signal = normalize_signal(draft.second_signal),
    constant = normalize_constant(draft.constant),
    direction = normalize_direction(draft.direction),
    min_distance = normalize_min_distance(draft.min_distance),
    input_red = draft.input_red ~= false,
    input_green = draft.input_green == true,
  }
end

local function condition_draft_from_config(config)
  if not (config and config.circuit_condition) then return default_condition_draft() end

  local condition = config.circuit_condition
  return normalize_condition_draft {
    first_signal = condition.first_signal,
    comparator = condition.comparator,
    second_signal = condition.second_signal,
    constant = condition.constant,
    direction = config.emission_direction,
    min_distance = config.directional_min_distance,
    input_red = not config.input_networks or config.input_networks.red ~= false,
    input_green = config.input_networks and config.input_networks.green == true,
  }
end

local function config_from_condition_draft(draft)
  local normalized = normalize_condition_draft(draft)
  if not normalized.first_signal then return nil end

  local condition = {
    first_signal = copy_table(normalized.first_signal),
    comparator = normalized.comparator,
  }
  if normalized.second_signal then
    condition.second_signal = copy_table(normalized.second_signal)
  else
    condition.constant = normalized.constant
  end

  return {
    circuit_condition = {
      first_signal = condition.first_signal,
      comparator = condition.comparator,
      second_signal = condition.second_signal,
      constant = condition.constant,
    },
    emission_direction = copy_table(normalized.direction),
    directional_min_distance = normalized.min_distance,
    directional_cone_angle_degrees = DIRECTIONAL_CONE_ANGLE_DEGREES,
    circuit_enable_disable = true,
    input_networks = {
      red = normalized.input_red,
      green = normalized.input_green,
    },
  }
end

local function normalize_quality_name(entity_or_quality)
  if not entity_or_quality then return "normal" end

  local ok, quality = pcall(function()
    if entity_or_quality.quality then return entity_or_quality.quality.name end
    return nil
  end)
  if ok and type(quality) == "string" then return quality end

  local ok_object_name, object_name = pcall(function()
    return entity_or_quality.object_name
  end)
  if ok_object_name and object_name == "LuaQualityPrototype" then
    local ok_name, name = pcall(function()
      return entity_or_quality.name
    end)
    if ok_name and type(name) == "string" then return name end
  end

  return "normal"
end

local function force_name(force)
  if force and force.valid then return force.name end
  return ""
end

local function position_key(position)
  local x = math.floor((position.x or 0) * 256 + 0.5)
  local y = math.floor((position.y or 0) * 256 + 0.5)
  return tostring(x) .. "," .. tostring(y)
end

local function rebuild_key(surface_index, entity_name, position, owner_force_name, quality_name)
  return tostring(surface_index)
      .. "|" .. tostring(entity_name)
      .. "|" .. position_key(position)
      .. "|" .. tostring(owner_force_name or "")
      .. "|" .. tostring(quality_name or "normal")
end

local function rebuild_key_for_entity(entity)
  if not (entity and entity.valid) then return nil end
  return rebuild_key(
    entity.surface.index,
    entity.name,
    entity.position,
    force_name(entity.force),
    normalize_quality_name(entity)
  )
end

local function rebuild_key_for_ghost(ghost)
  if not (ghost and ghost.valid) then return nil end
  local ghost_name = nil
  pcall(function()
    ghost_name = ghost.ghost_name
  end)
  if type(ghost_name) ~= "string" then return nil end

  return rebuild_key(
    ghost.surface.index,
    ghost_name,
    ghost.position,
    force_name(ghost.force),
    normalize_quality_name(ghost)
  )
end

local function make_blueprint_tag(config)
  if not config then return nil end

  return {
    version = BLUEPRINT_TAG_VERSION,
    config = copy_table(config),
  }
end

local function config_from_blueprint_tags(tags)
  if type(tags) ~= "table" then return nil end
  local tag = tags[BLUEPRINT_TAG]
  if type(tag) ~= "table" then return nil end
  if tag.version ~= BLUEPRINT_TAG_VERSION then return nil end
  if type(tag.config) ~= "table" then return nil end

  return copy_table(tag.config)
end

local function capture_proxy_config(proxy)
  if not (proxy and proxy.valid) then return nil end

  local ok_behavior, behavior = pcall(function()
    return proxy.get_control_behavior()
  end)
  if not ok_behavior or not behavior then return {} end

  local config = {}

  local ok_condition, condition = pcall(function()
    return behavior.circuit_condition
  end)
  if ok_condition and condition then
    config.circuit_condition = copy_table(condition)
  end

  local ok_circuit_enable_disable, circuit_enable_disable = pcall(function()
    return behavior.circuit_enable_disable
  end)
  if ok_circuit_enable_disable then
    config.circuit_enable_disable = circuit_enable_disable == true
  end

  local ok_input_networks, input_networks = pcall(function()
    return behavior.input_networks
  end)
  if ok_input_networks and input_networks then
    config.input_networks = {
      red = input_networks.red ~= false,
      green = input_networks.green ~= false,
    }
  end

  return config
end

local function merge_stored_config(proxy_config, stored_config)
  local config = copy_table(proxy_config or {})
  if type(stored_config) ~= "table" then return config end

  config.emission_direction = copy_table(normalize_direction(stored_config.emission_direction))
  config.directional_min_distance = normalize_min_distance(stored_config.directional_min_distance)
  config.directional_cone_angle_degrees = DIRECTIONAL_CONE_ANGLE_DEGREES
  return config
end

local function capture_link_config(link)
  if not link then return nil end
  return merge_stored_config(capture_proxy_config(link.proxy), link.config)
end

local function apply_proxy_config(proxy, config)
  if not (proxy and proxy.valid and config) then return end

  local ok_behavior, behavior = pcall(function()
    return proxy.get_control_behavior()
  end)
  if not ok_behavior or not behavior then return end

  if config.input_networks then
    pcall(function()
      behavior.input_networks = {
        red = config.input_networks.red ~= false,
        green = config.input_networks.green == true,
      }
    end)
  end

  if config.circuit_condition then
    pcall(function()
      behavior.circuit_condition = copy_table(config.circuit_condition)
    end)
  end

  if config.circuit_enable_disable ~= nil then
    pcall(function()
      behavior.circuit_enable_disable = config.circuit_enable_disable == true
    end)
  end
end

function CircuitDetonator.is_supported_container(entity)
  if not (entity and entity.valid and entity.unit_number) then return false end
  if entity.name == PROXY_ENTITY then return false end
  if entity.type ~= "container" and entity.type ~= "logistic-container" then return false end
  return get_chest_inventory(entity) ~= nil
end

function CircuitDetonator.is_proxy(entity)
  return controlled_chest_detonation_enabled() and entity and entity.valid and entity.name == PROXY_ENTITY
end

local function get_link_by_chest_unit(chest_unit)
  ensure_storage()
  local link = storage.circuit_detonators_by_chest[chest_unit]
  if not link then return nil end

  local chest = link.chest
  local proxy = link.proxy
  if not (chest and chest.valid and proxy and proxy.valid) then
    storage.circuit_detonators_by_chest[chest_unit] = nil
    if link.proxy_unit then
      storage.circuit_detonators_by_proxy[link.proxy_unit] = nil
    end
    return nil
  end

  return link
end

local function get_link_for_chest(chest)
  if not (chest and chest.valid and chest.unit_number) then return nil end
  return get_link_by_chest_unit(chest.unit_number)
end

local remove_pending_rebuild_for_ghost

local function config_from_active_chest_detonator(chest)
  local link = get_link_for_chest(chest)
  if not link then return nil end
  return capture_link_config(link)
end

local function get_condition_draft_for_chest(chest)
  if not (chest and chest.valid and chest.unit_number) then return default_condition_draft() end
  ensure_storage()

  local stored = storage.circuit_detonator_condition_drafts[chest.unit_number]
  if stored then return normalize_condition_draft(stored) end

  local link = get_link_for_chest(chest)
  if link then
    return condition_draft_from_config(capture_link_config(link))
  end

  return default_condition_draft()
end

local function set_condition_draft_for_chest(chest, draft)
  if not (chest and chest.valid and chest.unit_number) then return end
  ensure_storage()
  storage.circuit_detonator_condition_drafts[chest.unit_number] = normalize_condition_draft(draft)
end

local function clear_condition_draft_for_chest_unit(chest_unit)
  if not chest_unit then return end
  ensure_storage()
  storage.circuit_detonator_condition_drafts[chest_unit] = nil
end

local function add_styled_button(parent, spec, style_names)
  if type(style_names) == "string" then style_names = { style_names } end
  if type(style_names) == "table" then
    for i = 1, #style_names do
      local styled_spec = copy_table(spec)
      styled_spec.style = style_names[i]
      local ok, element = pcall(function()
        return parent.add(styled_spec)
      end)
      if ok and element then return element end
    end
  end

  return parent.add(spec)
end

local function player_has_supported_container_opened(player)
  if not (player and player.valid) then return false end

  local ok, supported = pcall(function()
    return CircuitDetonator.is_supported_container(player.opened)
  end)

  return ok and supported == true
end

local function force_has_circuit_detonation(force)
  if not controlled_chest_detonation_enabled() then return false end
  if not (force and force.valid) then return false end

  local technologies = force.technologies
  local technology = technologies and technologies[CIRCUIT_DETONATION_TECH]
  return technology and technology.researched == true
end

local function player_has_circuit_detonation_unlocked(player)
  return player and player.valid and force_has_circuit_detonation(player.force)
end

local function connect_proxy_to_chest(chest, proxy)
  if not (chest and chest.valid and proxy and proxy.valid) then return end

  for i = 1, #WIRE_CONNECTORS do
    local connector_id = WIRE_CONNECTORS[i]
    local ok_chest, chest_connector = pcall(function()
      return chest.get_wire_connector(connector_id, true)
    end)
    local ok_proxy, proxy_connector = pcall(function()
      return proxy.get_wire_connector(connector_id, true)
    end)

    if ok_chest and ok_proxy and chest_connector and proxy_connector then
      local ok_connected, connected = pcall(function()
        return proxy_connector.is_connected_to(chest_connector, defines.wire_origin.script)
      end)
      if not ok_connected or not connected then
        pcall(function()
          proxy_connector.connect_to(chest_connector, false, defines.wire_origin.script)
        end)
      end
    end
  end
end

local function create_proxy(chest)
  local proxy = chest.surface.create_entity {
    name = PROXY_ENTITY,
    position = chest.position,
    force = chest.force,
    create_build_effect_smoke = false,
    raise_built = false,
  }

  if proxy and proxy.valid then
    proxy.destructible = true
    connect_proxy_to_chest(chest, proxy)
  end

  return proxy
end

function CircuitDetonator.ensure_for_chest(chest, config)
  if not controlled_chest_detonation_enabled() then return nil end
  if not CircuitDetonator.is_supported_container(chest) then return nil end
  ensure_storage()

  local existing = get_link_for_chest(chest)
  if existing then
    connect_proxy_to_chest(chest, existing.proxy)
    existing.config = merge_stored_config(config, config)
    apply_proxy_config(existing.proxy, config)
    return existing.proxy
  end

  local proxy = create_proxy(chest)
  if not (proxy and proxy.valid and proxy.unit_number) then return nil end

  storage.circuit_detonators_by_chest[chest.unit_number] = {
    chest = chest,
    chest_unit = chest.unit_number,
    proxy = proxy,
    proxy_unit = proxy.unit_number,
    config = merge_stored_config(config, config),
  }
  storage.circuit_detonators_by_proxy[proxy.unit_number] = chest.unit_number
  apply_proxy_config(proxy, config)

  return proxy
end

local function remove_link(chest_unit, destroy_proxy)
  ensure_storage()

  local link = storage.circuit_detonators_by_chest[chest_unit]
  if not link then return end

  storage.circuit_detonator_pending_rearms[chest_unit] = nil

  storage.circuit_detonators_by_chest[chest_unit] = nil
  if link.proxy_unit then
    storage.circuit_detonators_by_proxy[link.proxy_unit] = nil
  end

  if destroy_proxy and link.proxy and link.proxy.valid then
    pcall(function()
      link.proxy.destroy()
    end)
  end
end

function CircuitDetonator.remove_for_chest(chest)
  if not (chest and chest.valid and chest.unit_number) then return end
  remove_link(chest.unit_number, true)
end

function CircuitDetonator.cleanup_entity(entity)
  if not (entity and entity.valid) then return end
  if entity.type == "entity-ghost" then
    remove_pending_rebuild_for_ghost(entity)
    return
  end
  if not entity.unit_number then return end
  if CircuitDetonator.is_proxy(entity) then
    local chest_unit = storage.circuit_detonators_by_proxy
        and storage.circuit_detonators_by_proxy[entity.unit_number]
    if chest_unit then
      remove_link(chest_unit, false)
    end
    return
  end

  if CircuitDetonator.is_supported_container(entity) then
    local chest_unit = entity.unit_number
    remove_link(entity.unit_number, true)
    clear_condition_draft_for_chest_unit(chest_unit)
  end
end

function CircuitDetonator.take_chest_for_dead_proxy(proxy)
  if not controlled_chest_detonation_enabled() then return nil end
  if not CircuitDetonator.is_proxy(proxy) then return nil end
  ensure_storage()

  local proxy_unit = proxy.unit_number
  local chest_unit = proxy_unit and storage.circuit_detonators_by_proxy[proxy_unit]
  if not chest_unit then return nil end

  local link = storage.circuit_detonators_by_chest[chest_unit]
  local chest = link and link.chest or nil
  local config = link and capture_link_config(link) or nil
  remove_link(chest_unit, false)

  if chest and chest.valid and chest.unit_number and config then
    storage.circuit_detonator_forced_death_configs[chest.unit_number] = config
  end

  if chest and chest.valid then return chest, config end
  return nil, config
end

function CircuitDetonator.cancel_forced_container_death(chest)
  if not (chest and chest.valid and chest.unit_number) then return end
  ensure_storage()
  storage.circuit_detonator_forced_death_configs[chest.unit_number] = nil
end

function CircuitDetonator.schedule_rearm_after_condition_reset(chest, config)
  if not (chest and chest.valid and chest.unit_number and type(config) == "table") then return end
  ensure_storage()

  local dormant_config = copy_table(config)
  dormant_config.circuit_enable_disable = false
  local proxy = CircuitDetonator.ensure_for_chest(chest, dormant_config)
  if not (proxy and proxy.valid) then return end

  storage.circuit_detonator_pending_rearms[chest.unit_number] = {
    chest = chest,
    proxy = proxy,
    config = copy_table(config),
  }
end

function CircuitDetonator.has_pending_rearms()
  if not storage or not storage.circuit_detonator_pending_rearms then return false end
  return next(storage.circuit_detonator_pending_rearms) ~= nil
end

function CircuitDetonator.process_pending_rearms(tick, has_detonatable_contents)
  if not storage or not storage.circuit_detonator_pending_rearms then return end
  if (tick or 0) % 10 ~= 0 then return end

  for chest_unit, pending in pairs(storage.circuit_detonator_pending_rearms) do
    local chest = pending.chest
    local proxy = pending.proxy
    if not (chest and chest.valid and proxy and proxy.valid) then
      storage.circuit_detonator_pending_rearms[chest_unit] = nil
    else
      local ok, fulfilled = pcall(function()
        local behavior = proxy.get_control_behavior()
        local condition = behavior and behavior.circuit_condition
        return condition and condition.fulfilled == true
      end)

      local should_rearm = ok and fulfilled == false
      if ok and fulfilled == true and type(has_detonatable_contents) == "function" then
        local ok_payload, has_payload = pcall(has_detonatable_contents, chest)
        should_rearm = ok_payload and has_payload == true
      end

      if should_rearm then
        apply_proxy_config(proxy, pending.config)
        storage.circuit_detonator_pending_rearms[chest_unit] = nil
      end
    end
  end
end

local function remember_pending_death(entity, config, tick)
  if not (entity and entity.valid and config) then return end

  local pending = storage.circuit_detonator_pending_deaths
  pending[#pending + 1] = {
    tick = tick,
    surface_index = entity.surface.index,
    entity_name = entity.name,
    position_key = position_key(entity.position),
    force_name = force_name(entity.force),
    quality_name = normalize_quality_name(entity),
    config = config,
  }
end

function CircuitDetonator.prepare_container_death(entity, tick)
  if not controlled_chest_detonation_enabled() then return end
  if not CircuitDetonator.is_supported_container(entity) then return end
  ensure_storage()

  local config = storage.circuit_detonator_forced_death_configs[entity.unit_number]
  storage.circuit_detonator_forced_death_configs[entity.unit_number] = nil

  local link = get_link_for_chest(entity)
  if not config and link then
    config = capture_link_config(link)
  end

  if config then
    remember_pending_death(entity, config, tick)
  end

  local chest_unit = entity.unit_number
  remove_link(entity.unit_number, true)
  clear_condition_draft_for_chest_unit(chest_unit)
  return config
end

function CircuitDetonator.emit_options_from_config(config)
  if type(config) ~= "table" then return nil end
  local direction = normalize_direction(config.emission_direction)
  if not direction then return nil end

  return {
    direction = direction,
    min_distance = normalize_min_distance(config.directional_min_distance),
    cone_angle_degrees = DIRECTIONAL_CONE_ANGLE_DEGREES,
  }
end

function CircuitDetonator.get_chest_emit_options(chest)
  if not CircuitDetonator.is_supported_container(chest) then return nil end
  return CircuitDetonator.emit_options_from_config(config_from_active_chest_detonator(chest))
end

local function take_pending_death(event, surface_index)
  ensure_storage()

  local pending = storage.circuit_detonator_pending_deaths
  local event_position_key = position_key(event.position)
  local entity_name = event.prototype and event.prototype.name or nil
  local quality_name = normalize_quality_name(event.quality)

  for i = #pending, 1, -1 do
    local candidate = pending[i]
    if candidate.tick == event.tick
        and candidate.entity_name == entity_name
        and candidate.position_key == event_position_key
        and candidate.quality_name == quality_name
        and (not surface_index or candidate.surface_index == surface_index) then
      table.remove(pending, i)
      return candidate.config
    end
  end

  return nil
end

local function remove_pending_rebuild_key(key)
  if not key then return end
  ensure_storage()

  storage.circuit_detonator_pending_rebuilds[key] = nil

  local pending_ghosts = storage.circuit_detonator_pending_ghosts
  for ghost_unit, ghost_key in pairs(pending_ghosts) do
    if ghost_key == key then
      pending_ghosts[ghost_unit] = nil
    end
  end
end

remove_pending_rebuild_for_ghost = function(ghost)
  if not (ghost and ghost.valid) then return end
  ensure_storage()

  local key = nil
  if ghost.unit_number then
    key = storage.circuit_detonator_pending_ghosts[ghost.unit_number]
  end
  if not key then
    key = rebuild_key_for_ghost(ghost)
  end
  remove_pending_rebuild_key(key)
end

function CircuitDetonator.on_post_entity_died(event)
  if not controlled_chest_detonation_enabled() then return end
  local ghost = event.ghost
  local surface_index = ghost and ghost.valid and ghost.surface.index or nil
  local config = take_pending_death(event, surface_index)
  if not config then return end
  if not (ghost and ghost.valid and ghost.unit_number) then return end

  local key = rebuild_key(
    ghost.surface.index,
    event.prototype and event.prototype.name or ghost.ghost_name,
    ghost.position,
    force_name(ghost.force),
    normalize_quality_name(event.quality)
  )

  storage.circuit_detonator_pending_rebuilds[key] = config
  storage.circuit_detonator_pending_ghosts[ghost.unit_number] = key
end

local function apply_blueprint_config_to_chest(entity, tags)
  if not controlled_chest_detonation_enabled() then return false end
  if not CircuitDetonator.is_supported_container(entity) then return false end

  local config = config_from_blueprint_tags(tags)
  if not config then return false end

  set_condition_draft_for_chest(entity, condition_draft_from_config(config))
  CircuitDetonator.ensure_for_chest(entity, config)
  return true
end

function CircuitDetonator.restore_for_built_entity(entity, tags)
  if not controlled_chest_detonation_enabled() then return end
  if not CircuitDetonator.is_supported_container(entity) then return end
  ensure_storage()

  if apply_blueprint_config_to_chest(entity, tags) then return end

  local key = rebuild_key_for_entity(entity)
  local config = key and storage.circuit_detonator_pending_rebuilds[key]
  if not config then return end

  remove_pending_rebuild_key(key)
  CircuitDetonator.ensure_for_chest(entity, config)
end

function CircuitDetonator.on_player_setup_blueprint(event)
  if not controlled_chest_detonation_enabled() then return end
  local blueprint = event.stack or event.record
  if not blueprint then return end

  local ok_setup, is_setup = pcall(function()
    return blueprint.is_blueprint_setup()
  end)
  if not ok_setup or not is_setup then return end

  local mapping_value = event.mapping
  if not mapping_value then return end

  local ok_mapping, mapping = pcall(function()
    return mapping_value.get()
  end)
  if not ok_mapping or type(mapping) ~= "table" then return end

  for blueprint_entity_index, source_entity in pairs(mapping) do
    if CircuitDetonator.is_supported_container(source_entity) then
      local config = config_from_active_chest_detonator(source_entity)
      local tag = make_blueprint_tag(config)
      if tag then
        pcall(function()
          blueprint.set_blueprint_entity_tag(blueprint_entity_index, BLUEPRINT_TAG, tag)
        end)
      end
    end
  end
end

function CircuitDetonator.on_entity_settings_pasted(event)
  if not controlled_chest_detonation_enabled() then return end
  local source = event.source
  local destination = event.destination
  if not CircuitDetonator.is_supported_container(source) then return end
  if not CircuitDetonator.is_supported_container(destination) then return end
  ensure_storage()

  local source_link = get_link_for_chest(source)
  if not source_link then return end

  local config = capture_link_config(source_link)
  if not config then return end

  set_condition_draft_for_chest(destination, condition_draft_from_config(config))
  CircuitDetonator.ensure_for_chest(destination, config)

  for _, player in pairs(game.players) do
    if player.valid and storage.circuit_detonator_gui_chest[player.index] == destination.unit_number then
      CircuitDetonator.build_gui(player, destination, storage.circuit_detonator_gui_expanded[player.index] == true)
    end
  end
end

function CircuitDetonator.on_blueprint_settings_pasted(event)
  if not controlled_chest_detonation_enabled() then return end
  local entity = event.entity
  if not (entity and entity.valid) then return end

  local tags = event.tags
  if not tags then
    pcall(function()
      tags = entity.tags
    end)
  end

  apply_blueprint_config_to_chest(entity, tags)
end

function CircuitDetonator.on_pre_ghost_deconstructed(event)
  if not controlled_chest_detonation_enabled() then return end
  remove_pending_rebuild_for_ghost(event.ghost or event.entity)
end

local function destroy_gui(player)
  if not (player and player.valid) then return end
  if player.gui.relative[GUI_FRAME] then
    player.gui.relative[GUI_FRAME].destroy()
  end
  if player.gui.relative[GUI_EXPAND] then
    player.gui.relative[GUI_EXPAND].destroy()
  end
end

function CircuitDetonator.destroy_gui(player)
  destroy_gui(player)
end

local function add_gui_section(parent, caption)
  local section = parent.add {
    type = "frame",
    style = "detonation_section_frame",
    direction = "vertical",
  }
  pcall(function()
    section.style.horizontally_stretchable = true
    section.style.bottom_margin = 8
  end)

  local header = section.add {
    type = "frame",
    style = "subheader_frame",
  }
  pcall(function()
    header.style.horizontally_stretchable = true
  end)
  header.add {
    type = "label",
    caption = caption,
    style = "subheader_caption_label",
  }

  local content = section.add {
    type = "flow",
    style = "detonation_section_content_flow",
    direction = "vertical",
  }
  pcall(function()
    content.style.horizontally_stretchable = true
  end)

  return content, header
end

function CircuitDetonator.build_gui(player, chest, expanded)
  if not (player and player.valid and CircuitDetonator.is_supported_container(chest)) then return end
  if not controlled_chest_detonation_enabled() then
    destroy_gui(player)
    return
  end
  if not player_has_circuit_detonation_unlocked(player) then
    destroy_gui(player)
    return
  end
  ensure_storage()
  destroy_gui(player)

  if not expanded then
    local expand = player.gui.relative.add {
      type = "sprite-button",
      name = GUI_EXPAND,
      sprite = CIRCUIT_DETONATION_SPRITE,
      tooltip = { "detonation-gui.circuit-detonator-open-tooltip" },
      tags = { chest_unit = chest.unit_number },
      anchor = {
        gui = defines.relative_gui_type.container_gui,
        position = defines.relative_gui_position.right,
      },
    }
    pcall(function()
      expand.style.size = 40
    end)

    storage.circuit_detonator_gui_chest[player.index] = chest.unit_number
    storage.circuit_detonator_gui_expanded[player.index] = false
    return
  end

  local draft = get_condition_draft_for_chest(chest)
  local frame = player.gui.relative.add {
    type = "frame",
    name = GUI_FRAME,
    direction = "vertical",
    anchor = {
      gui = defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right,
    },
  }
  pcall(function()
    frame.style.minimal_width = 0
    frame.style.maximal_width = 260
  end)

  local titlebar = frame.add {
    type = "flow",
    direction = "horizontal",
  }
  pcall(function()
    titlebar.style.horizontal_spacing = 8
    titlebar.style.bottom_margin = 4
    titlebar.style.horizontally_stretchable = true
  end)

  local title = titlebar.add {
    type = "label",
    caption = { "detonation-gui.circuit-detonator-title" },
    style = "frame_title",
  }
  pcall(function()
    title.style.right_margin = 8
  end)

  local title_spacer = titlebar.add {
    type = "empty-widget",
  }
  pcall(function()
    title_spacer.style.horizontally_stretchable = true
    title_spacer.style.height = 24
  end)

  local collapse = titlebar.add {
    type = "sprite-button",
    name = GUI_COLLAPSE,
    sprite = "utility/close",
    style = "frame_action_button",
    tooltip = { "detonation-gui.circuit-detonator-close-tooltip" },
    tags = { chest_unit = chest.unit_number },
  }
  pcall(function()
    collapse.style.horizontal_align = "right"
  end)

  local condition_content, condition_header = add_gui_section(
    frame,
    { "detonation-gui.circuit-detonator-condition" }
  )
  local input_spacer = condition_header.add { type = "empty-widget" }
  pcall(function()
    input_spacer.style.horizontally_stretchable = true
  end)
  condition_header.add {
    type = "checkbox",
    name = GUI_INPUT_RED,
    caption = "R",
    state = draft.input_red,
    tooltip = { "detonation-gui.circuit-detonator-input-red-tooltip" },
    tags = { chest_unit = chest.unit_number },
  }
  condition_header.add {
    type = "checkbox",
    name = GUI_INPUT_GREEN,
    caption = "G",
    state = draft.input_green,
    tooltip = { "detonation-gui.circuit-detonator-input-green-tooltip" },
    tags = { chest_unit = chest.unit_number },
  }

  local condition_table = condition_content.add {
    type = "table",
    column_count = 4,
  }
  pcall(function()
    condition_table.style.horizontal_spacing = 8
    condition_table.style.vertical_spacing = 4
  end)

  local signal = condition_table.add {
    type = "choose-elem-button",
    name = GUI_CONDITION_SIGNAL,
    elem_type = "signal",
    tags = { chest_unit = chest.unit_number },
  }
  pcall(function()
    signal.style.size = 40
  end)
  if draft.first_signal then
    pcall(function()
      signal.elem_value = copy_table(draft.first_signal)
    end)
  end

  local comparator = condition_table.add {
    type = "drop-down",
    name = GUI_CONDITION_COMPARATOR,
    items = COMPARATORS,
    selected_index = comparator_index(draft.comparator),
    tags = { chest_unit = chest.unit_number },
  }
  pcall(function()
    comparator.style.width = 56
    comparator.style.height = 40
  end)

  local second_signal = condition_table.add {
    type = "choose-elem-button",
    name = GUI_CONDITION_SECOND_SIGNAL,
    elem_type = "signal",
    tooltip = { "detonation-gui.circuit-detonator-second-signal-tooltip" },
    tags = { chest_unit = chest.unit_number },
  }
  pcall(function()
    second_signal.style.size = 40
  end)
  if draft.second_signal then
    pcall(function()
      second_signal.elem_value = copy_table(draft.second_signal)
    end)
  end

  local constant = condition_table.add {
    type = "textfield",
    name = GUI_CONDITION_CONSTANT,
    text = tostring(normalize_constant(draft.constant)),
    numeric = true,
    allow_decimal = false,
    allow_negative = true,
    tags = { chest_unit = chest.unit_number },
  }
  pcall(function()
    constant.style.width = 56
    constant.style.height = 40
  end)
  if draft.second_signal then
    pcall(function()
      constant.enabled = false
    end)
  end

  local direction_content = add_gui_section(frame, { "detonation-gui.circuit-detonator-direction" })

  local direction_flow = direction_content.add {
    type = "flow",
    direction = "vertical",
  }
  pcall(function()
    direction_flow.style.top_margin = 4
    direction_flow.style.vertical_spacing = 4
  end)

  local direction_table = direction_flow.add {
    type = "table",
    column_count = 3,
    style = "detonation_direction_table",
  }

  local selected_direction_key = direction_key(draft.direction)
  for i = 1, #DIRECTION_CHOICES do
    local choice = DIRECTION_CHOICES[i]
    local direction_button = add_styled_button(direction_table, {
      type = "sprite-button",
      name = GUI_DIRECTION_PREFIX .. choice.key,
      sprite = choice.sprite,
      tooltip = { "detonation-gui.circuit-detonator-direction-tooltip" },
      tags = { chest_unit = chest.unit_number },
    }, { "slot_button", "button" })
    pcall(function()
      direction_button.style.size = 40
      direction_button.toggled = choice.key == selected_direction_key
    end)
  end

  local min_distance_flow = direction_flow.add {
    type = "flow",
    direction = "horizontal",
  }
  min_distance_flow.add {
    type = "label",
    caption = { "detonation-gui.circuit-detonator-min-distance" },
    style = "heading_2_label",
  }
  pcall(function()
    min_distance_flow.style.horizontal_spacing = 8
    min_distance_flow.style.vertical_align = "center"
  end)
  local min_distance = min_distance_flow.add {
    type = "textfield",
    name = GUI_MIN_DISTANCE,
    text = tostring(normalize_min_distance(draft.min_distance)),
    numeric = true,
    allow_decimal = false,
    allow_negative = false,
    tags = { chest_unit = chest.unit_number },
  }
  pcall(function()
    min_distance.style.width = 56
  end)

  local buttons = frame.add {
    type = "flow",
    direction = "vertical",
  }
  pcall(function()
    buttons.style.top_margin = 8
    buttons.style.vertical_spacing = 4
  end)

  local apply = add_styled_button(buttons, {
    type = "button",
    name = GUI_APPLY,
    caption = { "detonation-gui.circuit-detonator-apply-short" },
    tooltip = { "detonation-gui.circuit-detonator-apply" },
    tags = { chest_unit = chest.unit_number },
  }, { "detonation_green_button", "green_button", "confirm_button" })
  pcall(function()
    apply.style.horizontally_stretchable = true
  end)

  local remove = add_styled_button(buttons, {
    type = "button",
    name = GUI_REMOVE,
    caption = { "detonation-gui.circuit-detonator-remove-short" },
    tooltip = { "detonation-gui.circuit-detonator-remove-detonator" },
    tags = { chest_unit = chest.unit_number },
  }, { "red_button" })
  pcall(function()
    remove.style.horizontally_stretchable = true
  end)

  storage.circuit_detonator_gui_chest[player.index] = chest.unit_number
  storage.circuit_detonator_gui_expanded[player.index] = true
end

local function find_chest_by_unit(unit_number)
  ensure_storage()
  local link = get_link_by_chest_unit(unit_number)
  if link then return link.chest end

  -- If the chest is not armed yet, the GUI event still needs the currently
  -- opened entity. The unit number stored in button tags is only a guard.
  for _, player in pairs(game.players) do
    local opened = player.opened
    local ok, opened_unit = pcall(function()
      if opened and opened.valid then return opened.unit_number end
      return nil
    end)
    if ok and opened_unit == unit_number then
      return opened
    end
  end

  return nil
end

local function chest_from_gui_event(event)
  local element = event.element
  if not (element and element.valid) then return nil end
  local tags = element.tags or {}
  local chest_unit = tags.chest_unit
  if not chest_unit then
    local player = get_player(event.player_index)
    chest_unit = player and storage.circuit_detonator_gui_chest
        and storage.circuit_detonator_gui_chest[player.index]
  end
  if not chest_unit then return nil end

  local chest = find_chest_by_unit(chest_unit)
  if CircuitDetonator.is_supported_container(chest) then return chest end
  return nil
end

local function direction_key_from_gui_name(name)
  if type(name) ~= "string" then return nil end
  if string.sub(name, 1, #GUI_DIRECTION_PREFIX) ~= GUI_DIRECTION_PREFIX then return nil end
  return string.sub(name, #GUI_DIRECTION_PREFIX + 1)
end

function CircuitDetonator.on_gui_opened(event)
  local player = get_player(event.player_index)
  if not player then return end
  if not controlled_chest_detonation_enabled() then
    destroy_gui(player)
    return
  end

  local entity = event.entity
  if CircuitDetonator.is_supported_container(entity) then
    destroy_gui(player)
    ensure_storage()
    if storage.circuit_detonator_gui_expanded[player.index] == nil then
      storage.circuit_detonator_gui_expanded[player.index] = true
    end
    CircuitDetonator.build_gui(player, entity, storage.circuit_detonator_gui_expanded[player.index] == true)
    return
  end

  if player_has_supported_container_opened(player) then return end
  destroy_gui(player)
end

function CircuitDetonator.on_gui_closed(event)
  local player = get_player(event.player_index)
  if not player then return end

  if player_has_supported_container_opened(player) then return end

  destroy_gui(player)
  if storage.circuit_detonator_gui_chest then
    storage.circuit_detonator_gui_chest[player.index] = nil
  end
end

function CircuitDetonator.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local name = element.name
  local clicked_direction_key = direction_key_from_gui_name(name)
  if name ~= GUI_EXPAND
      and name ~= GUI_COLLAPSE
      and name ~= GUI_APPLY
      and name ~= GUI_REMOVE
      and not clicked_direction_key then
    return false
  end
  if not controlled_chest_detonation_enabled() then return true end

  local player = get_player(event.player_index)
  if not player then return true end

  local chest = chest_from_gui_event(event)
  if not chest then
    player.print({ "detonation-message.circuit-detonator-no-chest" })
    return true
  end

  if name == GUI_EXPAND then
    ensure_storage()
    storage.circuit_detonator_gui_expanded[player.index] = true
    CircuitDetonator.build_gui(player, chest, true)
    return true
  end

  if name == GUI_COLLAPSE then
    ensure_storage()
    storage.circuit_detonator_gui_expanded[player.index] = false
    CircuitDetonator.build_gui(player, chest, false)
    return true
  end

  if clicked_direction_key then
    local draft = get_condition_draft_for_chest(chest)
    draft.direction = direction_from_key(clicked_direction_key)
    set_condition_draft_for_chest(chest, draft)
    CircuitDetonator.build_gui(player, chest, true)
    return true
  end

  if name == GUI_REMOVE then
    CircuitDetonator.remove_for_chest(chest)
    CircuitDetonator.build_gui(player, chest, true)
    return true
  end

  local config = config_from_condition_draft(get_condition_draft_for_chest(chest))
  if not config then
    player.print({ "detonation-message.circuit-detonator-condition-missing-signal" })
    return true
  end

  local proxy = CircuitDetonator.ensure_for_chest(chest, config)
  if not (proxy and proxy.valid) then
    player.print({ "detonation-message.circuit-detonator-create-failed" })
    return true
  end

  player.print({ "detonation-message.circuit-detonator-condition-applied" })
  CircuitDetonator.build_gui(player, chest, true)

  return true
end

local function update_condition_draft_from_gui_event(event)
  if not controlled_chest_detonation_enabled() then return false end
  local element = event.element
  if not (element and element.valid) then return false end
  local name = element.name
  if name ~= GUI_CONDITION_SIGNAL
      and name ~= GUI_CONDITION_COMPARATOR
      and name ~= GUI_CONDITION_SECOND_SIGNAL
      and name ~= GUI_CONDITION_CONSTANT
      and name ~= GUI_MIN_DISTANCE then
    return false
  end

  local chest = chest_from_gui_event(event)
  if not chest then return true end

  local draft = get_condition_draft_for_chest(chest)
  if name == GUI_CONDITION_SIGNAL then
    draft.first_signal = normalize_signal(element.elem_value)
  elseif name == GUI_CONDITION_COMPARATOR then
    draft.comparator = COMPARATORS[element.selected_index] or DEFAULT_COMPARATOR
  elseif name == GUI_CONDITION_SECOND_SIGNAL then
    draft.second_signal = normalize_signal(element.elem_value)
    if element.parent and element.parent.valid then
      local constant = element.parent[GUI_CONDITION_CONSTANT]
      if constant and constant.valid then
        pcall(function()
          constant.enabled = draft.second_signal == nil
        end)
      end
    end
  elseif name == GUI_CONDITION_CONSTANT then
    draft.constant = normalize_constant(element.text)
  elseif name == GUI_MIN_DISTANCE then
    draft.min_distance = normalize_min_distance(element.text)
  end

  set_condition_draft_for_chest(chest, draft)
  return true
end

function CircuitDetonator.on_gui_elem_changed(event)
  return update_condition_draft_from_gui_event(event)
end

function CircuitDetonator.on_gui_selection_state_changed(event)
  return update_condition_draft_from_gui_event(event)
end

function CircuitDetonator.on_gui_text_changed(event)
  return update_condition_draft_from_gui_event(event)
end

function CircuitDetonator.on_gui_checked_state_changed(event)
  if not controlled_chest_detonation_enabled() then return false end
  local element = event.element
  if not (element and element.valid) then return false end
  if element.name ~= GUI_INPUT_RED and element.name ~= GUI_INPUT_GREEN then return false end

  local chest = chest_from_gui_event(event)
  if not chest then return true end
  local draft = get_condition_draft_for_chest(chest)
  if element.name == GUI_INPUT_RED then
    draft.input_red = element.state == true
  else
    draft.input_green = element.state == true
  end
  set_condition_draft_for_chest(chest, draft)
  return true
end

function CircuitDetonator.arm_selected(player)
  if not controlled_chest_detonation_enabled() then
    if player then player.print({ "detonation-message.circuit-detonator-disabled" }) end
    return
  end
  if not (player and player.valid and CircuitDetonator.is_supported_container(player.selected)) then
    if player then player.print({ "detonation-message.circuit-detonator-select-chest" }) end
    return
  end

  local proxy = CircuitDetonator.ensure_for_chest(player.selected)
  if proxy and proxy.valid then
    player.print({ "detonation-message.circuit-detonator-created" })
  else
    player.print({ "detonation-message.circuit-detonator-create-failed" })
  end
end

function CircuitDetonator.open_selected(player)
  if not controlled_chest_detonation_enabled() then
    if player then player.print({ "detonation-message.circuit-detonator-disabled" }) end
    return
  end
  if not (player and player.valid and CircuitDetonator.is_supported_container(player.selected)) then
    if player then player.print({ "detonation-message.circuit-detonator-select-chest" }) end
    return
  end

  local proxy = CircuitDetonator.ensure_for_chest(player.selected)
  if proxy and proxy.valid then
    player.opened = proxy
  else
    player.print({ "detonation-message.circuit-detonator-create-failed" })
  end
end

function CircuitDetonator.remove_selected(player)
  if not controlled_chest_detonation_enabled() then
    if player then player.print({ "detonation-message.circuit-detonator-disabled" }) end
    return
  end
  if not (player and player.valid and CircuitDetonator.is_supported_container(player.selected)) then
    if player then player.print({ "detonation-message.circuit-detonator-select-chest" }) end
    return
  end

  CircuitDetonator.remove_for_chest(player.selected)
  player.print({ "detonation-message.circuit-detonator-removed" })
end

function CircuitDetonator.audit_proxy_mines()
  ensure_storage()

  local report = {
    total = 0,
    linked = 0,
    orphaned = 0,
    stale_chest_links = 0,
    stale_proxy_links = 0,
    orphaned_examples = {},
  }
  if not controlled_chest_detonation_enabled() then return report end
  local seen_proxy_units = {}

  for _, surface in pairs(game.surfaces) do
    local proxies = surface.find_entities_filtered { name = PROXY_ENTITY }
    for i = 1, #proxies do
      local proxy = proxies[i]
      report.total = report.total + 1

      local proxy_unit = proxy.unit_number
      if proxy_unit then
        seen_proxy_units[proxy_unit] = true
      end

      local chest_unit = proxy_unit and storage.circuit_detonators_by_proxy[proxy_unit]
      local link = chest_unit and storage.circuit_detonators_by_chest[chest_unit]
      local linked = link
          and link.chest
          and link.chest.valid
          and link.proxy
          and link.proxy.valid
          and link.proxy.unit_number == proxy_unit
          and link.proxy_unit == proxy_unit
          and link.chest_unit == chest_unit

      if linked then
        report.linked = report.linked + 1
      else
        report.orphaned = report.orphaned + 1
        if #report.orphaned_examples < 10 then
          report.orphaned_examples[#report.orphaned_examples + 1] = {
            surface = surface.name,
            x = proxy.position.x,
            y = proxy.position.y,
            unit_number = proxy_unit,
            chest_unit = chest_unit,
          }
        end
      end
    end
  end

  for chest_unit, link in pairs(storage.circuit_detonators_by_chest) do
    if not (link
        and link.chest
        and link.chest.valid
        and link.proxy
        and link.proxy.valid
        and link.proxy_unit
        and seen_proxy_units[link.proxy_unit]) then
      report.stale_chest_links = report.stale_chest_links + 1
    end
  end

  for proxy_unit, chest_unit in pairs(storage.circuit_detonators_by_proxy) do
    local link = storage.circuit_detonators_by_chest[chest_unit]
    if not (seen_proxy_units[proxy_unit]
        and link
        and link.chest
        and link.chest.valid
        and link.proxy
        and link.proxy.valid
        and link.proxy.unit_number == proxy_unit) then
      report.stale_proxy_links = report.stale_proxy_links + 1
    end
  end

  return report
end

function CircuitDetonator.initialize_storage()
  ensure_storage()
  if controlled_chest_detonation_enabled() then
    local migrate_input_networks = storage.circuit_detonator_input_network_version < 1
    for _, link in pairs(storage.circuit_detonators_by_chest) do
      if link and link.chest and link.chest.valid and link.proxy and link.proxy.valid then
        connect_proxy_to_chest(link.chest, link.proxy)
        if migrate_input_networks then
          link.config = link.config or {}
          link.config.input_networks = { red = true, green = false }
          local behavior = link.proxy.get_control_behavior()
          if behavior then
            behavior.input_networks = { red = true, green = false }
          end
        end
      end
    end
    storage.circuit_detonator_input_network_version = 1
    return
  end

  if game and game.surfaces then
    for _, surface in pairs(game.surfaces) do
      local ok, proxies = pcall(function()
        return surface.find_entities_filtered { name = PROXY_ENTITY }
      end)
      if ok and proxies then
        for i = 1, #proxies do
          local proxy = proxies[i]
          if proxy and proxy.valid then
            pcall(function()
              proxy.destroy()
            end)
          end
        end
      end
    end
  end

  if game and game.players then
    for _, player in pairs(game.players) do
      destroy_gui(player)
    end
  end

  storage.circuit_detonators_by_chest = {}
  storage.circuit_detonators_by_proxy = {}
  storage.circuit_detonator_forced_death_configs = {}
  storage.circuit_detonator_pending_deaths = {}
  storage.circuit_detonator_pending_rebuilds = {}
  storage.circuit_detonator_pending_ghosts = {}
  storage.circuit_detonator_condition_drafts = {}
  storage.circuit_detonator_pending_rearms = {}
end

return CircuitDetonator
