local Director = {}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function vector(value)
  if type(value) ~= "table" then return nil end
  local x, y, z = tonumber(value.x or value[1]), tonumber(value.y or value[2]), tonumber(value.z or value[3])
  if x and y and z then return { x = x, y = y, z = z } end
end

function Director.arrivalStatus(state, target, config)
  config = config or {}
  local navigation = config.navigation or {}
  local position = vector(state and state.position)
  target = vector(target)
  if not position or not target then return false, nil end

  -- Minecraft positions and physics telemetry are floating point values. Requiring
  -- bit-for-bit equality can make arrival mathematically unreachable, so precision
  -- is defined as a very small per-axis envelope. It may be tightened in config.
  local horizontalTolerance = math.max(0.001, tonumber(navigation.coordinateTolerance) or 0.05)
  local verticalTolerance = math.max(0.001, tonumber(navigation.verticalTolerance) or horizontalTolerance)
  local velocityTolerance = math.max(0, tonumber(navigation.settleVelocity) or 0.05)

  local dx = target.x - position.x
  local dy = target.y - position.y
  local dz = target.z - position.z
  local velocity = vector(state and state.velocity)
  local settled = true
  local currentSpeed = 0
  if velocity then
    currentSpeed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z)
    settled = currentSpeed <= velocityTolerance
  end

  local axesReached = math.abs(dx) <= horizontalTolerance
    and math.abs(dy) <= verticalTolerance
    and math.abs(dz) <= horizontalTolerance

  return axesReached and settled, {
    xError = dx,
    yError = dy,
    zError = dz,
    speed = currentSpeed,
    axesReached = axesReached,
    settled = settled,
    horizontalTolerance = horizontalTolerance,
    verticalTolerance = verticalTolerance,
    velocityTolerance = velocityTolerance,
  }
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
  local precisionSpeed = tonumber(navigation.precisionSpeed) or 0.35
  local slowdownRadius = math.max(1, tonumber(navigation.slowdownRadius) or 50)
  local precisionRadius = math.max(0.1, tonumber(navigation.precisionRadius) or 3)
  local speedRatio = clamp(distance / slowdownRadius, 0, 1)
  local desiredSpeed = precisionSpeed + (cruiseSpeed - precisionSpeed) * speedRatio
  if distance > precisionRadius then desiredSpeed = math.max(approachSpeed, desiredSpeed) end

  local arrived, arrival = Director.arrivalStatus(state, target, config)
  return {
    target = target,
    desiredHeading = heading,
    desiredAltitude = target.y,
    desiredSpeed = desiredSpeed,
    distance = distance,
    horizontalDistance = horizontalDistance,
    altitudeError = dy,
    xError = dx,
    yError = dy,
    zError = dz,
    arrival = arrival,
    arrived = arrived,
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
