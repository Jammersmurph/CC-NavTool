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

function Hardware.describe(config)
  local assignments = {}
  for _, control in ipairs(CONTROLS) do
    local output = type(config.outputs) == "table" and config.outputs[control] or nil
    local target = output and Hardware.decodeSide(output.side) or nil
    assignments[control] = {
      control = control,
      kind = target and target.kind or "unassigned",
      peripheral = target and target.peripheral or nil,
      side = target and target.side or nil,
      analog = not output or output.analog ~= false,
      inverted = output and output.inverted == true or false,
      maximum = output and tonumber(output.maximum) or nil,
      available = target and (target.kind == "local" or peripheral.isPresent(target.peripheral)) or false,
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
  if kind == "relay" then
    local name = tostring(request.peripheral or "")
    if name == "" or not peripheral.isPresent(name) or not hasType(name, "redstone_relay") then
      return false, "redstone relay unavailable"
    end
    output.side = Hardware.encodeRelay(name, side)
  elseif kind == "local" then
    output.side = side
  else
    return false, "invalid device kind"
  end
  output.analog = request.analog ~= false
  output.inverted = request.inverted == true
  output.maximum = math.max(0, math.min(15, tonumber(request.maximum) or tonumber(output.maximum) or 15))
  config.outputs[control] = output
  return true, Hardware.describe(config).assignments[control]
end

function Hardware.test(config, control, strength)
  local output = type(config.outputs) == "table" and config.outputs[tostring(control or "")] or nil
  if not output or not output.side then return false, "control is unassigned" end
  local value = math.max(0, math.min(15, tonumber(strength) or 5))
  local ok, err
  if output.analog == false then ok, err = pcall(redstone.setOutput, output.side, value > 0)
  else ok, err = pcall(redstone.setAnalogOutput, output.side, value) end
  if not ok then return false, err end
  sleep(0.25)
  if output.analog == false then pcall(redstone.setOutput, output.side, false)
  else pcall(redstone.setAnalogOutput, output.side, 0) end
  return true
end

return Hardware
