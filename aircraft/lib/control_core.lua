local PID = dofile("/navtool/lib/pid.lua")
local Director = dofile("/navtool/lib/flight_director.lua")

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

local function setAxis(config, commands, value, positive, negative)
  value = clamp(value, -1, 1)
  commands[positive] = value > 0 and math.floor(value * maximum(config, positive) + 0.5) or 0
  commands[negative] = value < 0 and math.floor(-value * maximum(config, negative) + 0.5) or 0
end

local function speed(state)
  local velocity = state.velocity
  if type(velocity) ~= "table" then return 0 end
  local x = tonumber(velocity.x or velocity[1]) or 0
  local y = tonumber(velocity.y or velocity[2]) or 0
  local z = tonumber(velocity.z or velocity[3]) or 0
  return math.sqrt(x * x + y * y + z * z)
end

function Control.new(config)
  local fc = type(config.flightControl) == "table" and config.flightControl or {}
  return setmetatable({
    config = config,
    fc = fc,
    heading = PID.new(fc.headingPID or { kp = 1.6, ki = 0.02, kd = 0.45, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 }),
    altitude = PID.new(fc.altitudePID or { kp = 0.12, ki = 0.01, kd = 0.18, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 }),
    speed = PID.new(fc.speedPID or { kp = 0.16, ki = 0.015, kd = 0.08, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 }),
    lastClock = os.clock(),
    hoverAltitude = nil,
  }, Control)
end

function Control:reset()
  self.heading:reset()
  self.altitude:reset()
  self.speed:reset()
  self.hoverAltitude = nil
end

function Control:outputs(state)
  local now = os.clock()
  local dt = math.max(0.001, now - self.lastClock)
  self.lastClock = now
  local mode = tostring(state.mode or "standby")
  local commands = { forward = 0, reverse = 0, left = 0, right = 0, up = 0, down = 0 }
  local notes = { "Avionics flight core" }

  if mode == "standby" then
    self:reset()
    return commands, notes, true
  end

  -- The integrated controller requires the same normalized state already shown by the UI.
  -- When any critical field is absent, the caller deliberately uses the legacy backend.
  if type(state.position) ~= "table" or type(state.heading) ~= "table" then
    return nil, { "Avionics state incomplete; legacy controller active" }, false
  end

  if mode == "navigate" or mode == "return-home" then
    if type(state.target) ~= "table" then
      return nil, { "No target; legacy controller active" }, false
    end
    local guidance, fault = Director.solve(state, state.target, self.config)
    if not guidance then return nil, { tostring(fault or "guidance unavailable") }, false end
    if guidance.arrived then
      notes[#notes + 1] = "arrival envelope"
      return commands, notes, true
    end

    local headingError, alignment = Director.headingError(state.heading, guidance.desiredHeading)
    local angular = state.angularVelocity
    local yawRate = type(angular) == "table" and tonumber(angular.y or angular[2]) or nil
    setAxis(self.config, commands, self.heading:update(headingError or 0, dt, yawRate), "right", "left")

    local verticalSpeed = tonumber(state.verticalSpeed) or (state.velocity and tonumber(state.velocity.y or state.velocity[2])) or 0
    setAxis(self.config, commands, self.altitude:update(guidance.altitudeError or 0, dt, verticalSpeed), "up", "down")

    local thrust = self.speed:update((guidance.desiredSpeed or 0) - speed(state), dt)
    local minimumAlignment = tonumber(self.fc.minimumThrustAlignment) or 0.25
    if alignment and alignment < minimumAlignment then
      thrust = thrust * math.max(0, (alignment + 1) / (minimumAlignment + 1))
    end
    setAxis(self.config, commands, thrust, "forward", "reverse")
    notes[#notes + 1] = string.format("distance %.1f", guidance.distance or 0)
    notes[#notes + 1] = string.format("alignment %.2f", alignment or 0)
    return commands, notes, true
  end

  if mode == "hover" then
    self.hoverAltitude = self.hoverAltitude or tonumber(state.altitude) or tonumber(state.position.y or state.position[2])
    local altitude = tonumber(state.altitude) or tonumber(state.position.y or state.position[2])
    local verticalSpeed = tonumber(state.verticalSpeed) or (state.velocity and tonumber(state.velocity.y or state.velocity[2])) or 0
    if altitude and self.hoverAltitude then
      setAxis(self.config, commands, self.altitude:update(self.hoverAltitude - altitude, dt, verticalSpeed), "up", "down")
    end
    local body = state.bodyVelocity or {}
    local forwardSpeed = tonumber(body.z or body.forward) or 0
    local lateralSpeed = tonumber(body.x or body.sideways) or 0
    local gain = tonumber(self.fc.hoverVelocityGain) or 0.18
    setAxis(self.config, commands, -forwardSpeed * gain, "forward", "reverse")
    setAxis(self.config, commands, -lateralSpeed * gain, "right", "left")
    notes[#notes + 1] = "position damping"
    return commands, notes, true
  end

  return nil, { "Mode delegated to legacy controller" }, false
end

return Control
