-- CC-NavTool Sable-native flight runtime
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

local function outputTargets(output)
  if type(output) ~= "table" then return {} end
  if type(output.targets) == "table" then return output.targets end
  if output.side then return { output } end
  return {}
end

local function outputValue(config, output, normalized)
  if type(output) ~= "table" or not output.side then return 0 end
  local maximum = outputMaximum(config, output)
  local value = math.floor(clamp(math.abs(normalized), 0, 1) * maximum + 0.5)
  if output.inverted and value > 0 then value = math.max(1, maximum - value + 1) end
  return value
end

local function writeOutputTarget(output, value)
  if output.analog == false then redstone.setOutput(output.side, value > 0)
  else redstone.setAnalogOutput(output.side, value) end
end

local function writeOutputs(config, commands)
  local winners = {}
  local applied = {}
  for name, output in pairs(config.outputs or {}) do
    for _, target in ipairs(outputTargets(output)) do
      if type(target) == "table" and target.side then
        local value = outputValue(config, target, commands[name] or 0)
        local current = winners[target.side]
        if not current or value > current.value then winners[target.side] = { target = target, value = value } end
      end
    end
  end
  for _, winner in pairs(winners) do writeOutputTarget(winner.target, winner.value) end
  for name, output in pairs(config.outputs or {}) do
    local value = 0
    for _, target in ipairs(outputTargets(output)) do
      if type(target) == "table" and target.side and winners[target.side] then value = math.max(value, winners[target.side].value) end
    end
    applied[name] = value
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
local airshipArrivalLock

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
    fault = "required CC:Sable telemetry unavailable"
    if not config.safety or config.safety.disengageOnTelemetryLoss ~= false then
      save(MODE_PATH, { mode = "standby" })
      mode = "standby"
    end
  elseif mode == "navigate" or mode == "return-home" then
    guidance, fault = Director.solve(state, target, config)
    if guidance then
      if guidance.arrived then
        if type(config.hardware) == "table" and config.hardware.airshipMode == true and type(state.position) == "table" and type(guidance.target) == "table" then
          airshipArrivalLock = airshipArrivalLock or { x = guidance.target.x, z = guidance.target.z }
          local driftLimit = tonumber(config.hardware.airshipReturnDrift) or 5
          local lockDx = (tonumber(state.position.x) or 0) - airshipArrivalLock.x
          local lockDz = (tonumber(state.position.z) or 0) - airshipArrivalLock.z
          if math.sqrt(lockDx * lockDx + lockDz * lockDz) <= driftLimit then
            commands.__airshipArrived = true
            save(MODE_PATH, { mode = "hover" })
            mode = "hover"
          else
            airshipArrivalLock = nil
            guidance.arrived = false
          end
        else
          airshipArrivalLock = nil
          save(MODE_PATH, { mode = "hover" })
          mode = "hover"
        end
      else
        airshipArrivalLock = nil
        local headingError = Director.headingError(state.heading, guidance.desiredHeading)
        local headingAlignment = guidance.desiredHeading and state.heading and select(2, Director.headingError(state.heading, guidance.desiredHeading)) or 0
        if headingAlignment and headingAlignment < -0.95 and guidance.desiredHeading then
          local reversedHeading = { x = -guidance.desiredHeading.x, y = 0, z = -guidance.desiredHeading.z }
          local reversedError, reversedAlignment = Director.headingError(state.heading, reversedHeading)
          if reversedAlignment and reversedAlignment > 0.5 then
            headingError, headingAlignment = reversedError, reversedAlignment
            guidance.desiredHeading = reversedHeading
          end
        end
        local holdYawForAltitude = guidance.altitudePhase == "final-altitude"
          or (guidance.altitudePhase == "horizontal-cruise" and not guidance.cruiseAltitudeReady and not guidance.airshipMode)
        local finalHeadingReached = true
        if guidance.finalHeading then
          local finalHeadingError = Director.headingError(state.heading, guidance.finalHeading)
          local headingTolerance = math.rad(math.max(0, tonumber((config.navigation or {}).headingTolerance) or 4))
          finalHeadingReached = finalHeadingError ~= nil and math.abs(finalHeadingError) <= headingTolerance
          if guidance.finalCapture and not holdYawForAltitude then headingError = finalHeadingError end
        end
        if holdYawForAltitude then
          headingPID:reset()
        elseif guidance.finalCapture and finalHeadingReached then
          headingPID:reset()
        elseif headingError then
          local navigation = config.navigation or {}
          local yawTolerance = math.rad(math.max(0, tonumber(navigation.cruiseHeadingTolerance) or tonumber(navigation.headingTolerance) or 4))
          if guidance.airshipMode then
            yawTolerance = math.rad(math.max(math.deg(yawTolerance), tonumber(navigation.airshipHeadingTolerance) or 15))
          end
          if math.abs(headingError) <= yawTolerance then
            headingPID:reset()
          else
            local yaw = headingPID:update(headingError, dt)
            splitAxis(yaw, "left", "right", commands)
          end
        else
          local yaw = headingPID:update(headingError or 0, dt)
          splitAxis(yaw, "left", "right", commands)
        end

        local airshipCruiseGate = guidance.airshipMode and guidance.altitudePhase == "horizontal-cruise"
        if guidance.altitudePhase == "horizontal-cruise" and guidance.cruiseAltitudeReady then
          altitudePID:reset()
        else
          local vertical = altitudePID:update(guidance.altitudeError or 0, dt, state.verticalSpeed)
          splitAxis(vertical, "up", "down", commands)
        end
        if airshipCruiseGate then
          guidance.cruiseAltitudeReady = math.max(commands.up or 0, commands.down or 0) >= 1
        end
        local acquiringCruiseAltitude = guidance.altitudePhase == "horizontal-cruise" and not guidance.cruiseAltitudeReady
        if not acquiringCruiseAltitude and math.abs(guidance.altitudeError or 0) <= (tonumber(guidance.finalVerticalRadius) or 15) then
          local limit = math.max(1, math.min(15, tonumber(guidance.finalVerticalOutputMaximum) or 2))
          local upLimit = math.max(limit, math.min(15, tonumber(guidance.finalVerticalUpOutputMaximum) or 3))
          local maximum = math.max(1, math.min(15, tonumber((config.safety or {}).maximumOutput) or 15))
          local normalizedLimit = limit / maximum
          local normalizedUpLimit = upLimit / maximum
          commands.up = math.min(commands.up or 0, normalizedUpLimit)
          commands.down = math.min(commands.down or 0, normalizedLimit)
        end

        headingAlignment = holdYawForAltitude and 1 or headingAlignment
        local speed = horizontalSpeedAlong(state, guidance.desiredHeading)
        if guidance.altitudePhase == "horizontal-cruise" and not guidance.cruiseAltitudeReady and not guidance.airshipMode then guidance.desiredSpeed = 0 end
        local thrust = speedPID:update((guidance.desiredSpeed or 0) - speed, dt)
        local inPositioningZone = guidance.horizontalDistance and guidance.finalOutputRadius and guidance.horizontalDistance <= guidance.finalOutputRadius
        if not headingAlignment or headingAlignment < tonumber(fc.minimumThrustAlignment or 0.9) then
          thrust = 0
          speedPID:reset()
          if headingError and math.abs(headingError) > math.rad(0.5) and (commands.left or 0) == 0 and (commands.right or 0) == 0 then
            local maximum = math.max(1, math.min(15, tonumber((config.safety or {}).maximumOutput) or 15))
            local yaw = (tonumber(fc.minimumYawOutput) or 1) / maximum
            splitAxis(headingError > 0 and yaw or -yaw, "left", "right", commands)
          end
          if not inPositioningZone and guidance.horizontalDistance and (guidance.horizontalDistance > (guidance.brakeRadius or 75)) and headingAlignment and headingAlignment > 0.5 and (guidance.desiredSpeed or 0) > 0 then
            local maximum = math.max(1, math.min(15, tonumber((config.safety or {}).maximumOutput) or 15))
            thrust = math.max(1, math.min(15, tonumber(fc.minimumForwardOutput) or 2)) / maximum
          end
        end
        if guidance.shouldBrake then
          speedPID:reset()
          local brake = math.min(1, math.max(0.25, (guidance.approachSpeedAlong or 0) / math.max(1, tonumber((config.navigation or {}).cruiseSpeed) or 12)))
          splitAxis(inPositioningZone and -brake or 0, "forward", "reverse", commands)
        elseif guidance.finalCapture then
          speedPID:reset()
        else
          if not inPositioningZone then thrust = math.max(0, thrust) end
          if headingAlignment and headingAlignment >= tonumber(fc.minimumThrustAlignment or 0.9) and guidance.horizontalDistance and guidance.finalOutputRadius and guidance.horizontalDistance > guidance.finalOutputRadius and (guidance.desiredSpeed or 0) > 0 then
            local maximum = math.max(1, math.min(15, tonumber((config.safety or {}).maximumOutput) or 15))
            thrust = math.max(thrust, math.max(1, math.min(15, tonumber(fc.minimumForwardOutput) or 2)) / maximum)
          end
          splitAxis(thrust, "forward", "reverse", commands)
        end
        if guidance.horizontalDistance and guidance.finalOutputRadius and guidance.horizontalDistance <= guidance.finalOutputRadius then
          local limit = math.max(1, math.min(15, tonumber(guidance.finalOutputMaximum) or 2))
          local maximum = math.max(1, math.min(15, tonumber((config.safety or {}).maximumOutput) or 15))
          local normalizedLimit = limit / maximum
          commands.forward = math.min(commands.forward or 0, normalizedLimit)
          commands.reverse = math.min(commands.reverse or 0, normalizedLimit)
        end
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

  local okApplied, applied = pcall(writeOutputs, config, commands)
  if not okApplied then applied = {} end

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
  print("CC-NavTool Sable Flight Core")
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

print("Starting Sable-native flight core...")
local ok, err = pcall(parallel.waitForAny, loop, controls)
if not ok then printError(err) end
clearOutputs(config)
recorder:close()
