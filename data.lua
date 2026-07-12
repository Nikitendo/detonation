local REAL_LAUNCHER_HOST_CHARACTER = "detonation-invisible-character"
local CIRCUIT_DETONATOR_PROXY = "detonation-circuit-detonator-proxy"
local CIRCUIT_DETONATION_TECH = "detonation-circuit-detonation"
local CIRCUIT_DETONATION_SPRITE = "detonation-circuit-detonation-icon"
local OBSIDIAN_CHEST = "detonation-obsidian-chest"
local OBSIDIAN_CHEST_TECH = "detonation-obsidian-chest"
local OBSIDIAN_REQUESTER_CHEST = "detonation-obsidian-requester-chest"
local OBSIDIAN_REQUESTER_CHEST_TECH = "detonation-obsidian-requester-chest"
local INVISIBLE_CHARACTER_SHEET = "__detonation__/graphics/invisible-character.png"
local controlled_chest_detonation_enabled =
    not settings.startup["detonation-controlled-chest-detonation"]
    or settings.startup["detonation-controlled-chest-detonation"].value ~= false

local function obsidian_requester_science_ingredients()
  local ingredients = {
    { "automation-science-pack", 1 },
    { "logistic-science-pack", 1 },
    { "chemical-science-pack", 1 },
  }
  if mods["space-age"] then
    ingredients[#ingredients + 1] = { "space-science-pack", 1 }
  end
  return ingredients
end

-- Keep normal building/tile placement checks, but omit every layer used by
-- characters and units (player, train and is_object). This prevents protected
-- chests from functioning as indestructible walls while still stopping two
-- buildings from being placed on the same tile.
local PASSABLE_CHEST_COLLISION_MASK = {
  layers = {
    item = true,
    object = true,
    water_tile = true,
    is_lower_object = true,
  },
}

local function add_flag(flags, flag)
  for _, existing in pairs(flags) do
    if existing == flag then return end
  end
  flags[#flags + 1] = flag
end

local function empty_character_animation(frame_count, direction_count)
  return {
    filename = INVISIBLE_CHARACTER_SHEET,
    width = 1,
    height = 1,
    line_length = frame_count,
    frame_count = frame_count,
    direction_count = direction_count,
    animation_speed = 1,
  }
end

local function empty_sprite()
  return {
    filename = INVISIBLE_CHARACTER_SHEET,
    width = 1,
    height = 1,
    priority = "low",
  }
end

local function empty_character_armor_animation()
  return {
    idle = empty_character_animation(22, 8),
    idle_with_gun = empty_character_animation(22, 8),
    mining_with_tool = empty_character_animation(26, 8),
    running = empty_character_animation(22, 8),
    running_with_gun = empty_character_animation(22, 18),
  }
end

local function define_gui_styles()
  local styles = data.raw["gui-style"] and data.raw["gui-style"].default
  if not styles then return end

  if styles.green_button then
    styles.detonation_green_button = table.deepcopy(styles.green_button)
  elseif styles.confirm_button then
    styles.detonation_green_button = table.deepcopy(styles.confirm_button)
  end

  styles.detonation_direction_table = {
    type = "table_style",
    horizontal_spacing = 2,
    vertical_spacing = 2,
  }

  styles.detonation_section_frame = {
    type = "frame_style",
    parent = "inside_shallow_frame_packed",
    vertical_flow_style = {
      type = "vertical_flow_style",
      vertical_spacing = 0,
    },
  }

  styles.detonation_section_content_flow = {
    type = "vertical_flow_style",
    padding = 12,
    vertical_spacing = 4,
  }
end

define_gui_styles()

local base_steel_chest = data.raw.container and data.raw.container["steel-chest"]
local base_steel_chest_item = data.raw.item and data.raw.item["steel-chest"]
if base_steel_chest and base_steel_chest_item then
  local obsidian_tint = { 0.32, 0.20, 0.42, 1 }

  local obsidian_chest = table.deepcopy(base_steel_chest)
  obsidian_chest.name = OBSIDIAN_CHEST
  obsidian_chest.icon = nil
  obsidian_chest.icons = {
    {
      icon = base_steel_chest.icon,
      icon_size = base_steel_chest.icon_size or 64,
      tint = obsidian_tint,
    },
  }
  obsidian_chest.minable = { mining_time = 0.2, result = OBSIDIAN_CHEST }
  obsidian_chest.corpse = nil
  obsidian_chest.dying_explosion = nil
  obsidian_chest.fast_replaceable_group = nil
  obsidian_chest.collision_mask = table.deepcopy(PASSABLE_CHEST_COLLISION_MASK)
  obsidian_chest.localised_name = { "entity-name." .. OBSIDIAN_CHEST }
  obsidian_chest.localised_description = { "entity-description." .. OBSIDIAN_CHEST }
  if obsidian_chest.picture and obsidian_chest.picture.layers and obsidian_chest.picture.layers[1] then
    obsidian_chest.picture.layers[1].tint = obsidian_tint
  end

  local obsidian_item = table.deepcopy(base_steel_chest_item)
  obsidian_item.name = OBSIDIAN_CHEST
  obsidian_item.icon = nil
  obsidian_item.icons = table.deepcopy(obsidian_chest.icons)
  obsidian_item.place_result = OBSIDIAN_CHEST
  obsidian_item.order = "a[items]-d[detonation-obsidian-chest]"
  obsidian_item.localised_name = { "item-name." .. OBSIDIAN_CHEST }
  obsidian_item.localised_description = { "item-description." .. OBSIDIAN_CHEST }

  data:extend {
    obsidian_chest,
    obsidian_item,
    {
      type = "recipe",
      name = OBSIDIAN_CHEST,
      enabled = false,
      hidden = not controlled_chest_detonation_enabled,
      energy_required = 2,
      ingredients = {
        { type = "item", name = "steel-chest", amount = 1 },
        { type = "item", name = "stone-brick", amount = 20 },
      },
      results = {
        { type = "item", name = OBSIDIAN_CHEST, amount = 1 },
      },
    },
    {
      type = "technology",
      name = OBSIDIAN_CHEST_TECH,
      icons = table.deepcopy(obsidian_chest.icons),
      hidden = not controlled_chest_detonation_enabled,
      prerequisites = { "steel-processing" },
      effects = {
        { type = "unlock-recipe", recipe = OBSIDIAN_CHEST },
      },
      unit = {
        count = 50,
        ingredients = {
          { "automation-science-pack", 1 },
        },
        time = 15,
      },
      order = "c-a-b",
      localised_name = { "technology-name." .. OBSIDIAN_CHEST_TECH },
      localised_description = { "technology-description." .. OBSIDIAN_CHEST_TECH },
    },
  }
end

local base_requester_chest = data.raw["logistic-container"] and data.raw["logistic-container"]["requester-chest"]
local base_requester_chest_item = data.raw.item and data.raw.item["requester-chest"]
if base_requester_chest and base_requester_chest_item and data.raw.item[OBSIDIAN_CHEST] then
  local obsidian_requester_tint = { 0.30, 0.22, 0.50, 1 }

  local requester = table.deepcopy(base_requester_chest)
  requester.name = OBSIDIAN_REQUESTER_CHEST
  requester.icon = nil
  requester.icons = {
    {
      icon = base_requester_chest.icon,
      icon_size = base_requester_chest.icon_size or 64,
      tint = obsidian_requester_tint,
    },
  }
  requester.minable = { mining_time = 0.2, result = OBSIDIAN_REQUESTER_CHEST }
  requester.corpse = nil
  requester.dying_explosion = nil
  requester.fast_replaceable_group = nil
  requester.collision_mask = table.deepcopy(PASSABLE_CHEST_COLLISION_MASK)
  requester.localised_name = { "entity-name." .. OBSIDIAN_REQUESTER_CHEST }
  requester.localised_description = { "entity-description." .. OBSIDIAN_REQUESTER_CHEST }
  local requester_layers = requester.robot_door
      and requester.robot_door.animation
      and requester.robot_door.animation.layers
  if requester_layers and requester_layers[1] then
    requester_layers[1].tint = obsidian_requester_tint
  end

  local requester_item = table.deepcopy(base_requester_chest_item)
  requester_item.name = OBSIDIAN_REQUESTER_CHEST
  requester_item.icon = nil
  requester_item.icons = table.deepcopy(requester.icons)
  requester_item.place_result = OBSIDIAN_REQUESTER_CHEST
  requester_item.order = "b[storage]-f[detonation-obsidian-requester-chest]"
  requester_item.localised_name = { "item-name." .. OBSIDIAN_REQUESTER_CHEST }
  requester_item.localised_description = { "item-description." .. OBSIDIAN_REQUESTER_CHEST }

  data:extend {
    requester,
    requester_item,
    {
      type = "recipe",
      name = OBSIDIAN_REQUESTER_CHEST,
      enabled = false,
      hidden = not controlled_chest_detonation_enabled,
      energy_required = 2,
      ingredients = {
        { type = "item", name = OBSIDIAN_CHEST, amount = 1 },
        { type = "item", name = "requester-chest", amount = 1 },
      },
      results = {
        { type = "item", name = OBSIDIAN_REQUESTER_CHEST, amount = 1 },
      },
    },
    {
      type = "technology",
      name = OBSIDIAN_REQUESTER_CHEST_TECH,
      icons = table.deepcopy(requester.icons),
      hidden = not controlled_chest_detonation_enabled,
      prerequisites = { "logistic-system", OBSIDIAN_CHEST_TECH },
      effects = {
        { type = "unlock-recipe", recipe = OBSIDIAN_REQUESTER_CHEST },
      },
      unit = {
        count = 200,
        ingredients = obsidian_requester_science_ingredients(),
        time = 30,
      },
      order = "c-k-d-b",
      localised_name = { "technology-name." .. OBSIDIAN_REQUESTER_CHEST_TECH },
      localised_description = { "technology-description." .. OBSIDIAN_REQUESTER_CHEST_TECH },
    },
  }
end

local base_character = data.raw.character and data.raw.character.character
if base_character then
  local invisible_character = table.deepcopy(base_character)
  invisible_character.name = REAL_LAUNCHER_HOST_CHARACTER
  invisible_character.localised_name = { "", "Detonation launcher host" }
  invisible_character.localised_description = { "", "Hidden helper character used for runtime launcher shots." }
  invisible_character.hidden = true
  invisible_character.selectable_in_game = false
  invisible_character.flags = table.deepcopy(base_character.flags or {})
  add_flag(invisible_character.flags, "not-blueprintable")
  add_flag(invisible_character.flags, "not-deconstructable")
  add_flag(invisible_character.flags, "hide-alt-info")
  add_flag(invisible_character.flags, "not-in-kill-statistics")

  invisible_character.animations = { empty_character_armor_animation() }
  invisible_character.light = nil
  invisible_character.character_corpse = nil
  invisible_character.heartbeat = nil
  invisible_character.synced_footstep_particle_triggers = nil
  invisible_character.footstep_particle_triggers = nil
  invisible_character.footprint_particles = nil
  invisible_character.left_footprint_frames = nil
  invisible_character.right_footprint_frames = nil
  invisible_character.left_footprint_offset = nil
  invisible_character.right_footprint_offset = nil
  invisible_character.water_reflection = nil

  data:extend { invisible_character }
end

local base_land_mine = data.raw["land-mine"] and data.raw["land-mine"]["land-mine"]
if controlled_chest_detonation_enabled and base_land_mine then
  local proxy = table.deepcopy(base_land_mine)
  proxy.name = CIRCUIT_DETONATOR_PROXY
  proxy.localised_name = { "entity-name." .. CIRCUIT_DETONATOR_PROXY }
  proxy.localised_description = { "entity-description." .. CIRCUIT_DETONATOR_PROXY }
  proxy.hidden = true
  proxy.selectable_in_game = false
  proxy.flags = table.deepcopy(base_land_mine.flags or {})
  add_flag(proxy.flags, "not-on-map")
  add_flag(proxy.flags, "not-blueprintable")
  add_flag(proxy.flags, "not-deconstructable")
  add_flag(proxy.flags, "not-selectable-in-game")
  add_flag(proxy.flags, "hide-alt-info")
  add_flag(proxy.flags, "not-in-kill-statistics")

  proxy.minable = nil
  proxy.fast_replaceable_group = nil
  proxy.corpse = nil
  proxy.dying_explosion = nil
  proxy.damaged_trigger_effect = nil
  proxy.alert_when_damaged = false
  proxy.collision_box = {{-0.01, -0.01}, {0.01, 0.01}}
  proxy.selection_box = {{-0.01, -0.01}, {0.01, 0.01}}
  proxy.collision_mask = { layers = {} }
  proxy.trigger_radius = 0.01
  proxy.timeout = 0
  proxy.picture_safe = empty_sprite()
  proxy.picture_set = empty_sprite()
  proxy.picture_set_enemy = empty_sprite()

  -- Keep the proxy mine's own detonation harmless. The action only kills the
  -- proxy itself so runtime can observe on_entity_died and kill the linked
  -- chest through the normal detonation path.
  proxy.action = {
    type = "direct",
    action_delivery = {
      type = "instant",
      source_effects = {
        {
          type = "damage",
          damage = { amount = 1000, type = "explosion" },
        },
      },
    },
  }

  data:extend { proxy }
end

if controlled_chest_detonation_enabled then
  data:extend {
    {
      type = "sprite",
      name = CIRCUIT_DETONATION_SPRITE,
      filename = "__detonation__/graphics/icons/circuit-detonation.png",
      width = 64,
      height = 64,
    },
  }
end

local military_technology = data.raw.technology and data.raw.technology.military
local automation_technology = data.raw.technology and data.raw.technology.automation

if controlled_chest_detonation_enabled and data.raw.technology and not data.raw.technology[CIRCUIT_DETONATION_TECH] then
  data:extend {
    {
      type = "technology",
      name = CIRCUIT_DETONATION_TECH,
      icon = "__detonation__/graphics/technology/circuit-detonation.png",
      icon_size = 256,
      prerequisites = military_technology and { "military" } or nil,
      effects = {},
      unit = table.deepcopy(
        (military_technology and military_technology.unit)
        or (automation_technology and automation_technology.unit)
        or {
          count = 10,
          ingredients = {
            { "automation-science-pack", 1 },
          },
          time = 10,
        }
      ),
      order = "e-a-a",
    },
  }
end
