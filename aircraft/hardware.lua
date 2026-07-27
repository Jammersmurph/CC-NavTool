local Hardware = {}

local PREFIX = "@relay/"
local SIDES = { "top", "bottom", "left", "right", "front", "back" }
local CONTROLS = { "forward", "reverse", "left", "right", "up", "down" }

local native = {
  setOutput = redstone.setOutput,
  setAnalogOutput = redstone.setAnalogOutput,
  setAnalogueOutput = redstone.setAnalogueOutput,
  getOutput = redstone.getOutput,
  getAnalogOutput = redstone.getAnalogOutput,
  getAnalogueOutput = redstone.getAnalogueOutput,
}

local function hasType(name, wanted)
  if type(peripheral.hasType) == "function" then
    local ok, value = pcall(peripheral.hasType, name, wanted)
    if ok and value then return true end
  end
  local ok, value = pcall(peripheral.getType, name)
  if not ok then return false end
  if type(value) == "table" then
    for _, kind in ipairs(value) do if kind == wanted then return true end end
    return false
  end
  return value == wanted
end

local function validSide(side)
  for _, value in ipairs(SIDES) do if side == value then return true end end
  return false
end

local function validControl(control)
  for _, value in ipairs(CONTROLS) do if control == value then return true end end
  return false
end

function Hardware.encodeRelay(name, side)
  return PREFIX .. tostring(name) .. "/" .. tostring(side)
end

function Hardware.decodeSide(value)
  value = tostring(value or "")
  if value:sub(1, #PREFIX) ~= PREFIX then return { kind = "local", side = value } end
  local body = value:sub(#PREFIX + 1)
  local split = body:match("^.*()/")
  if not split then return nil end
  local name, side = body:sub(1, split - 1), body:sub(split + 1)
  if name == "" or not validSide(side) then return nil end
  return { kind = "relay", peripheral = name, side = side }
end

function Hardware.relays()
  local result = {}
  for _, name in ipairs(peripheral.getNames()) do
    if hasType(name, "redstone_relay") then result[#result + 1] = name end
  end
  table.sort(result)
  return result
end

local function callRelay(target, method, ...)
  if not target or target.kind ~= "relay" then return false end
  if not peripheral.isPresent(target.peripheral) or not hasType(target.peripheral, "redstone_relay") then
    return false, "relay unavailable: " .. tostring(target.peripheral)
  end
  local ok, result = pcall(peripheral.call, target.peripheral, method, target.side, ...)
  if not ok then return false, result end
  return true, result
end

function Hardware.installRedstoneProxy()
  if Hardware._installed then return end
  Hardware._installed = true

  redstone.setOutput = function(side, on)
    local target = Hardware.decodeSide(side)
    if target and target.kind == "relay" then
      local ok, err = callRelay(target, "setOutput", on == true)
      if not ok then error(err, 2) end
      return
    end
    return native.setOutput(side, on)
  end

  redstone.setAnalogOutput = function(side, value)
    local target = Hardware.decodeSide(side)
    if target and target.kind == "relay" then
      local ok, err = callRelay(target, "setAnalogOutput", value)
      if not ok then error(err, 2) end
      return
    end
    return native.setAnalogOutput(side, value)
  end
  redstone.setAnalogueOutput = redstone.setAnalogOutput

  redstone.getOutput = function(side)
    local target = Hardware.decodeSide(side)
    if target and target.kind == "relay" then
      local ok, value = callRelay(target, "getOutput")
      if not ok then error(value, 2) end
      return value
    end
    return native.getOutput(side)
  end

  redstone.getAnalogOutput = function(side)
    local target = Hardware.decodeSide(side)
    if target and target.kind == "relay" then
      local ok, value = callRelay(target, "getAnalogOutput")
      if not ok then error(value, 2) end
      return value
    end
    return native.getAnalogOutput(side)
  end
  redstone.getAnalogueOutput = redstone.getAnalogOutput
end

local function outputTargets(output)
  if type(output) ~= "table" then return {} end
  if type(output.targets) == "table" then return output.targets end
  if output.side then return { output } end
  return {}
end

local function describeTarget(output)
  local target = output and Hardware.decodeSide(output.side) or nil
  return {
    kind = target and target.kind or "unassigned",
    peripheral = target and target.peripheral or nil,
    side = target and target.side or nil,
    analog = not output or output.analog ~= false,
    inverted = output and output.inverted == true or false,
    maximum = output and tonumber(output.maximum) or nil,
    available = target and (target.kind == "local" or peripheral.isPresent(target.peripheral)) or false,
  }
end

local function configuredTarget(request, encodedSide)
  return {
    side = encodedSide,
    analog = request.analog ~= false,
    inverted = request.inverted == true,
    maximum = math.max(0, math.min(15, tonumber(request.maximum) or 15)),
  }
end

local function clearTarget(output)
  if type(output) == "table" and output.side then
    pcall(redstone.setAnalogOutput, output.side, 0)
    pcall(redstone.setOutput, output.side, false)
  end
end

function Hardware.describe(config)
  local assignments = {}
  for _, control in ipairs(CONTROLS) do
    local output = type(config.outputs) == "table" and config.outputs[control] or nil
    local targets = outputTargets(output)
    local described = {}
    local allAvailable = #targets > 0
    for index, targetOutput in ipairs(targets) do
      described[index] = describeTarget(targetOutput)
      if described[index].available == false then allAvailable = false end
    end
    local first = described[1] or describeTarget(nil)
    assignments[control] = {
      control = control,
      kind = #described > 1 and "multi" or first.kind,
      peripheral = first.peripheral,
      side = first.side,
      analog = first.analog,
      inverted = first.inverted,
      maximum = first.maximum,
      available = allAvailable,
      count = #described,
      targets = described,
    }
  end
  return { relays = Hardware.relays(), assignments = assignments, sides = SIDES, controls = CONTROLS }
end

function Hardware.assign(config, request)
  local control = tostring(request.control or "")
  local kind = tostring(request.kind or "local")
  local side = tostring(request.side or "")
  if not validControl(control) then return false, "invalid control" end
  if not validSide(side) then return false, "invalid side" end
  config.outputs = type(config.outputs) == "table" and config.outputs or {}
  local output = config.outputs[control] or {}
  local encodedSide
  if kind == "relay" then
    local name = tostring(request.peripheral or "")
    if name == "" or not peripheral.isPresent(name) or not hasType(name, "redstone_relay") then
      return false, "redstone relay unavailable"
    end
    encodedSide = Hardware.encodeRelay(name, side)
  elseif kind == "local" then
    encodedSide = side
  else
    return false, "invalid device kind"
  end
  local target = configuredTarget(request, encodedSide)
  if request.add == true then
    local targets = {}
    for _, existing in ipairs(outputTargets(output)) do targets[#targets + 1] = existing end
    targets[#targets + 1] = target
    config.outputs[control] = { targets = targets }
  else
    config.outputs[control] = target
  end
  return true, Hardware.describe(config).assignments[control]
end

function Hardware.unassign(config, request)
  local control = tostring(request.control or "")
  if not validControl(control) then return false, "invalid control" end
  config.outputs = type(config.outputs) == "table" and config.outputs or {}
  local output = config.outputs[control]
  local targets = outputTargets(output)
  if #targets == 0 then return false, "control is unassigned" end

  local index = tonumber(request.index)
  if request.all == true or not index then
    for _, target in ipairs(targets) do clearTarget(target) end
    config.outputs[control] = nil
  else
    index = math.floor(index)
    if index < 1 or index > #targets then return false, "invalid binding number" end
    clearTarget(targets[index])
    table.remove(targets, index)
    if #targets == 0 then
      config.outputs[control] = nil
    elseif #targets == 1 then
      config.outputs[control] = targets[1]
    else
      config.outputs[control] = { targets = targets }
    end
  end

  return true, Hardware.describe(config).assignments[control]
end

function Hardware.test(config, control, strength)
  local output = type(config.outputs) == "table" and config.outputs[tostring(control or "")] or nil
  local targets = outputTargets(output)
  if #targets == 0 then return false, "control is unassigned" end
  local value = math.max(0, math.min(15, tonumber(strength) or 5))
  for _, target in ipairs(targets) do
    local ok, err
    if target.analog == false then ok, err = pcall(redstone.setOutput, target.side, value > 0)
    else ok, err = pcall(redstone.setAnalogOutput, target.side, value) end
    if not ok then return false, err end
  end
  sleep(0.25)
  for _, target in ipairs(targets) do
    if target.analog == false then pcall(redstone.setOutput, target.side, false)
    else pcall(redstone.setAnalogOutput, target.side, 0) end
  end
  return true
end

return Hardware
