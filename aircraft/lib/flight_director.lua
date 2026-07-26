local Director = {}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function vector(value)
  if type(value) ~= "table" then return nil end
  local x, y, z = tonumber(value.x or value[1]), tonumber(value.y or value[2]), tonumber(value.z or value[3])
  if x and y and z then return { x = x, y = y, z = z } end
end

function Director.solve(state, target, config)
  config = config or {}
  local navigation = config.navigation or {}
  local position = vector(state and state.position)
  target = vector(target)
  if not position or not target then return nil, "position or target unavailable" end

  local dx, dy, dz = target.x - position.x, target.y - position.y, target.z - position.z
  local horizontalDistance = math.sqrt(dx * dx + dz * dz)
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  local heading
  if horizontalDistance > 0.0001 then heading = { x = dx / horizontalDistance, y = 0, z = dz / horizontalDistance } end

  local cruiseSpeed = tonumber(navigation.cruiseSpeed) or 12
  local approachSpeed = tonumber(navigation.approachSpeed) or 4
  local slowdownRadius = math.max(1, tonumber(navigation.slowdownRadius) or 50)
  local arrivalRadius = math.max(0.25, tonumber(navigation.arrivalRadius) or 5)
  local speedRatio = clamp((distance - arrivalRadius) / slowdownRadius, 0, 1)

  return {
    target = target,
    desiredHeading = heading,
    desiredAltitude = target.y,
    desiredSpeed = approachSpeed + (cruiseSpeed - approachSpeed) * speedRatio,
    distance = distance,
    horizontalDistance = horizontalDistance,
    altitudeError = dy,
    arrived = distance <= arrivalRadius,
  }
end

function Director.headingError(current, desired)
  current, desired = vector(current), vector(desired)
  if not current or not desired then return nil end
  local dot = clamp(current.x * desired.x + current.z * desired.z, -1, 1)
  local cross = current.x * desired.z - current.z * desired.x
  return math.atan2(cross, dot), dot, cross
end

return Director
