local PID = dofile("/navtool/lib/pid.lua")
local Director = dofile("/navtool/lib/flight_director.lua")
local Avionics = dofile("/navtool/lib/avionics.lua")

local Control = {}
Control.__index = Control

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, tonumber(value) or 0))
end

local function maximum(config, name)
  local output = config.outputs and config.outputs[name] or {}
  local safety = type(config.safety) == "table" and config.safety or {}
  return math.max(0, math.min(15, tonumber(output.maximum) or 15, tonumber(safety.maximumOutput) or 5))
end

local function vector(value)
  if type(value) ~= "table" then return nil end
  local x = tonumber(value.x or value[1])
  local y = tonumber(value.y or value[2])
  local z = tonumber(value.z or value[3])
  if x and y and z then return { x = x, y = y, z = z } end
end

local function normalizeHorizontal(value)
  value = vector(value)
  if not value then return nil end
  local length = math.sqrt(value.x * value.x + value.z * value.z)
  if length < 0.000001 then return nil end
  return { x = value.x / length, y = 0, z = value.z / length }
end

local function horizontalSpeed(state, heading)
  local velocity = vector(state.velocity)
  if not velocity then return 0 end
  heading = normalizeHorizontal(heading)
  if heading then return velocity.x * heading.x + velocity.z * heading.z end
  return math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
end

local function ensureAttitude(config, state)
  if type(state.attitude) ~= "table" and type(state.pose) == "table" then
    state.attitude = Avionics.attitudeFromPose(state.pose, type(config.orientation) == "table" and config.orientation or {})
  end
  if type(state.attitude) == "table" then
    state.heading = normalizeHorizontal(state.attitude.horizontalForward or state.attitude.forward) or state.heading
    state.orientationSource = state.attitude.source or state.orientationSource
  end
end

local function horizontalBasis(state)
  local attitude = type(state.attitude) == "table" and state.attitude or nil
  local forward = normalizeHorizontal(attitude and (attitude.horizontalForward or attitude.forward) or state.heading)
  if not forward then return nil end

  -- Yaw steering and horizontal position hold need a level basis even when the craft
  -- is pitched or rolled. The full 3D axes remain available for body-velocity reads.
  local right = { x = -forward.z, y = 0, z = forward.x }
  return forward, right
end

local function horizontalRates(state, forward, right)
  local body = type(state.bodyVelocity) == "table" and state.bodyVelocity or {}
  local forwardRate = tonumber(body.forward or body.z)
  local velocity = vector(state.velocity)
  if velocity then
    forwardRate = forwardRate or (velocity.x * forward.x + velocity.z * forward.z)
  end
  return forwardRate or 0
end

function Control.new(config)
  local fc = type(config.flightControl) == "table" and config.flightControl or {}
  local precisionPID = fc.positionPID or {
    kp = 0.45, ki = 0.015, kd = 0.35,
    minimum = -0.45, maximum = 0.45,
    integralMinimum = -0.3, integralMaximum = 0.3,
    derivativeFilter = 0.7,
  }
  return setmetatable({
    config = config,
    fc = fc,
    heading = PID.new(fc.headingPID or { kp = 1.6, ki = 0.02, kd = 0.45, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 }),
    altitude = PID.new(fc.altitudePID or { kp = 0.12, ki = 0.01, kd = 0.18, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 }),
    speed = PID.new(fc.speedPID or { kp = 0.16, ki = 0.015, kd = 0.08, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 }),
    positionForward = PID.new(fc.positionForwardPID or precisionPID),
    positionLateral = PID.new(fc.positionLateralPID or precisionPID),
    positionVertical = PID.new(fc.positionVerticalPID or fc.altitudePID or { kp = 0.22, ki = 0.012, kd = 0.3, minimum = -0.5, maximum = 0.5, integralMinimum = -0.25, integralMaximum = 0.25 }),
    lastClock = os.clock(),
    hoverAltitude = nil,
    airshipArrivalLock = nil,
    pulse = {},
  }, Control)
end

function Control:resetPulse(axis)
  self.pulse[axis] = nil
end

function Control:setAxis(commands, value, positive, negative, axis, precision)
  value = clamp(value, -1, 1)
  local selected = value > 0 and positive or negative
  local other = value > 0 and negative or positive
  commands[other] = 0

  if value == 0 then
    commands[selected] = 0
    self:resetPulse(axis)
    return
  end

  local peak = maximum(self.config, selected)
  local requested = math.abs(value) * peak
  if not precision then
    commands[selected] = math.floor(requested + 0.5)
    self:resetPulse(axis)
    return
  end

  local pulseState = self.pulse[axis]
  local sign = value > 0 and 1 or -1
  if not pulseState or pulseState.sign ~= sign then pulseState = { credit = 0, sign = sign } end
  pulseState.credit = pulseState.credit + requested
  local output = math.min(peak, math.floor(pulseState.credit))
  pulseState.credit = pulseState.credit - output
  self.pulse[axis] = pulseState
  commands[selected] = output
end

function Control:reset()
  self.heading:reset()
  self.altitude:reset()
  self.speed:reset()
  self.positionForward:reset()
  self.positionLateral:reset()
  self.positionVertical:reset()
  self.hoverAltitude = nil
  self.airshipArrivalLock = nil
  self.pulse = {}
end

function Control:precisionHold(state, guidance, commands, dt, notes)
  local position = vector(state.position)
  local target = vector(guidance.target)
  local forward, right = horizontalBasis(state)
  if not position or not target or not forward then return false end

  if guidance.arrived then
    if type(self.config.hardware) == "table" and self.config.hardware.airshipMode == true then
      self.airshipArrivalLock = self.airshipArrivalLock or { x = target.x, z = target.z }
      local driftLimit = tonumber(self.config.hardware.airshipReturnDrift) or 5
      local lockDx, lockDz = position.x - self.airshipArrivalLock.x, position.z - self.airshipArrivalLock.z
      if math.sqrt(lockDx * lockDx + lockDz * lockDz) > driftLimit then
        self.airshipArrivalLock = nil
        notes[#notes + 1] = "airship drift return"
        return false
      end
      commands.__airshipArrived = true
      commands.up, commands.down = 0, 0
    else
      self.airshipArrivalLock = nil
    end
    self.positionForward:reset()
    self.positionLateral:reset()
    self.positionVertical:reset()
    self.pulse = {}
    notes[#notes + 1] = "coordinate lock"
    return true
  end

  self.airshipArrivalLock = nil

  local dx, dy, dz = target.x - position.x, target.y - position.y, target.z - position.z
  local forwardError = dx * forward.x + dz * forward.z
  local forwardRate = horizontalRates(state, forward, right)
  local velocity = vector(state.velocity)
  local verticalRate = tonumber(state.verticalSpeed) or (velocity and velocity.y) or 0

  self:setAxis(commands, self.positionForward:update(forwardError, dt, forwardRate), "forward", "reverse", "precision-forward", true)
  self:setAxis(commands, self.positionVertical:update(dy, dt, verticalRate), "up", "down", "precision-vertical", true)

  notes[#notes + 1] = string.format("precision x %.4f y %.4f z %.4f", guidance.xError or 0, guidance.yError or 0, guidance.zError or 0)
  notes[#notes + 1] = "precision positioning"
  return true
end

function Control:outputs(state)
  local now = os.clock()
  local dt = math.max(0.001, now - self.lastClock)
  self.lastClock = now
  local mode = tostring(state.mode or "standby")
  local commands = { forward = 0, reverse = 0, left = 0, right = 0, up = 0, down = 0 }
  local notes = { "Sable flight core" }

  if mode == "standby" then
    self:reset()
    return commands, notes, true
  end

  ensureAttitude(self.config, state)
  if type(state.position) ~= "table" or type(state.heading) ~= "table" then
    return nil, { "Flight state incomplete; legacy controller active" }, false
  end
  if state.orientationSource then notes[#notes + 1] = "orientation " .. tostring(state.orientationSource) end

  if mode == "navigate" or mode == "return-home" then
    if type(state.target) ~= "table" then
      return nil, { "No target; legacy controller active" }, false
    end
    local guidance, fault = Director.solve(state, state.target, self.config)
    if not guidance then return nil, { tostring(fault or "guidance unavailable") }, false end

    if guidance.arrived then
      self.heading:reset()
      self.speed:reset()
      if self:precisionHold(state, guidance, commands, dt, notes) then return commands, notes, true end
    end

    self.positionForward:reset()
    self.positionLateral:reset()
    self.positionVertical:reset()
    self.pulse = {}
    local headingError, alignment = Director.headingError(state.heading, guidance.desiredHeading)
    local holdYawForAltitude = guidance.altitudePhase == "final-altitude"
      or (guidance.altitudePhase == "horizontal-cruise" and not guidance.cruiseAltitudeReady and not guidance.airshipMode)
    local finalHeadingReached = true
    if guidance.finalHeading then
      local finalHeadingError, finalAlignment = Director.headingError(state.heading, guidance.finalHeading)
      local headingTolerance = math.rad(math.max(0, tonumber(self.config.navigation and self.config.navigation.headingTolerance) or 4))
      finalHeadingReached = finalHeadingError ~= nil and math.abs(finalHeadingError) <= headingTolerance
      if guidance.finalCapture and not holdYawForAltitude then headingError, alignment = finalHeadingError, finalAlignment end
    end
    if holdYawForAltitude then
      self.heading:reset()
      commands.left, commands.right = 0, 0
      alignment = 1
      notes[#notes + 1] = "yaw held during final altitude"
    elseif guidance.finalCapture and finalHeadingReached then
      self.heading:reset()
      commands.left, commands.right = 0, 0
    elseif headingError then
      local yawTolerance = math.rad(math.max(0, tonumber(self.config.navigation and self.config.navigation.headingTolerance) or 4))
      if guidance.airshipMode then
        yawTolerance = math.rad(math.max(math.deg(yawTolerance), tonumber(self.config.navigation and self.config.navigation.airshipHeadingTolerance) or 15))
      end
      if math.abs(headingError) <= yawTolerance then
        self.heading:reset()
        commands.left, commands.right = 0, 0
        alignment = 1
        notes[#notes + 1] = "yaw within cruise tolerance"
      else
        self:setAxis(commands, self.heading:update(headingError, dt), "left", "right", "heading", false)
      end
    else
      self:setAxis(commands, self.heading:update(headingError or 0, dt), "left", "right", "heading", false)
    end

    local verticalSpeed = tonumber(state.verticalSpeed) or (state.velocity and tonumber(state.velocity.y or state.velocity[2])) or 0
    local airshipCruiseGate = guidance.airshipMode and guidance.altitudePhase == "horizontal-cruise"
    if guidance.altitudePhase == "horizontal-cruise" and guidance.cruiseAltitudeReady then
      self.altitude:reset()
      commands.up, commands.down = 0, 0
    else
      self:setAxis(commands, self.altitude:update(guidance.altitudeError or 0, dt, verticalSpeed), "up", "down", "altitude", false)
    end
    if airshipCruiseGate then
      local verticalMaximum = math.max(maximum(self.config, "up"), maximum(self.config, "down"))
      guidance.cruiseAltitudeReady = math.max(commands.up or 0, commands.down or 0) >= verticalMaximum
      if guidance.cruiseAltitudeReady then
        notes[#notes + 1] = "airship cruise: vertical max"
      else
        notes[#notes + 1] = "airship cruise: waiting for vertical max"
      end
    end
    local acquiringCruiseAltitude = guidance.altitudePhase == "horizontal-cruise" and not guidance.cruiseAltitudeReady
    if not acquiringCruiseAltitude and math.abs(guidance.altitudeError or 0) <= (tonumber(guidance.finalVerticalRadius) or 25) then
      local limit = tonumber(guidance.finalVerticalOutputMaximum) or 2
      local upLimit = tonumber(guidance.finalVerticalUpOutputMaximum) or math.min(15, limit + 1)
      commands.up = math.min(commands.up or 0, upLimit)
      commands.down = math.min(commands.down or 0, limit)
      notes[#notes + 1] = "final up/down cap " .. tostring(upLimit) .. "/" .. tostring(limit)
    end

    local currentHorizontalSpeed = horizontalSpeed(state, guidance.desiredHeading)
    if guidance.altitudePhase == "horizontal-cruise" and not guidance.cruiseAltitudeReady and not guidance.airshipMode then guidance.desiredSpeed = 0 end
    local thrust = self.speed:update((guidance.desiredSpeed or 0) - currentHorizontalSpeed, dt)
    local minimumAlignment = tonumber(self.fc.minimumThrustAlignment) or 0.94
    local inPositioningZone = guidance.horizontalDistance and guidance.finalOutputRadius and guidance.horizontalDistance <= guidance.finalOutputRadius
    if not alignment or alignment < minimumAlignment then
      self.speed:reset()
      if headingError and math.abs(headingError) > math.rad(0.5) and (commands.left or 0) == 0 and (commands.right or 0) == 0 then
        local yawOutput = math.max(1, math.min(15, tonumber(self.fc.minimumYawOutput) or 1))
        if headingError > 0 then commands.left = math.min(maximum(self.config, "left"), yawOutput)
        else commands.right = math.min(maximum(self.config, "right"), yawOutput) end
        notes[#notes + 1] = "minimum yaw while aligning"
      end
      if currentHorizontalSpeed > 0.25 then
        local brake = math.min(1, currentHorizontalSpeed / math.max(1, tonumber(self.config.navigation and self.config.navigation.cruiseSpeed) or 12))
        self:setAxis(commands, inPositioningZone and -brake or 0, "forward", "reverse", "speed", false)
        notes[#notes + 1] = string.format("align brake %.2f align %.2f", currentHorizontalSpeed, alignment or 0)
      else
        thrust = 0
        self:setAxis(commands, 0, "forward", "reverse", "speed", false)
        notes[#notes + 1] = string.format("forward held: align %.2f < %.2f", alignment or 0, minimumAlignment)
      end
    end
    if guidance.shouldBrake then
      self.speed:reset()
      local brake = math.min(1, math.max(0.25, (guidance.approachSpeedAlong or 0) / math.max(1, tonumber(self.config.navigation and self.config.navigation.cruiseSpeed) or 12)))
      self:setAxis(commands, inPositioningZone and -brake or 0, "forward", "reverse", "speed", false)
      notes[#notes + 1] = string.format("final brake %.2f in %.1f", guidance.approachSpeedAlong or 0, guidance.horizontalDistance or 0)
    elseif guidance.finalCapture then
      self.speed:reset()
      commands.forward, commands.reverse = 0, 0
      notes[#notes + 1] = string.format("final capture %.1f", guidance.horizontalDistance or 0)
    else
      if not inPositioningZone then thrust = math.max(0, thrust) end
      if alignment and alignment >= minimumAlignment and guidance.horizontalDistance and guidance.finalOutputRadius and guidance.horizontalDistance > guidance.finalOutputRadius and (guidance.desiredSpeed or 0) > 0 then
        thrust = math.max(thrust, math.max(1, math.min(15, tonumber(self.fc.minimumForwardOutput) or 2)) / math.max(1, maximum(self.config, "forward")))
      end
      self:setAxis(commands, thrust, "forward", "reverse", "speed", false)
    end
    if guidance.horizontalDistance and guidance.finalOutputRadius and guidance.horizontalDistance <= guidance.finalOutputRadius then
      local limit = tonumber(guidance.finalOutputMaximum) or 2
      commands.forward = math.min(commands.forward or 0, limit)
      commands.reverse = math.min(commands.reverse or 0, limit)
      notes[#notes + 1] = "final f/rev cap " .. tostring(limit)
    end
    notes[#notes + 1] = string.format("phase %s cruise %s", tostring(guidance.altitudePhase or "unknown"), guidance.cruiseAltitudeReady and "ready" or "hold")
    notes[#notes + 1] = string.format("distance %.2f horizontal %.2f", guidance.distance or 0, guidance.horizontalDistance or 0)
    notes[#notes + 1] = string.format("heading %.1f align %.2f speed %.2f/%.2f", math.deg(headingError or 0), alignment or 0, currentHorizontalSpeed, guidance.desiredSpeed or 0)
    return commands, notes, true
  end

  if mode == "hover" then
    self.hoverAltitude = self.hoverAltitude or tonumber(state.altitude) or tonumber(state.position.y or state.position[2])
    local altitude = tonumber(state.altitude) or tonumber(state.position.y or state.position[2])
    local verticalSpeed = tonumber(state.verticalSpeed) or (state.velocity and tonumber(state.velocity.y or state.velocity[2])) or 0
    if altitude and self.hoverAltitude then
      self:setAxis(commands, self.altitude:update(self.hoverAltitude - altitude, dt, verticalSpeed), "up", "down", "hover-altitude", true)
    end
    local body = state.bodyVelocity or {}
    local forwardSpeed = tonumber(body.forward or body.z) or 0
    local gain = tonumber(self.fc.hoverVelocityGain) or 0.18
    self:setAxis(commands, -forwardSpeed * gain, "forward", "reverse", "hover-forward", true)
    notes[#notes + 1] = "position damping"
    return commands, notes, true
  end

  return nil, { "Mode delegated to legacy controller" }, false
end

return Control
