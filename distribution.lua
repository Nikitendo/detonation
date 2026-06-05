local Distribution = {}

local TWO_PI = 2 * math.pi
local DEFAULT_DIRECTIONAL_BACK_WEIGHT = 0.08
local DEFAULT_DIRECTIONAL_SHARPNESS = 3
local DEFAULT_FORWARD_DISTANCE_MULTIPLIER = math.sqrt(6)
local BIASED_ANGLE_ATTEMPTS = 16

local function normalize_direction(direction)
  if type(direction) ~= "table" or type(direction.x) ~= "number" or type(direction.y) ~= "number" then
    return nil, nil
  end

  local length = math.sqrt(direction.x * direction.x + direction.y * direction.y)
  if length <= 0.001 then return nil, nil end

  return direction.x / length, direction.y / length
end

local function directional_angle_weight(angle, back_weight, sharpness)
  local forwardness = (1 + math.cos(angle)) * 0.5
  return back_weight + (1 - back_weight) * (forwardness ^ sharpness)
end

local function sample_biased_angle(rng, back_weight, sharpness)
  if back_weight >= 1 then return rng() * TWO_PI - math.pi end

  local best_angle = nil
  local best_weight = -1
  for _ = 1, BIASED_ANGLE_ATTEMPTS do
    local angle = rng() * TWO_PI - math.pi
    local weight = directional_angle_weight(angle, back_weight, sharpness)
    if rng() <= weight then return angle end
    if weight > best_weight then
      best_angle = angle
      best_weight = weight
    end
  end

  return best_angle or (rng() * TWO_PI - math.pi)
end

local function directional_distance_multiplier(angle, forward_distance_multiplier)
  local forwardness = math.max(0, math.cos(angle))
  return 1 + (forward_distance_multiplier - 1) * forwardness * forwardness
end

function Distribution.new(center, total_booms, rng, options)
  local spread = math.sqrt(total_booms)
  local direction_x, direction_y = normalize_direction(options and options.direction)

  return function(radius_scale)
    local angle
    if direction_x then
      angle = sample_biased_angle(rng, DEFAULT_DIRECTIONAL_BACK_WEIGHT, DEFAULT_DIRECTIONAL_SHARPNESS)
      local distance_multiplier = directional_distance_multiplier(angle, DEFAULT_FORWARD_DISTANCE_MULTIPLIER)
      local distance = math.sqrt(rng()) * spread * radius_scale * distance_multiplier
      local cos_angle = math.cos(angle)
      local sin_angle = math.sin(angle)
      return {
        x = center.x + (direction_x * cos_angle - direction_y * sin_angle) * distance,
        y = center.y + (direction_x * sin_angle + direction_y * cos_angle) * distance,
      }, distance
    else
      angle = rng() * TWO_PI
    end

    local distance = math.sqrt(rng()) * spread * radius_scale
    return {
      x = center.x + math.cos(angle) * distance,
      y = center.y + math.sin(angle) * distance,
    }, distance
  end
end

return Distribution
