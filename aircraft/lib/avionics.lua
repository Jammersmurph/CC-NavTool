local Avionics = {}

local function has(list, wanted)
  for _, value in ipairs(list) do if value == wanted then return true end end
  return false
end

local function hasType(name, wanted)
  if type(peripheral.hasType) == "function" then
    local ok, value = pcall(peripheral.hasType, name, wanted)
    if ok and value then return true end
  end
  local ok, value = pcall(peripheral.getType, name)
  if not ok then return false end
  if type(value) == "table" then return has(value, wanted) end
  return value == wanted
end

local function findType(configured, wanted)
  if configured and peripheral.isPresent(configured) then return configured end
  for _, name in ipairs(peripheral.getNames()) do
    if hasType(name, wanted) then return name end
  end
end

local function findAll(wanted)
  local result = {}
  for _, name in ipairs(peripheral.getNames()) do
    if hasType(name, wanted) then result[#result + 1] = name end
  end
  return result
end

local function call(name, method)
  if not name then return nil end
  local ok, a, b, c = pcall(peripheral.call, name, method)
  if not ok then return nil end
  if b ~= nil and c ~= nil and tonumber(a) and tonumber(b) and tonumber(c) then
    return { x = tonumber(a), y = tonumber(b), z = tonumber(c) }
  end
  return a
end

local function vector(value)
  if type(value) ~= "table" then return nil end
  local source = value.position or value.pos or value.translation or value.location or value.vector or value
  if type(source) ~= "table" then return nil end
  local x = tonumber(source.x or source.X or source[1])
  local y = tonumber(source.y or source.Y or source[2])
  local z = tonumber(source.z or source.Z or source[3])
  if x and y and z then return { x = x, y = y, z = z } end
end

local function horizontalHeading(degrees, format, offset)
  degrees = tonumber(degrees)
  if not degrees then return nil end
  local angle = math.rad(degrees + (tonumber(offset) or 0))
  if format == "compass" or format == "bearing" then
    return { x = math.sin(angle), y = 0, z = -math.cos(angle) }
  end
  return { x = math.sin(angle), y = 0, z = math.cos(angle) }
end

local function magnitude(value)
  value = vector(value)
  if not value then return nil end
  return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
end

function Avionics.discover(config)
  config = config or {}
  return {
    navigationTable = findType(config.navigationTablePeripheral, "navigation_table"),
    gimbalSensor = findType(config.gimbalSensorPeripheral, "gimbal_sensor"),
    altitudeSensor = findType(config.altitudeSensorPeripheral, "altitude_sensor"),
    physicsAssembler = findType(config.physicsAssemblerPeripheral, "physics_assembler"),
    velocitySensors = findAll("velocity_sensor"),
  }
end

function Avionics.read(config, discovered, detail)
  config = config or {}
  discovered = discovered or Avionics.discover(config)
  local orientation = config.orientation or {}
  local state = {
    source = "create-avionics+sable",
    peripherals = discovered,
    healthy = false,
  }

  if type(sublevel) == "table" then
    local ok, rawPose = pcall(function()
      if type(sublevel.getLogicalPose) == "function" then return sublevel.getLogicalPose() end
      if type(sublevel.getLastPose) == "function" then return sublevel.getLastPose() end
    end)
    if ok and rawPose ~= nil then
      state.pose = rawPose
      state.position = vector(rawPose)
    end

    local okVelocity, rawVelocity = pcall(function()
      if type(sublevel.getLinearVelocity) == "function" then return sublevel.getLinearVelocity() end
      if type(sublevel.getVelocity) == "function" then return sublevel.getVelocity() end
    end)
    if okVelocity then state.velocity = vector(rawVelocity) end

    local okAngular, angular = pcall(function()
      if type(sublevel.getAngularVelocity) == "function" then return sublevel.getAngularVelocity() end
    end)
    if okAngular then state.angularVelocity = vector(angular) or angular end
  end

  if discovered.navigationTable then
    state.headingDegrees = tonumber(call(discovered.navigationTable, "getHeading"))
    if not state.headingDegrees then
      local radians = tonumber(call(discovered.navigationTable, "getHeadingRad"))
      if radians then state.headingDegrees = math.deg(radians) end
    end
    state.heading = horizontalHeading(state.headingDegrees, tostring(orientation.yawFormat or "avionics"):lower(), orientation.yawOffset)
    if detail then state.orientation = call(discovered.navigationTable, "getOrientation") end
  end

  if discovered.altitudeSensor then
    state.altitude = tonumber(call(discovered.altitudeSensor, "getHeight"))
    state.verticalSpeed = tonumber(call(discovered.altitudeSensor, "getVerticalSpeed"))
    if state.position and state.altitude then state.position.y = state.altitude end
    if state.velocity and state.verticalSpeed then state.velocity.y = state.verticalSpeed end
  end

  if discovered.gimbalSensor then
    state.gimbalAngles = call(discovered.gimbalSensor, "getAngles")
    state.gimbalAngularRates = call(discovered.gimbalSensor, "getAngularRates")
    if not state.angularVelocity then state.angularVelocity = vector(state.gimbalAngularRates) or state.gimbalAngularRates end
    if detail then
      state.gravity = call(discovered.gimbalSensor, "getGravity")
      state.linearAcceleration = call(discovered.gimbalSensor, "getLinearAcceleration")
    end
  end

  local bodyVelocity = {}
  for _, name in ipairs(discovered.velocitySensors or {}) do
    local axis = tostring(call(name, "getAxis") or ""):lower()
    local speed = tonumber(call(name, "getVelocity"))
    if axis ~= "" and speed then bodyVelocity[axis] = speed end
  end
  if next(bodyVelocity) then state.bodyVelocity = bodyVelocity end

  if discovered.physicsAssembler then
    state.mass = tonumber(call(discovered.physicsAssembler, "getMass"))
    if detail then
      state.centerOfMass = call(discovered.physicsAssembler, "getCenterOfMass")
      state.subLevelId = call(discovered.physicsAssembler, "getSubLevelId")
      state.subLevelName = call(discovered.physicsAssembler, "getSubLevelName")
    end
  end

  state.speed = magnitude(state.velocity)
  state.healthy = state.position ~= nil and state.heading ~= nil
  state.degraded = state.position == nil or state.heading == nil or state.altitude == nil
  return state
end

return Avionics
