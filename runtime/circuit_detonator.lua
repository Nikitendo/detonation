local CircuitDetonator = {}

local PROXY_ENTITY = "detonation-circuit-detonator-proxy"

local GUI_FRAME = "detonation_circuit_detonator_frame"
local GUI_STATUS = "detonation_circuit_detonator_status"
local GUI_ARM = "detonation_circuit_detonator_arm"
local GUI_OPEN = "detonation_circuit_detonator_open"
local GUI_REMOVE = "detonation_circuit_detonator_remove"

local WIRE_CONNECTORS = {
  defines.wire_connector_id.circuit_red,
  defines.wire_connector_id.circuit_green,
}

local function ensure_storage()
  storage.circuit_detonators_by_chest = storage.circuit_detonators_by_chest or {}
  storage.circuit_detonators_by_proxy = storage.circuit_detonators_by_proxy or {}
  storage.circuit_detonator_gui_chest = storage.circuit_detonator_gui_chest or {}
  storage.circuit_detonator_forced_death_configs = storage.circuit_detonator_forced_death_configs or {}
  storage.circuit_detonator_pending_deaths = storage.circuit_detonator_pending_deaths or {}
  storage.circuit_detonator_pending_rebuilds = storage.circuit_detonator_pending_rebuilds or {}
  storage.circuit_detonator_pending_ghosts = storage.circuit_detonator_pending_ghosts or {}
end

local function get_player(player_index)
  if not player_index then return nil end
  return game.get_player(player_index)
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
        green = config.input_networks.green ~= false,
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
  return entity and entity.valid and entity.name == PROXY_ENTITY
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
  if not CircuitDetonator.is_supported_container(chest) then return nil end
  ensure_storage()

  local existing = get_link_for_chest(chest)
  if existing then
    connect_proxy_to_chest(chest, existing.proxy)
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
  }
  storage.circuit_detonators_by_proxy[proxy.unit_number] = chest.unit_number
  apply_proxy_config(proxy, config)

  return proxy
end

local function remove_link(chest_unit, destroy_proxy)
  ensure_storage()

  local link = storage.circuit_detonators_by_chest[chest_unit]
  if not link then return end

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
  if not (entity and entity.valid and entity.unit_number) then return end
  if CircuitDetonator.is_proxy(entity) then
    local chest_unit = storage.circuit_detonators_by_proxy
        and storage.circuit_detonators_by_proxy[entity.unit_number]
    if chest_unit then
      remove_link(chest_unit, false)
    end
    return
  end

  if CircuitDetonator.is_supported_container(entity) then
    remove_link(entity.unit_number, true)
  end
end

function CircuitDetonator.take_chest_for_dead_proxy(proxy)
  if not CircuitDetonator.is_proxy(proxy) then return nil end
  ensure_storage()

  local proxy_unit = proxy.unit_number
  local chest_unit = proxy_unit and storage.circuit_detonators_by_proxy[proxy_unit]
  if not chest_unit then return nil end

  local link = storage.circuit_detonators_by_chest[chest_unit]
  local chest = link and link.chest or nil
  local config = link and capture_proxy_config(link.proxy) or nil
  remove_link(chest_unit, false)

  if chest and chest.valid and chest.unit_number and config then
    storage.circuit_detonator_forced_death_configs[chest.unit_number] = config
  end

  if chest and chest.valid then return chest end
  return nil
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
  if not CircuitDetonator.is_supported_container(entity) then return end
  ensure_storage()

  local config = storage.circuit_detonator_forced_death_configs[entity.unit_number]
  storage.circuit_detonator_forced_death_configs[entity.unit_number] = nil

  local link = get_link_for_chest(entity)
  if not config and link then
    config = capture_proxy_config(link.proxy)
  end

  if config then
    remember_pending_death(entity, config, tick)
  end

  remove_link(entity.unit_number, true)
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

function CircuitDetonator.on_post_entity_died(event)
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

function CircuitDetonator.restore_for_built_entity(entity)
  if not CircuitDetonator.is_supported_container(entity) then return end
  ensure_storage()

  local key = rebuild_key_for_entity(entity)
  local config = key and storage.circuit_detonator_pending_rebuilds[key]
  if not config then return end

  remove_pending_rebuild_key(key)
  CircuitDetonator.ensure_for_chest(entity, config)
end

function CircuitDetonator.on_pre_ghost_deconstructed(event)
  local ghost = event.ghost
  if not (ghost and ghost.valid and ghost.unit_number) then return end
  ensure_storage()

  local key = storage.circuit_detonator_pending_ghosts[ghost.unit_number]
  remove_pending_rebuild_key(key)
end

local function destroy_gui(player)
  if not (player and player.valid) then return end
  if player.gui.relative[GUI_FRAME] then
    player.gui.relative[GUI_FRAME].destroy()
  end
end

function CircuitDetonator.destroy_gui(player)
  destroy_gui(player)
end

local function update_gui_status(frame, chest)
  if not (frame and frame.valid) then return end
  local status = frame[GUI_STATUS]
  if not status then return end

  if get_link_for_chest(chest) then
    status.caption = { "detonation-gui.circuit-detonator-armed" }
  else
    status.caption = { "detonation-gui.circuit-detonator-not-armed" }
  end
end

function CircuitDetonator.build_gui(player, chest)
  if not (player and player.valid and CircuitDetonator.is_supported_container(chest)) then return end
  ensure_storage()
  destroy_gui(player)

  local frame = player.gui.relative.add {
    type = "frame",
    name = GUI_FRAME,
    direction = "vertical",
    caption = { "detonation-gui.circuit-detonator-title" },
    anchor = {
      gui = defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right,
    },
  }

  frame.add {
    type = "label",
    name = GUI_STATUS,
    caption = "",
  }

  local flow = frame.add {
    type = "flow",
    direction = "horizontal",
  }

  flow.add {
    type = "button",
    name = GUI_ARM,
    caption = { "detonation-gui.circuit-detonator-create" },
    tags = { chest_unit = chest.unit_number },
  }
  flow.add {
    type = "button",
    name = GUI_OPEN,
    caption = { "detonation-gui.circuit-detonator-open" },
    tags = { chest_unit = chest.unit_number },
  }
  flow.add {
    type = "button",
    name = GUI_REMOVE,
    caption = { "detonation-gui.circuit-detonator-remove" },
    tags = { chest_unit = chest.unit_number },
  }

  storage.circuit_detonator_gui_chest[player.index] = chest.unit_number
  update_gui_status(frame, chest)
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

function CircuitDetonator.on_gui_opened(event)
  local player = get_player(event.player_index)
  if not player then return end
  destroy_gui(player)

  local entity = event.entity
  if CircuitDetonator.is_supported_container(entity) then
    CircuitDetonator.build_gui(player, entity)
  end
end

function CircuitDetonator.on_gui_closed(event)
  local player = get_player(event.player_index)
  if not player then return end
  destroy_gui(player)
  if storage.circuit_detonator_gui_chest then
    storage.circuit_detonator_gui_chest[player.index] = nil
  end
end

function CircuitDetonator.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local name = element.name
  if name ~= GUI_ARM and name ~= GUI_OPEN and name ~= GUI_REMOVE then return false end

  local player = get_player(event.player_index)
  if not player then return true end

  local chest = chest_from_gui_event(event)
  if not chest then
    player.print({ "detonation-message.circuit-detonator-no-chest" })
    return true
  end

  if name == GUI_REMOVE then
    CircuitDetonator.remove_for_chest(chest)
    CircuitDetonator.build_gui(player, chest)
    return true
  end

  local proxy = CircuitDetonator.ensure_for_chest(chest)
  if not (proxy and proxy.valid) then
    player.print({ "detonation-message.circuit-detonator-create-failed" })
    return true
  end

  if name == GUI_OPEN then
    destroy_gui(player)
    player.opened = proxy
  else
    CircuitDetonator.build_gui(player, chest)
  end

  return true
end

function CircuitDetonator.arm_selected(player)
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
  if not (player and player.valid and CircuitDetonator.is_supported_container(player.selected)) then
    if player then player.print({ "detonation-message.circuit-detonator-select-chest" }) end
    return
  end

  CircuitDetonator.remove_for_chest(player.selected)
  player.print({ "detonation-message.circuit-detonator-removed" })
end

function CircuitDetonator.initialize_storage()
  ensure_storage()
end

return CircuitDetonator
