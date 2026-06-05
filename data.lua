local REAL_LAUNCHER_HOST_CHARACTER = "detonation-invisible-character"
local INVISIBLE_CHARACTER_SHEET = "__detonation__/graphics/invisible-character.png"

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

local function empty_character_armor_animation()
  return {
    idle = empty_character_animation(22, 8),
    idle_with_gun = empty_character_animation(22, 8),
    mining_with_tool = empty_character_animation(26, 8),
    running = empty_character_animation(22, 8),
    running_with_gun = empty_character_animation(22, 18),
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
