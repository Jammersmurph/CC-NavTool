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

local function horizontalSpeedAlong(state, heading)
  local velocity = vector(state and state.velocity)
  heading = vector(heading)
  if not velocity or not heading then return 0 end
  return velocity.x * heading.x + velocity.z * heading.z
end

local function headingVector(degrees)
  degrees = tonumber(degrees)
  if not degrees then return nil end
  local radians = math.rad(degrees)
  return { x = math.sin(radians), y = 0, z = math.cos(radians) }
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
  local airshipMode = type(config.hardware) == "table" and config.hardware.airshipMode == true
  local arrivalRadius = math.max(horizontalTolerance, tonumber(navigation.arrivalRadius) or 1)
  if airshipMode then arrivalRadius = math.max(arrivalRadius, tonumber(navigation.airshipArrivalRadius) or 6) end
  local settleVelocity = math.max(0, tonumber(navigation.horizontalSettleVelocity) or tonumber(navigation.settleVelocity) or 0.5)
  local transitionRadius = following
    and math.max(horizontalTolerance, tonumber(navigation.followHorizontalRadius) or 10)
    or math.max(horizontalTolerance, tonumber(navigation.verticalTransitionRadius) or 3)
  local cruiseAltitude = tonumber(navigation.cruiseAltitude) or 310
  local cruiseAltitudeMinimum = tonumber(navigation.cruiseAltitudeMinimum) or 300
  local cruiseAltitudeMaximum = tonumber(navigation.cruiseAltitudeMaximum) or 500
  local cruiseAltitudeTolerance = math.max(0, tonumber(navigation.cruiseAltitudeTolerance) or 1)
  local cruiseAltitudeReady = not airshipMode and position.y >= (cruiseAltitude - cruiseAltitudeTolerance)
  local horizontallyLocked = horizontalDistance <= arrivalRadius
    and driftSpeed <= settleVelocity

  local desiredY
  local phase
  if following and horizontalDistance <= transitionRadius then
    desiredY = final.y
    phase = "follow-offset"
  elseif horizontallyLocked then
    desiredY = final.y
    phase = "final-altitude"
  elseif horizontalDistance > transitionRadius then
    if cruiseAltitudeReady then
      desiredY = position.y
    else
      desiredY = cruiseAltitude
    end
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
    arrivalRadius = arrivalRadius,
    settleVelocity = settleVelocity,
    transitionRadius = transitionRadius,
    cruiseAltitude = cruiseAltitude,
    cruiseAltitudeMinimum = cruiseAltitudeMinimum,
    cruiseAltitudeMaximum = cruiseAltitudeMaximum,
    cruiseAltitudeReady = cruiseAltitudeReady,
    airshipMode = airshipMode,
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
  local arrivalRadius = math.max(horizontalTolerance, tonumber(navigation.arrivalRadius) or 1)
  local verticalTolerance = math.max(0.001, tonumber(navigation.verticalTolerance) or horizontalTolerance)
  local velocityTolerance = math.max(0, tonumber(navigation.settleVelocity) or 0.5)
  local headingTolerance = math.rad(math.max(0, tonumber(navigation.headingTolerance) or 4))
  local airshipMode = type(config.hardware) == "table" and config.hardware.airshipMode == true
  if airshipMode then
    arrivalRadius = math.max(arrivalRadius, tonumber(navigation.airshipArrivalRadius) or 6)
    verticalTolerance = math.max(verticalTolerance, tonumber(navigation.airshipVerticalTolerance) or 8)
    velocityTolerance = math.max(velocityTolerance, tonumber(navigation.airshipSettleVelocity) or 2.0)
    headingTolerance = math.rad(math.max(math.deg(headingTolerance), tonumber(navigation.airshipHeadingTolerance) or 15))
  end

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

  local horizontalReached = math.sqrt(dx * dx + dz * dz) <= arrivalRadius
  local targetHeading = headingVector(target and target.heading)
  local headingReached = true
  if targetHeading then
    local headingError = Director.headingError(state and state.heading, targetHeading)
    headingReached = headingError ~= nil and math.abs(headingError) <= headingTolerance
  end
  local axesReached = horizontalReached
    and math.abs(dy) <= verticalTolerance
    and headingReached

  return axesReached and settled, {
    xError = dx,
    yError = dy,
    zError = dz,
    speed = currentSpeed,
    axesReached = axesReached,
    settled = settled,
    horizontalTolerance = horizontalTolerance,
    arrivalRadius = arrivalRadius,
    verticalTolerance = verticalTolerance,
    velocityTolerance = velocityTolerance,
    headingReached = headingReached,
    headingTolerance = headingTolerance,
    airshipMode = airshipMode,
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
  local arrivalRadius = math.max(stage and stage.horizontalTolerance or 0.05, tonumber(navigation.arrivalRadius) or 1)
  if type(config.hardware) == "table" and config.hardware.airshipMode == true then
    arrivalRadius = math.max(arrivalRadius, tonumber(navigation.airshipArrivalRadius) or 6)
  end
  local brakeRadius = math.max(arrivalRadius, tonumber(navigation.brakeRadius) or 75)
  local finalOutputRadius = math.max(arrivalRadius, tonumber(navigation.finalOutputRadius) or 10)
  local finalOutputMaximum = math.max(1, math.min(15, tonumber(navigation.finalOutputMaximum) or 2))
  local finalVerticalRadius = math.max(0, tonumber(navigation.finalVerticalRadius) or 10)
  local finalVerticalOutputMaximum = math.max(1, math.min(15, tonumber(navigation.finalVerticalOutputMaximum) or 2))
  local finalVerticalUpOutputMaximum = math.max(finalVerticalOutputMaximum, math.min(15, tonumber(navigation.finalVerticalUpOutputMaximum) or 3))

  -- Horizontal propulsion must depend only on horizontal error. A large altitude
  -- difference must never produce forward thrust after X/Z have been acquired.
  local speedRatio = clamp(horizontalDistance / slowdownRadius, 0, 1)
  local desiredSpeed = precisionSpeed + (cruiseSpeed - precisionSpeed) * speedRatio
  if horizontalDistance > precisionRadius then desiredSpeed = math.max(approachSpeed, desiredSpeed) end
  if horizontalDistance <= arrivalRadius then desiredSpeed = 0 end
  if stage and stage.phase == "horizontal-cruise" and not stage.cruiseAltitudeReady and not stage.airshipMode then desiredSpeed = 0 end
  local approachSpeedAlong = horizontalSpeedAlong(state, heading)
  local shouldBrake = horizontalDistance <= brakeRadius and approachSpeedAlong > (tonumber(navigation.stopSpeed) or 0.5)
  local finalCapture = horizontalDistance <= arrivalRadius
  local targetHeading = headingVector(requestedTarget and requestedTarget.heading)
  if targetHeading and horizontalDistance <= arrivalRadius then heading = targetHeading end

  local arrived, arrival = Director.arrivalStatus(state, requestedTarget, config)
  return {
    target = target,
    requestedTarget = vector(requestedTarget),
    desiredHeading = heading,
    finalHeading = targetHeading,
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
    arrivalRadius = arrivalRadius,
    brakeRadius = brakeRadius,
    finalOutputRadius = finalOutputRadius,
    finalOutputMaximum = finalOutputMaximum,
    finalVerticalRadius = finalVerticalRadius,
    finalVerticalOutputMaximum = finalVerticalOutputMaximum,
    finalVerticalUpOutputMaximum = finalVerticalUpOutputMaximum,
    shouldBrake = shouldBrake,
    finalCapture = finalCapture,
    approachSpeedAlong = approachSpeedAlong,
    transitionRadius = stage and stage.transitionRadius or nil,
    cruiseAltitude = stage and stage.cruiseAltitude or nil,
    cruiseAltitudeReady = stage and stage.cruiseAltitudeReady or false,
    airshipMode = stage and stage.airshipMode or false,
  }
end

function Director.headingError(current, desired)
  current, desired = vector(current), vector(desired)
  if not current or not desired then return nil end
  local dot = clamp(current.x * desired.x + current.z * desired.z, -1, 1)
  -- Positive error means yaw left, matching the aircraft output names.
  local cross = current.z * desired.x - current.x * desired.z
  return math.atan2(cross, dot), dot, cross
end

return Director
