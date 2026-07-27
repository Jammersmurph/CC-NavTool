-- CC-NavTool Avionics-native flight runtime
local ROOT = "/navtool"
local CONFIG_PATH = ROOT .. "/config.lua"
local TARGET_PATH = ROOT .. "/target.db"
local MODE_PATH = ROOT .. "/mode.db"

local PID = dofile(ROOT .. "/lib/pid.lua")
local Avionics = dofile(ROOT .. "/lib/avionics.lua")
local Director = dofile(ROOT .. "/lib/flight_director.lua")
local Recorder = dofile(ROOT .. "/lib/recorder.lua")
local Hardware = fs.exists(ROOT .. "/hardware.lua") and dofile(ROOT .. "/hardware.lua") or nil
if Hardware then Hardware.installRedstoneProxy() end

local function load(path, fallback)
  if not fs.exists(path) then return fallback end
  local file = fs.open(path, "r")
  if not file then return fallback end
  local value = textutils.unserialize(file.readAll())
  file.close()
  return value == nil and fallback or value
end

local function save(path, value)
  local file = fs.open(path, "w")
  if not file then return false end
  file.write(textutils.serialize(value))
  file.close()
  return true
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, tonumber(value) or 0))
end

local function outputMaximum(config, output)
  local safety = config.safety or {}
  return math.max(0, math.min(15, tonumber(output.maximum) or 15, tonumber(safety.maximumOutput) or 5))
end

local function writeOutputTarget(config, output, normalized)
  if type(output) ~= "table" or not output.side then return 0 end
  local maximum = outputMaximum(config, output)
  local value = math.floor(clamp(math.abs(normalized), 0, 1) * maximum + 0.5)
  if output.inverted and value > 0 then value = math.max(1, maximum - value + 1) end
  if output.analog == false then redstone.setOutput(output.side, value > 0)
  else redstone.setAnalogOutput(output.side, value) end
  return value
end

local function writeOutput(config, name, normalized)
  local output = config.outputs and config.outputs[name]
  if type(output) ~= "table" then return 0 end
  local targets = type(output.targets) == "table" and output.targets or { output }
  local applied = 0
  for _, target in ipairs(targets) do
    applied = math.max(applied, writeOutputTarget(config, target, normalized))
  end
  return applied
end

local function clearOutputs(config)
  local cleared = {}
  for _, output in pairs(config.outputs or {}) do
    local targets = type(output.targets) == "table" and output.targets or { output }
    for _, target in ipairs(targets) do
      if target.side and not cleared[target.side] then
        pcall(redstone.setAnalogOutput, target.side, 0)
        pcall(redstone.setOutput, target.side, false)
        cleared[target.side] = true
      end
    end
  end
end

local function splitAxis(value, positive, negative, commands)
  value = clamp(value, -1, 1)
  commands[positive] = value > 0 and value or 0
  commands[negative] = value < 0 and -value or 0
end

local function horizontalSpeedAlong(state, heading)
  local velocity = type(state.velocity) == "table" and state.velocity or nil
  if not velocity then return 0 end
  local vx = tonumber(velocity.x or velocity[1]) or 0
  local vz = tonumber(velocity.z or velocity[3]) or 0
  if type(heading) == "table" then
    local hx = tonumber(heading.x or heading[1])
    local hz = tonumber(heading.z or heading[3])
    if hx and hz then return vx * hx + vz * hz end
  end
  return math.sqrt(vx * vx + vz * vz)
end

local config, configErr = load(CONFIG_PATH)
if type(config) ~= "table" then printError("Config error: " .. tostring(configErr or "missing config")); return end

config.flightControl = type(config.flightControl) == "table" and config.flightControl or {}
local fc = config.flightControl
local interval = math.max(0.05, tonumber(fc.interval) or tonumber(config.updateInterval) or 0.05)
local discovered = Avionics.discover(config)

local headingPID = PID.new(fc.headingPID or { kp = 1.6, ki = 0.02, kd = 0.45, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 })
local altitudePID = PID.new(fc.altitudePID or { kp = 0.12, ki = 0.01, kd = 0.18, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 })
local speedPID = PID.new(fc.speedPID or { kp = 0.16, ki = 0.015, kd = 0.08, minimum = -1, maximum = 1, integralMinimum = -0.5, integralMaximum = 0.5 })
local recorder = Recorder.new(fc.recorder or {})

local lastClock = os.clock()
local running = true

local function stop(reason)
  running = false
  save(MODE_PATH, { mode = "standby" })
  clearOutputs(config)
  recorder:append({ event = "stop", reason = reason })
  recorder:close()
end

local function controlTick()
  local now = os.clock()
  local dt = math.max(0.001, now - lastClock)
  lastClock = now

  local modeData = load(MODE_PATH, { mode = "standby" })
  local mode = tostring(modeData.mode or "standby")
  local target = load(TARGET_PATH)
  local state = Avionics.read(config, discovered, false)
  local commands = { forward = 0, reverse = 0, left = 0, right = 0, up = 0, down = 0 }
  local guidance
  local fault

  if mode == "standby" then
    headingPID:reset(); altitudePID:reset(); speedPID:reset()
  elseif not state.healthy then
    fault = "required Create: Avionics/Sable telemetry unavailable"
    if not config.safety or config.safety.disengageOnTelemetryLoss ~= false then
      save(MODE_PATH, { mode = "standby" })
      mode = "standby"
    end
  elseif mode == "navigate" or mode == "return-home" then
    guidance, fault = Director.solve(state, target, config)
    if guidance then
      if guidance.arrived then
        save(MODE_PATH, { mode = "hover" })
        mode = "hover"
      else
        local headingError = Director.headingError(state.heading, guidance.desiredHeading)
        local yawRate = type(state.angularVelocity) == "table" and tonumber(state.angularVelocity.y or state.angularVelocity[2]) or nil
        local yaw = headingPID:update(headingError or 0, dt, yawRate)
        splitAxis(yaw, "left", "right", commands)

        local vertical = altitudePID:update(guidance.altitudeError or 0, dt, state.verticalSpeed)
        splitAxis(vertical, "up", "down", commands)

        local headingAlignment = guidance.desiredHeading and state.heading and select(2, Director.headingError(state.heading, guidance.desiredHeading)) or 0
        local speed = horizontalSpeedAlong(state, guidance.desiredHeading)
        local thrust = speedPID:update((guidance.desiredSpeed or 0) - speed, dt)
        if not headingAlignment or headingAlignment < tonumber(fc.minimumThrustAlignment or 0.75) then
          thrust = 0
          speedPID:reset()
        end
        thrust = math.max(0, thrust)
        splitAxis(thrust, "forward", "reverse", commands)
      end
    end
  elseif mode == "hover" then
    local verticalSpeed = tonumber(state.verticalSpeed) or (state.velocity and tonumber(state.velocity.y)) or 0
    local vertical = altitudePID:update(0, dt, verticalSpeed)
    splitAxis(vertical, "up", "down", commands)
    local body = state.bodyVelocity or {}
    local forwardSpeed = tonumber(body.z or body.forward) or 0
    splitAxis(-forwardSpeed * tonumber(fc.hoverVelocityGain or 0.18), "forward", "reverse", commands)
  else
    fault = "unsupported mode " .. mode
    save(MODE_PATH, { mode = "standby" })
    mode = "standby"
  end

  local applied = {}
  for name, value in pairs(commands) do
    local ok, result = pcall(writeOutput, config, name, value)
    applied[name] = ok and result or 0
  end

  recorder:append({
    mode = mode,
    source = state.source,
    healthy = state.healthy,
    degraded = state.degraded,
    position = state.position,
    velocity = state.velocity,
    bodyVelocity = state.bodyVelocity,
    heading = state.heading,
    headingDegrees = state.headingDegrees,
    altitude = state.altitude,
    verticalSpeed = state.verticalSpeed,
    mass = state.mass,
    target = target,
    guidance = guidance,
    commands = commands,
    outputs = applied,
    fault = fault,
  })

  term.clear()
  term.setCursorPos(1, 1)
  print("CC-NavTool Flight Core")
  print("Mode: " .. mode)
  print("Telemetry: " .. (state.healthy and "ONLINE" or "DEGRADED"))
  print("Source: " .. tostring(state.source))
  print("Heading: " .. tostring(state.headingDegrees or "unknown"))
  print("Altitude: " .. tostring(state.altitude or "unknown"))
  print("Speed: " .. string.format("%.2f", tonumber(state.speed) or 0))
  if guidance then
    print("Distance: " .. string.format("%.1f", guidance.distance or 0))
    print("Desired speed: " .. string.format("%.1f", guidance.desiredSpeed or 0))
  end
  if fault then printError(fault) end
  print("Outputs: " .. textutils.serialize(applied))
  print("Press Q to disengage")
end

local function controls()
  while running do
    local event, key = os.pullEvent("key")
    if key == keys.q then stop("operator disengage") end
  end
end

local function loop()
  while running do
    local ok, err = pcall(controlTick)
    if not ok then
      printError(err)
      stop("control exception")
      return
    end
    sleep(interval)
  end
end

print("Starting Avionics-native flight core...")
local ok, err = pcall(parallel.waitForAny, loop, controls)
if not ok then printError(err) end
clearOutputs(config)
recorder:close()
