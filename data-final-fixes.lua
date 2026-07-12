local OBSIDIAN_CHEST = "detonation-obsidian-chest"
local OBSIDIAN_REQUESTER_CHEST = "detonation-obsidian-requester-chest"
local controlled_chest_detonation_enabled =
    not settings.startup["detonation-controlled-chest-detonation"]
    or settings.startup["detonation-controlled-chest-detonation"].value ~= false

local protected_chests = {}
local obsidian_chest = data.raw.container and data.raw.container[OBSIDIAN_CHEST]
local obsidian_requester_chest =
    data.raw["logistic-container"] and data.raw["logistic-container"][OBSIDIAN_REQUESTER_CHEST]
if obsidian_chest then protected_chests[#protected_chests + 1] = obsidian_chest end
if obsidian_requester_chest then protected_chests[#protected_chests + 1] = obsidian_requester_chest end

if controlled_chest_detonation_enabled then
  local damage_type_names = {}
  for damage_type_name in pairs(data.raw["damage-type"] or {}) do
    damage_type_names[#damage_type_names + 1] = damage_type_name
  end
  table.sort(damage_type_names)

  for chest_index = 1, #protected_chests do
    local chest = protected_chests[chest_index]
    if chest then
      chest.resistances = {}
      for i = 1, #damage_type_names do
        chest.resistances[#chest.resistances + 1] = {
          type = damage_type_names[i],
          percent = 100,
        }
      end
    end
  end
end
