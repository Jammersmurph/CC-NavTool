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

local function magnitude(value)
  value = vector(value)
  if not value then return nil end
  return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
end

local function normalize(value)
  value = vector(value)
  local length = magnitude(value)
  if not value or not length or length < 0.000001 then return nil end
  return { x = value.x / length, y = value.y / length, z = value.z / length }
end

local function cross(a, b)
  return {
    x = a.y * b.z - a.z * b.y,
    y = a.z * b.x - a.x * b.z,
    z = a.x * b.y - a.y * b.x,
  }
end

local function quaternion(value)
  if type(value) ~= "table" then return nil end
  local scalar = tonumber(value.a or value.w or value[1])
  local rawVector = value.v or value.vector
  local x = tonumber(rawVector and (rawVector.x or rawVector[1]) or value.x or value[2])
  local y = tonumber(rawVector and (rawVector.y or rawVector[2]) or value.y or value[3])
  local z = tonumber(rawVector and (rawVector.z or rawVector[3]) or value.z or value[4])
  if not scalar or not x or not y or not z then return nil end
  local length = math.sqrt(scalar * scalar + x * x + y * y + z * z)
  if length < 0.000001 then return nil end
  return { a = scalar / length, v = { x = x / length, y = y / length, z = z / length } }
end

local function rotate(q, value)
  value = vector(value)
  if not q or not value then return nil end
  local uv = cross(q.v, value)
  local uuv = cross(q.v, uv)
  return {
    x = value.x + 2 * (q.a * uv.x + uuv.x),
    y = value.y + 2 * (q.a * uv.y + uuv.y),
    z = value.z + 2 * (q.a * uv.z + uuv.z),
  }
end

local function rotateLocalYaw(value, degrees)
  value = vector(value)
  degrees = tonumber(degrees) or 0
  if not value or degrees == 0 then return value end
  local radians = math.rad(degrees)
  local sinValue, cosValue = math.sin(radians), math.cos(radians)
  return {
    x = value.x * cosValue + value.z * sinValue,
    y = value.y,
    z = value.z * cosValue - value.x * sinValue,
  }
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

local function headingDegrees(heading)
  heading = normalize({ x = heading and heading.x, y = 0, z = heading and heading.z })
  if not heading then return nil end
  local degrees = math.deg(math.atan2(heading.x, heading.z))
  return (degrees + 180) % 360 - 180
end

local function attitudeFromPose(rawPose, orientation)
  if type(rawPose) ~= "table" then return nil end
  local q = quaternion(rawPose.orientation or rawPose.rotation or rawPose.quaternion)
  if not q then return nil end

  local localForward = normalize(rotateLocalYaw(orientation.forward or { x = 0, y = 0, z = 1 }, orientation.yawOffset))
  local localUp = normalize(orientation.up or { x = 0, y = 1, z = 0 })
  if not localForward or not localUp then return nil end
  local localRight = normalize(cross(localForward, localUp))
  if not localRight then return nil end

  local forward = normalize(rotate(q, localForward))
  local up = normalize(rotate(q, localUp))
  local right = normalize(rotate(q, localRight))
  if not forward or not up or not right then return nil end

  local horizontalForward = normalize({ x = forward.x, y = 0, z = forward.z })
  return {
    quaternion = q,
    forward = forward,
    right = right,
    up = up,
    horizontalForward = horizontalForward,
    source = "cc-sable-quaternion",
    full3D = true,
  }
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
    source = "telemetry-unavailable",
    peripherals = discovered,
    healthy = false,
  }

  if config.sublevelEnabled ~= false and type(sublevel) == "table" then
    local ok, rawPose = pcall(function()
      if type(sublevel.getLogicalPose) == "function" then return sublevel.getLogicalPose() end
      if type(sublevel.getLastPose) == "function" then return sublevel.getLastPose() end
    end)
    if ok and rawPose ~= nil then
      state.pose = rawPose
      state.position = vector(rawPose)
      state.attitude = attitudeFromPose(rawPose, orientation)
      if state.attitude then
        state.orientation = state.attitude.quaternion
        state.heading = state.attitude.horizontalForward
        state.headingDegrees = headingDegrees(state.heading)
        state.orientationSource = state.attitude.source
      end
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

  -- Create: Avionics remains a fallback and optional source of additional sensors.
  if discovered.navigationTable and not state.heading then
    state.headingDegrees = tonumber(call(discovered.navigationTable, "getHeading"))
    if not state.headingDegrees then
      local radians = tonumber(call(discovered.navigationTable, "getHeadingRad"))
      if radians then state.headingDegrees = math.deg(radians) end
    end
    state.heading = horizontalHeading(state.headingDegrees, tostring(orientation.yawFormat or "avionics"):lower(), orientation.yawOffset)
    if state.heading then state.orientationSource = "create-avionics-navigation-table" end
    if detail then state.orientation = call(discovered.navigationTable, "getOrientation") end
  end

  if discovered.altitudeSensor then
    state.altitude = tonumber(call(discovered.altitudeSensor, "getHeight"))
    state.verticalSpeed = tonumber(call(discovered.altitudeSensor, "getVerticalSpeed"))
    if state.position and state.altitude then state.position.y = state.altitude end
    if state.velocity and state.verticalSpeed then state.velocity.y = state.verticalSpeed end
  elseif state.position then
    state.altitude = state.position.y
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
  if state.velocity and state.attitude then
    bodyVelocity.forward = state.velocity.x * state.attitude.forward.x + state.velocity.y * state.attitude.forward.y + state.velocity.z * state.attitude.forward.z
    bodyVelocity.right = state.velocity.x * state.attitude.right.x + state.velocity.y * state.attitude.right.y + state.velocity.z * state.attitude.right.z
    bodyVelocity.up = state.velocity.x * state.attitude.up.x + state.velocity.y * state.attitude.up.y + state.velocity.z * state.attitude.up.z
  end
  for _, name in ipairs(discovered.velocitySensors or {}) do
    local axis = tostring(call(name, "getAxis") or ""):lower()
    local axisSpeed = tonumber(call(name, "getVelocity"))
    if axis ~= "" and axisSpeed then bodyVelocity[axis] = axisSpeed end
  end
  if next(bodyVelocity) then state.bodyVelocity = bodyVelocity end

  if discovered.physicsAssembler then
    state.mass = tonumber(call(discovered.physicsAssembler, "getMass"))
    if detail then
      state.centerOfMass = call(discovered.physicsAssembler, "getCenterOfMass")
      state.subLevelId = call(discovered.physicsAssembler, "getSubLevelId")
      state.subLevelName = call(discovered.physicsAssembler, "getSubLevelName")
    end
  elseif type(sublevel) == "table" and type(sublevel.getMass) == "function" then
    local okMass, mass = pcall(sublevel.getMass)
    if okMass then state.mass = tonumber(mass) end
  end

  state.speed = magnitude(state.velocity)
  state.verticalSpeed = state.verticalSpeed or (state.velocity and state.velocity.y)
  state.healthy = state.position ~= nil and state.heading ~= nil
  state.degraded = state.position == nil or state.heading == nil or state.velocity == nil
  if state.attitude then
    state.source = "cc-sable"
  elseif state.heading then
    state.source = "create-avionics"
  end
  return state
end

Avionics.attitudeFromPose = attitudeFromPose
Avionics.quaternion = quaternion
Avionics.rotateVector = rotate

return Avionics
