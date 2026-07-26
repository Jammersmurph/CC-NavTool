local Director = {}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function vector(value)
  if type(value) ~= "table" then return nil end
  local x, y, z = tonumber(value.x or value[1]), tonumber(value.y or value[2]), tonumber(value.z or value[3])
  if x and y and z then return { x = x, y = y, z = z } end
end

local function horizontalSpeed(state)
  local velocity = vector(state and state.velocity)
  if not velocity then return 0 end
  return math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
end

local function finalTarget(target, navigation)
  local requested = vector(target)
  if not requested then return nil end
  local following = type(target) == "table" and target.dynamic == true
  return {
    x = requested.x,
    y = following and (requested.y + (tonumber(navigation.followHeightOffset) or 10)) or requested.y,
    z = requested.z,
  }, following, requested
end

local function stagedTarget(state, target, config)
  config = config or {}
  local navigation = config.navigation or {}
  local position = vector(state and state.position)
  local final, following, requested = finalTarget(target, navigation)
  if not position or not final then return final, nil end

  local dx, dz = final.x - position.x, final.z - position.z
  local horizontalDistance = math.sqrt(dx * dx + dz * dz)
  local driftSpeed = horizontalSpeed(state)
  local horizontalTolerance = math.max(0.001, tonumber(navigation.coordinateTolerance) or 0.05)
  local settleVelocity = math.max(0, tonumber(navigation.horizontalSettleVelocity) or tonumber(navigation.settleVelocity) or 0.05)
  local transitionRadius = following
    and math.max(horizontalTolerance, tonumber(navigation.followHorizontalRadius) or 10)
    or math.max(horizontalTolerance, tonumber(navigation.verticalTransitionRadius) or 3)
  local cruiseAltitude = tonumber(navigation.cruiseAltitude) or 300

  local horizontallyLocked = math.abs(dx) <= horizontalTolerance
    and math.abs(dz) <= horizontalTolerance
    and driftSpeed <= settleVelocity

  local desiredY
  local phase
  if horizontallyLocked then
    desiredY = final.y
    phase = following and "follow-offset" or "final-altitude"
  elseif horizontalDistance > transitionRadius then
    desiredY = cruiseAltitude
    phase = "horizontal-cruise"
  else
    -- Inside the precision approach envelope but not exactly centered, freeze the
    -- current altitude. This prevents a diagonal descent and immediately suspends
    -- descent if the craft is pushed away from the waypoint.
    desiredY = position.y
    phase = "horizontal-lock"
  end

  return {
    x = final.x,
    y = desiredY,
    z = final.z,
  }, {
    requested = requested,
    finalTarget = final,
    phase = phase,
    following = following,
    horizontalDistance = horizontalDistance,
    horizontalSpeed = driftSpeed,
    horizontallyLocked = horizontallyLocked,
    horizontalTolerance = horizontalTolerance,
    settleVelocity = settleVelocity,
    transitionRadius = transitionRadius,
    cruiseAltitude = cruiseAltitude,
  }
end

function Director.navigationTarget(state, target, config)
  return stagedTarget(state, target, config)
end

function Director.arrivalStatus(state, target, config)
  config = config or {}
  local navigation = config.navigation or {}
  local position = vector(state and state.position)
  local targetPosition = finalTarget(target, navigation)
  if not position or not targetPosition then return false, nil end

  local horizontalTolerance = math.max(0.001, tonumber(navigation.coordinateTolerance) or 0.05)
  local verticalTolerance = math.max(0.001, tonumber(navigation.verticalTolerance) or horizontalTolerance)
  local velocityTolerance = math.max(0, tonumber(navigation.settleVelocity) or 0.05)

  local dx = targetPosition.x - position.x
  local dy = targetPosition.y - position.y
  local dz = targetPosition.z - position.z
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
    navigationTarget = targetPosition,
  }
end

function Director.solve(state, target, config)
  config = config or {}
  local navigation = config.navigation or {}
  local position = vector(state and state.position)
  local requestedTarget = target
  local navigationTarget, stage = stagedTarget(state, target, config)
  target = vector(navigationTarget)
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

  -- Horizontal propulsion must depend only on horizontal error. A large altitude
  -- difference must never produce forward thrust after X/Z have been acquired.
  local speedRatio = clamp(horizontalDistance / slowdownRadius, 0, 1)
  local desiredSpeed = precisionSpeed + (cruiseSpeed - precisionSpeed) * speedRatio
  if horizontalDistance > precisionRadius then desiredSpeed = math.max(approachSpeed, desiredSpeed) end
  if horizontalDistance <= (stage and stage.horizontalTolerance or 0.05) then desiredSpeed = 0 end

  local arrived, arrival = Director.arrivalStatus(state, requestedTarget, config)
  return {
    target = target,
    requestedTarget = vector(requestedTarget),
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
    altitudePhase = stage and stage.phase or nil,
    horizontallyLocked = stage and stage.horizontallyLocked or false,
    horizontalSpeed = stage and stage.horizontalSpeed or nil,
    horizontalTolerance = stage and stage.horizontalTolerance or nil,
    transitionRadius = stage and stage.transitionRadius or nil,
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
