local VERSION = "0.5.9-nightly"
local ROOT = "/navtool"
local CONFIG_PATH = ROOT .. "/config.lua"
local TARGET_PATH = ROOT .. "/target.db"
local WAYPOINTS_PATH = ROOT .. "/waypoints.db"
local MODE_PATH = ROOT .. "/mode.db"
local SCHEDULES_PATH = ROOT .. "/schedules.db"
local ACTIVE_SCHEDULE_PATH = ROOT .. "/active_schedule.db"
local args = { ... }
local buttons = {}
local ScheduleDirector = dofile(ROOT .. "/lib/flight_director.lua")

local function loadHardware()
  local paths = { ROOT .. "/hardware.lua", "/hardware.lua", "hardware.lua" }
  for _, path in ipairs(paths) do
    if fs.exists(path) then
      local ok, module = pcall(dofile, path)
      if ok and type(module) == "table" then return module, path end
    end
  end

  local module = {}
  local prefix = "@relay/"
  local sides = { "top", "bottom", "left", "right", "front", "back" }
  local controls = { "forward", "reverse", "left", "right", "up", "down" }
  local native = {
    setOutput = redstone.setOutput,
    setAnalogOutput = redstone.setAnalogOutput,
    setAnalogueOutput = redstone.setAnalogueOutput,
    getOutput = redstone.getOutput,
    getAnalogOutput = redstone.getAnalogOutput,
    getAnalogueOutput = redstone.getAnalogueOutput,
  }
  local function validSide(side) for _, value in ipairs(sides) do if side == value then return true end end; return false end
  local function validControl(control) for _, value in ipairs(controls) do if control == value then return true end end; return false end
  local function hasType(name, wanted)
    if type(peripheral.hasType) == "function" then local ok, value = pcall(peripheral.hasType, name, wanted); if ok and value then return true end end
    local ok, value = pcall(peripheral.getType, name)
    if not ok then return false end
    if type(value) == "table" then for _, kind in ipairs(value) do if kind == wanted then return true end end; return false end
    return value == wanted
  end
  local function isRelay(name)
    for _, kind in ipairs({ "redstone_relay", "redstoneRelay", "redstone relay" }) do if hasType(name, kind) then return true end end
    if type(peripheral.getMethods) ~= "function" then return false end
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then return false end
    for _, method in ipairs({ "setAnalogOutput", "setAnalogueOutput", "setOutput" }) do
      for _, available in ipairs(methods) do if available == method then return true end end
    end
    return false
  end
  function module.encodeRelay(name, side) return prefix .. tostring(name) .. "/" .. tostring(side) end
  function module.decodeSide(value)
    value = tostring(value or "")
    if value:sub(1, #prefix) ~= prefix then return { kind = "local", side = value } end
    local body = value:sub(#prefix + 1)
    local split = body:match("^.*()/")
    if not split then return nil end
    local name, side = body:sub(1, split - 1), body:sub(split + 1)
    if name == "" or not validSide(side) then return nil end
    return { kind = "relay", peripheral = name, side = side }
  end
  function module.relays()
    local result = {}
    for _, name in ipairs(peripheral.getNames()) do if isRelay(name) then result[#result + 1] = name end end
    table.sort(result)
    return result
  end
  local function callRelay(target, method, ...)
    if not target or target.kind ~= "relay" then return false end
    if not peripheral.isPresent(target.peripheral) or not isRelay(target.peripheral) then return false, "relay unavailable: " .. tostring(target.peripheral) end
    local ok, result = pcall(peripheral.call, target.peripheral, method, target.side, ...)
    if not ok then return false, result end
    return true, result
  end
  function module.installRedstoneProxy()
    if module._installed then return end
    module._installed = true
    redstone.setOutput = function(side, on)
      local target = module.decodeSide(side)
      if target and target.kind == "relay" then local ok, err = callRelay(target, "setOutput", on == true); if not ok then error(err, 2) end; return end
      return native.setOutput(side, on)
    end
    redstone.setAnalogOutput = function(side, value)
      local target = module.decodeSide(side)
      if target and target.kind == "relay" then local ok, err = callRelay(target, "setAnalogOutput", value); if not ok then error(err, 2) end; return end
      return native.setAnalogOutput(side, value)
    end
    redstone.setAnalogueOutput = redstone.setAnalogOutput
    redstone.getOutput = function(side)
      local target = module.decodeSide(side)
      if target and target.kind == "relay" then local ok, value = callRelay(target, "getOutput"); if not ok then error(value, 2) end; return value end
      return native.getOutput(side)
    end
    redstone.getAnalogOutput = function(side)
      local target = module.decodeSide(side)
      if target and target.kind == "relay" then local ok, value = callRelay(target, "getAnalogOutput"); if not ok then error(value, 2) end; return value end
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
    local target = output and module.decodeSide(output.side) or nil
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
    return { side = encodedSide, analog = request.analog ~= false, inverted = request.inverted == true, maximum = math.max(0, math.min(15, tonumber(request.maximum) or 15)) }
  end
  local function clearTarget(output)
    if type(output) == "table" and output.side then pcall(redstone.setAnalogOutput, output.side, 0); pcall(redstone.setOutput, output.side, false) end
  end
  function module.describe(config)
    config.hardware = type(config.hardware) == "table" and config.hardware or {}
    local assignments, airshipVertical = {}, nil
    for _, control in ipairs(controls) do
      local output = type(config.outputs) == "table" and config.outputs[control] or nil
      local targets = outputTargets(output)
      local described, allAvailable = {}, #targets > 0
      for index, targetOutput in ipairs(targets) do described[index] = describeTarget(targetOutput); if described[index].available == false then allAvailable = false end end
      local first = described[1] or describeTarget(nil)
      assignments[control] = { control = control, kind = #described > 1 and "multi" or first.kind, peripheral = first.peripheral, side = first.side, analog = first.analog, inverted = first.inverted, maximum = first.maximum, available = allAvailable, count = #described, targets = described }
    end
    for _, control in ipairs({ "up", "down" }) do
      local output = type(config.outputs) == "table" and config.outputs[control] or nil
      local target = outputTargets(output)[1]
      if type(target) == "table" and target.side then local ok, value = pcall(redstone.getAnalogOutput, target.side); if ok then airshipVertical = tonumber(value) or 0; break end end
    end
    return { relays = module.relays(), assignments = assignments, sides = sides, controls = controls, modes = { airship = config.hardware.airshipMode == true, airshipVertical = airshipVertical }, source = "embedded" }
  end
  function module.setMode(config, request)
    config.hardware = type(config.hardware) == "table" and config.hardware or {}
    if tostring(request.mode or "") ~= "airship" then return false, "invalid hardware mode" end
    config.hardware.airshipMode = request.enabled == true
    return true, module.describe(config)
  end
  function module.assign(config, request)
    local control, kind, side = tostring(request.control or ""), tostring(request.kind or "local"), tostring(request.side or "")
    if not validControl(control) then return false, "invalid control" end
    if not validSide(side) then return false, "invalid side" end
    config.outputs = type(config.outputs) == "table" and config.outputs or {}
    local output = config.outputs[control] or {}
    local encodedSide
    if kind == "relay" then
      local name = tostring(request.peripheral or "")
      if name == "" or not peripheral.isPresent(name) or not isRelay(name) then return false, "redstone relay unavailable" end
      encodedSide = module.encodeRelay(name, side)
    elseif kind == "local" then encodedSide = side
    else return false, "invalid device kind" end
    local target = configuredTarget(request, encodedSide)
    if request.add == true then local targets = {}; for _, existing in ipairs(outputTargets(output)) do targets[#targets + 1] = existing end; targets[#targets + 1] = target; config.outputs[control] = { targets = targets }
    else config.outputs[control] = target end
    return true, module.describe(config).assignments[control]
  end
  function module.unassign(config, request)
    local control = tostring(request.control or "")
    if not validControl(control) then return false, "invalid control" end
    config.outputs = type(config.outputs) == "table" and config.outputs or {}
    local targets = outputTargets(config.outputs[control])
    if #targets == 0 then return false, "control is unassigned" end
    local index = tonumber(request.index)
    if request.all == true or not index then for _, target in ipairs(targets) do clearTarget(target) end; config.outputs[control] = nil
    else
      index = math.floor(index)
      if index < 1 or index > #targets then return false, "invalid binding number" end
      clearTarget(targets[index]); table.remove(targets, index)
      if #targets == 0 then config.outputs[control] = nil elseif #targets == 1 then config.outputs[control] = targets[1] else config.outputs[control] = { targets = targets } end
    end
    return true, module.describe(config).assignments[control]
  end
  function module.test(config, control, strength)
    local output = type(config.outputs) == "table" and config.outputs[tostring(control or "")] or nil
    local targets = outputTargets(output)
    if #targets == 0 then return false, "control is unassigned" end
    local value = math.max(0, math.min(15, tonumber(strength) or 5))
    for _, target in ipairs(targets) do local ok, err; if target.analog == false then ok, err = pcall(redstone.setOutput, target.side, value > 0) else ok, err = pcall(redstone.setAnalogOutput, target.side, value) end; if not ok then return false, err end end
    sleep(0.25)
    for _, target in ipairs(targets) do if target.analog == false then pcall(redstone.setOutput, target.side, false) else pcall(redstone.setAnalogOutput, target.side, 0) end end
    return true
  end
  return module, "embedded"
end

local Hardware, HardwareSource = loadHardware()
if Hardware then Hardware.installRedstoneProxy() end

local lastGpsFix

local function loadConfig()
  local ok, config = pcall(dofile, CONFIG_PATH)
  if not ok or type(config) ~= "table" then return nil, tostring(config) end
  if type(config.network) == "table" and config.network.channel == nil and config.network.protocol ~= nil then
    config.network.channel = config.network.protocol
    config.network.protocol = nil
    config._migrated = true
  end
  config.flightControl = type(config.flightControl) == "table" and config.flightControl or {}
  if config.flightControl.minimumThrustAlignment == nil or (tonumber(config.flightControl.minimumThrustAlignment) or 0) >= 0.985 then
    config.flightControl.minimumThrustAlignment = 0.94
    config._migrated = true
  end
  if type(config.flightControl) == "table" and config.flightControl.minimumYawOutput == nil then
    config.flightControl.minimumYawOutput = 1
    config._migrated = true
  end
  if type(config.flightControl) == "table" and config.flightControl.minimumForwardOutput == nil then
    config.flightControl.minimumForwardOutput = 2
    config._migrated = true
  end
  if type(config.safety) == "table" and tonumber(config.safety.maximumOutput) == 5 then
    config.safety.maximumOutput = 15
    config._migrated = true
  end
  if type(config.navigation) == "table" and (tonumber(config.navigation.cruiseAltitude) or 0) ~= 310 then
    config.navigation.cruiseAltitude = 310
    config._migrated = true
  end
  if type(config.navigation) == "table" and tonumber(config.navigation.settleVelocity) == 0.05 then
    config.navigation.settleVelocity = 0.5
    config._migrated = true
  end
  if type(config.navigation) == "table" and (config.navigation.brakeRadius == nil or tonumber(config.navigation.brakeRadius) == 25) then
    config.navigation.brakeRadius = 75
    config._migrated = true
  end
  if type(config.navigation) == "table" and (tonumber(config.navigation.arrivalRadius) or 0) > 1 then
    config.navigation.arrivalRadius = 1
    config._migrated = true
  end
  if type(config.navigation) == "table" and (tonumber(config.navigation.headingTolerance) or 0) > 4 then
    config.navigation.headingTolerance = 4
    config._migrated = true
  end
  if type(config.navigation) == "table" and config.navigation.finalOutputMaximum == nil then
    config.navigation.finalOutputMaximum = 2
    config._migrated = true
  end
  if type(config.navigation) == "table" and config.navigation.finalOutputRadius == nil then
    config.navigation.finalOutputRadius = 10
    config._migrated = true
  end
  if type(config.navigation) == "table" and (config.navigation.finalVerticalRadius == nil or tonumber(config.navigation.finalVerticalRadius) == 10) then
    config.navigation.finalVerticalRadius = 25
    config._migrated = true
  end
  if type(config.navigation) == "table" and config.navigation.finalVerticalOutputMaximum == nil then
    config.navigation.finalVerticalOutputMaximum = 2
    config._migrated = true
  end
  if type(config.navigation) == "table" and config.navigation.finalVerticalUpOutputMaximum == nil then
    config.navigation.finalVerticalUpOutputMaximum = 3
    config._migrated = true
  end
  return config
end

local function saveConfig(config)
  local file = fs.open(CONFIG_PATH, "w")
  file.write("return " .. textutils.serialize(config) .. "\n")
  file.close()
end

local function prompt(default, label)
  write(label .. " [" .. tostring(default) .. "]: ")
  local value = read()
  if value == "" then return default end
  return value
end

local function promptYesNo(label, default)
  local suffix = default and "Y/n" or "y/N"
  write(label .. " [" .. suffix .. "]: ")
  local value = read():lower()
  if value == "" then return default end
  return value == "y" or value == "yes"
end

local function hasModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then return true end
  end
  return false
end

local function onboarding(config, force)
  if config.onboardingComplete and not force then return config end
  term.clear()
  term.setCursorPos(1, 1)
  print("CC-NavTool First Launch Setup")
  print("This configures aircraft networking for navremote.")
  print("")
  if not hasModem() then
    print("No modem was detected. You can still configure networking now,")
    print("but navtool server needs a wired or wireless/Ender modem later.")
    print("")
  end
  config.network = type(config.network) == "table" and config.network or {}
  local enable = promptYesNo("Enable Rednet remote control", config.network.enabled == true)
  config.network.enabled = enable
  config.network.channel = prompt(config.network.channel or "cc-navtool", "Rednet channel")
  config.network.host = prompt(config.network.host or "navtool-aircraft", "Aircraft host name")
  if enable then
    repeat
      write("Shared key required by navremote: ")
      local key = read("*")
      if key ~= "" then config.network.sharedKey = key; break end
      printError("Shared key cannot be blank when networking is enabled.")
    until false
  else
    config.network.sharedKey = config.network.sharedKey or ""
  end
  config.onboardingComplete = true
  saveConfig(config)
  print("")
  print("Setup saved to " .. CONFIG_PATH)
  if enable then
    print("Remote profile values:")
    print("  Channel: " .. tostring(config.network.channel))
    print("  Host: " .. tostring(config.network.host))
    print("  Shared key: the key you just entered")
  else
    print("Networking is disabled. Run 'navtool setup' to enable it later.")
  end
  print("")
  print("Press Enter to continue.")
  read()
  return config
end

local function methods(name)
  local ok, result = pcall(peripheral.getMethods, name)
  return ok and result or {}
end

local function has(list, wanted)
  for _, value in ipairs(list) do if value == wanted then return true end end
  return false
end

local function peripheralHasType(name, wanted)
  if type(peripheral.hasType) == "function" then
    local ok, result = pcall(peripheral.hasType, name, wanted)
    if ok then return result end
  end
  local ok, result = pcall(peripheral.getType, name)
  if not ok then return false end
  if type(result) == "table" then return has(result, wanted) end
  return result == wanted
end

local function findPeripheralByType(configName, config, wanted)
  local configured = config[configName]
  if configured and peripheral.isPresent(configured) then return configured end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheralHasType(name, wanted) then return name end
  end
end

local function findPeripheralsByType(wanted)
  local found = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheralHasType(name, wanted) then found[#found + 1] = name end
  end
  return found
end

local function sublevelAvailable(config)
  if config.sublevelEnabled == false then return false end
  if type(sublevel) ~= "table" then return false end
  if type(sublevel.isInPlotGrid) == "function" then
    local ok, result = pcall(sublevel.isInPlotGrid)
    return ok and result == true
  end
  return type(sublevel.getLogicalPose) == "function"
end

local function callSublevel(method)
  if type(sublevel) ~= "table" or type(sublevel[method]) ~= "function" then return nil end
  local ok, value = pcall(sublevel[method])
  if ok then return value end
end

local function telemetryName(config)
  if config.telemetryPeripheral and peripheral.isPresent(config.telemetryPeripheral) then
    return config.telemetryPeripheral
  end
  for _, name in ipairs(peripheral.getNames()) do
    local available = methods(name)
    if has(available, "getLogicalPose") or has(available, "getPose") or has(available, "getPosition") or has(available, "getShipPosition") or (has(available, "getX") and has(available, "getY") and has(available, "getZ")) or (has(available, "getLinearVelocity") and has(available, "getAngularVelocity")) then
      return name
    end
  end
end

local function orientationName(config, telemetry)
  if config.orientationPeripheral and peripheral.isPresent(config.orientationPeripheral) then
    return config.orientationPeripheral
  end
  if telemetry then
    local available = methods(telemetry)
    if has(available, "getLogicalPose") or has(available, "getPose") or has(available, "getOrientation") or has(available, "getRotation") or has(available, "getFacing") or has(available, "getDirection") or has(available, "getYaw") or has(available, "getHeading") or has(available, "getBearing") then
      return telemetry
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    local available = methods(name)
    if has(available, "getLogicalPose") or has(available, "getPose") or has(available, "getOrientation") or has(available, "getRotation") or has(available, "getFacing") or has(available, "getDirection") or has(available, "getYaw") or has(available, "getHeading") or has(available, "getBearing") then
      return name
    end
  end
end

local function callFirst(name, candidates)
  for _, method in ipairs(candidates) do
    local ok, value = pcall(peripheral.call, name, method)
    if ok and value ~= nil then return value end
  end
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

local function outputMaximum(config, output)
  local safety = type(config.safety) == "table" and config.safety or {}
  return math.max(0, math.min(15, tonumber(output.maximum) or 15, tonumber(safety.maximumOutput) or 5))
end

local function outputValue(config, output, strength)
  if type(output) ~= "table" or not output.side then return false end
  local maximum = outputMaximum(config, output)
  local value = math.max(0, math.min(maximum, math.floor(tonumber(strength) or 0)))
  if output.inverted and value > 0 then value = math.max(1, maximum - value + 1) end
  return true, value
end

local function writeOutputTarget(output, value)
  if output.analog == false then
    redstone.setOutput(output.side, value > 0)
  else
    redstone.setAnalogOutput(output.side, value)
  end
end

local function setOutputTarget(config, output, strength)
  local ok, value = outputValue(config, output, strength)
  if not ok then return false end
  writeOutputTarget(output, value)
  return true, value
end

local function outputTargets(output)
  if type(output) ~= "table" then return {} end
  if type(output.targets) == "table" then return output.targets end
  if output.side then return { output } end
  return {}
end

local function writeWinner(config, winners, target, strength)
  if type(target) ~= "table" or not target.side then return end
  local ok, value = outputValue(config, target, strength)
  if not ok then return end
  local current = winners[target.side]
  if not current or value > current.value then winners[target.side] = { target = target, value = value } end
end

local function applyAirshipVertical(config, values, winners, applied)
  local outputs = type(config.outputs) == "table" and config.outputs or {}
  local upTargets, downTargets = outputTargets(outputs.up), outputTargets(outputs.down)
  if #upTargets == 0 and #downTargets == 0 then return false end

  local up = tonumber(values and values.up) or 0
  local down = tonumber(values and values.down) or 0

  local verticalTargets = {}
  for _, target in ipairs(upTargets) do verticalTargets[#verticalTargets + 1] = target end
  for _, target in ipairs(downTargets) do verticalTargets[#verticalTargets + 1] = target end

  for _, target in ipairs(verticalTargets) do
    local maximum = outputMaximum(config, target)
    local neutral = math.floor(maximum / 2 + 0.5)
    local delta = math.max(-neutral, math.min(maximum - neutral, up - down))
    local output = neutral + delta
    if values and values.__airshipArrived then
      output = math.max(0, math.min(maximum, tonumber((config.hardware or {}).airshipArrivedPower) or 2))
    elseif values and values.__clear then
      output = 0
    end
    writeWinner(config, winners, target, output)
  end
  applied.up = up > down and up or 0
  applied.down = down > up and down or 0
  applied.airshipVertical = true
  return true
end

local function applyOutputValues(config, values)
  local winners = {}
  local applied = {}
  local airshipVertical = type(config.hardware) == "table" and config.hardware.airshipMode == true
  if airshipVertical then applyAirshipVertical(config, values, winners, applied) end
  for control, output in pairs(config.outputs or {}) do
    if not (airshipVertical and (control == "up" or control == "down")) then
    for _, target in ipairs(outputTargets(output)) do
      writeWinner(config, winners, target, values and values[control] or 0)
    end
    end
  end
  for _, winner in pairs(winners) do writeOutputTarget(winner.target, winner.value) end
  for control, output in pairs(config.outputs or {}) do
    local value = 0
    for _, target in ipairs(outputTargets(output)) do
      if type(target) == "table" and target.side and winners[target.side] then
        value = math.max(value, winners[target.side].value)
      end
    end
    applied[control] = value
  end
  return applied
end

local function setOutput(config, control, strength)
  if type(config.hardware) == "table" and config.hardware.airshipMode == true and (control == "up" or control == "down") then
    local values = { up = 0, down = 0 }
    values[control] = tonumber(strength) or 0
    local applied = applyOutputValues(config, values)
    return true, applied[control] or 0
  end
  local output = config.outputs and config.outputs[control]
  if type(output) ~= "table" then return false end
  local targets = type(output.targets) == "table" and output.targets or { output }
  local applied, wrote = 0, false
  for _, target in ipairs(targets) do
    if type(target) == "table" and target.side then
      local ok, value = setOutputTarget(config, target, strength)
      if ok then
        wrote = true
        applied = math.max(applied, tonumber(value) or 0)
      end
    end
  end
  return wrote, applied
end

local function setAirshipVerticalOutput(config, strength)
  if type(config.hardware) ~= "table" or config.hardware.airshipMode ~= true then return false, "airship mode is off" end
  local outputs = type(config.outputs) == "table" and config.outputs or {}
  local targets = {}
  for _, target in ipairs(outputTargets(outputs.up)) do targets[#targets + 1] = target end
  for _, target in ipairs(outputTargets(outputs.down)) do targets[#targets + 1] = target end
  if #targets == 0 then return false, "vertical output unassigned" end
  local applied, wrote = 0, false
  for _, target in ipairs(targets) do
    if type(target) == "table" and target.side then
      local ok, value = setOutputTarget(config, target, strength)
      if ok then wrote = true; applied = math.max(applied, tonumber(value) or 0) end
    end
  end
  return wrote, applied
end

local function airshipVerticalOutput(config)
  if type(config.hardware) ~= "table" or config.hardware.airshipMode ~= true then return false, "airship mode is off" end
  local outputs = type(config.outputs) == "table" and config.outputs or {}
  local targets = outputTargets(outputs.up)
  if #targets == 0 then targets = outputTargets(outputs.down) end
  local target = targets[1]
  if type(target) ~= "table" or not target.side then return false, "vertical output unassigned" end
  local ok, value = pcall(redstone.getAnalogOutput, target.side)
  if not ok then return false, value end
  return true, tonumber(value) or 0
end

local function applyOutputs(config, requested)
  local ok, applied = pcall(applyOutputValues, config, requested or {})
  return ok and applied or {}
end

local function makeOutputController(config)
  local active = {}
  local automation = type(config.automation) == "table" and config.automation or {}
  local holdAfter = tonumber(automation.outputHoldAfter) or 0.6
  local pulseReleaseGrace = tonumber(automation.outputPulseReleaseGrace) or 0.25
  local holdReleaseGrace = tonumber(automation.outputHoldReleaseGrace) or 1.0
  if type(config.flightControl) == "table" and config.flightControl.enabled ~= false then
    holdAfter, pulseReleaseGrace, holdReleaseGrace = 0, 0, 0
  end
  local pulseAutomation = automation.pulseAutomationOutputs ~= false
  local outputPulsePeriod = math.max(0.05, tonumber(automation.outputPulsePeriod) or 0.4)
  local outputPulseWidth = math.max(0.05, math.min(outputPulsePeriod, tonumber(automation.outputPulseWidth) or 0.3))
  return function(requested, forceClear)
    requested = requested or {}
    local applied = {}
    local now = os.clock()
    if forceClear then active = {} end
    for control in pairs(config.outputs or {}) do
      local requestedValue = forceClear and 0 or (tonumber(requested[control]) or 0)
      local state = active[control]
      local value = requestedValue
      if requestedValue > 0 then
        if not state then
          state = { since = now, last = now, value = requestedValue, holding = false }
          active[control] = state
        end
        state.last = now
        state.value = requestedValue
        if now - state.since >= holdAfter then state.holding = true end
        if pulseAutomation then
          local phase = (now - state.since) % outputPulsePeriod
          if phase >= outputPulseWidth then value = 0 end
        end
      elseif state then
        local grace = state.holding and holdReleaseGrace or pulseReleaseGrace
        if now - state.last <= grace then
          value = state.value
        else
          active[control] = nil
        end
      end
      applied[control] = value or 0
    end
    if forceClear then applied.__clear = true end
    return applyOutputs(config, applied)
  end
end

local function loadTarget()
  if not fs.exists(TARGET_PATH) then return nil end
  local file = fs.open(TARGET_PATH, "r")
  local data = textutils.unserialize(file.readAll())
  file.close()
  return data
end

local function loadData(path, fallback)
  if not fs.exists(path) then return fallback end
  local file = fs.open(path, "r")
  local data = textutils.unserialize(file.readAll())
  file.close()
  if data == nil then return fallback end
  return data
end

local function saveData(path, data)
  local file = fs.open(path, "w")
  file.write(textutils.serialize(data))
  file.close()
end

local function loadWaypoints()
  return loadData(WAYPOINTS_PATH, {})
end

local function saveWaypoints(waypoints)
  saveData(WAYPOINTS_PATH, waypoints)
end

local function loadMode()
  return loadData(MODE_PATH, { mode = "standby" })
end

local function saveMode(mode)
  saveData(MODE_PATH, { mode = mode })
end

local function loadSchedules()
  return loadData(SCHEDULES_PATH, {})
end

local function saveSchedules(schedules)
  saveData(SCHEDULES_PATH, schedules)
end

local function loadActiveSchedule()
  return loadData(ACTIVE_SCHEDULE_PATH, nil)
end

local function saveActiveSchedule(active)
  if not active then
    if fs.exists(ACTIVE_SCHEDULE_PATH) then fs.delete(ACTIVE_SCHEDULE_PATH) end
    return
  end
  saveData(ACTIVE_SCHEDULE_PATH, active)
end

local function withoutFinalHeading(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do if key ~= "heading" then copy[key] = item end end
  return copy
end

local function saveTarget(target)
  local file = fs.open(TARGET_PATH, "w")
  file.write(textutils.serialize(withoutFinalHeading(target)))
  file.close()
end

local function extractVector(value)
  if type(value) ~= "table" then return nil end
  local source = value.position or value.pos or value.translation or value.location or value.origin or value.center or value.vector or value
  if type(source) ~= "table" then return nil end
  local x = tonumber(source.x or source.X or source[1] or source.xCoord or source.x_coord)
  local y = tonumber(source.y or source.Y or source[2] or source.yCoord or source.y_coord)
  local z = tonumber(source.z or source.Z or source[3] or source.zCoord or source.z_coord)
  if x and y and z then return { x = x, y = y, z = z } end
  for _, nested in ipairs({ "position", "pos", "translation", "location", "origin", "center", "vector" }) do
    if value[nested] and value[nested] ~= source then
      local vector = extractVector(value[nested])
      if vector then return vector end
    end
  end
end

local function normalizeHorizontal(vector)
  if type(vector) ~= "table" then return nil end
  local x, z = tonumber(vector.x), tonumber(vector.z)
  if not x or not z then return nil end
  local length = math.sqrt(x * x + z * z)
  if length < 0.0001 then return nil end
  return { x = x / length, y = 0, z = z / length }
end

local function extractQuaternion(value)
  if type(value) ~= "table" then return nil end
  local source = value.rotation or value.orientation or value.quaternion or value.rot or value
  if type(source) ~= "table" then return nil end
  local w = tonumber(source.w or source.W or source[4] or source.qw)
  local x = tonumber(source.x or source.X or source[1] or source.qx)
  local y = tonumber(source.y or source.Y or source[2] or source.qy)
  local z = tonumber(source.z or source.Z or source[3] or source.qz)
  if not w or not x or not y or not z then return nil end
  local length = math.sqrt(w * w + x * x + y * y + z * z)
  if length < 0.0001 then return nil end
  return { w = w / length, x = x / length, y = y / length, z = z / length }
end

local function rotateByQuaternion(vector, q)
  local x, y, z = tonumber(vector.x) or 0, tonumber(vector.y) or 0, tonumber(vector.z) or 0
  local qx, qy, qz, qw = q.x, q.y, q.z, q.w
  local ix = qw * x + qy * z - qz * y
  local iy = qw * y + qz * x - qx * z
  local iz = qw * z + qx * y - qy * x
  local iw = -qx * x - qy * y - qz * z
  return {
    x = ix * qw + iw * -qx + iy * -qz - iz * -qy,
    y = iy * qw + iw * -qy + iz * -qx - ix * -qz,
    z = iz * qw + iw * -qz + ix * -qy - iy * -qx,
  }
end

local function rotateLocalYaw(vector, degrees)
  vector = extractVector(vector)
  degrees = tonumber(degrees) or 0
  if not vector or degrees == 0 then return vector end
  local radians = math.rad(degrees)
  local sinValue, cosValue = math.sin(radians), math.cos(radians)
  return {
    x = vector.x * cosValue + vector.z * sinValue,
    y = vector.y,
    z = vector.z * cosValue - vector.x * sinValue,
  }
end

local function headingFromPose(config, pose)
  if type(pose) ~= "table" then return nil end
  local direct = extractVector(pose.forward or pose.facing or pose.direction or (type(pose.rotation) == "table" and (pose.rotation.forward or pose.rotation.facing or pose.rotation.direction)))
  direct = normalizeHorizontal(direct)
  if direct then return direct, "pose-vector" end
  local q = extractQuaternion(pose)
  if q then
    local orientation = type(config.orientation) == "table" and config.orientation or {}
    local localForward = extractVector(orientation.forward) or { x = 0, y = 0, z = 1 }
    localForward = rotateLocalYaw(localForward, orientation.yawOffset)
    local rotated = normalizeHorizontal(rotateByQuaternion(localForward, q))
    if rotated then return rotated, "pose-quaternion" end
  end
end

local function headingFromCardinal(value)
  if type(value) ~= "string" then return nil end
  value = value:lower()
  if value == "north" or value == "n" then return { x = 0, y = 0, z = -1 }, "cardinal" end
  if value == "south" or value == "s" then return { x = 0, y = 0, z = 1 }, "cardinal" end
  if value == "east" or value == "e" then return { x = 1, y = 0, z = 0 }, "cardinal" end
  if value == "west" or value == "w" then return { x = -1, y = 0, z = 0 }, "cardinal" end
end

local function headingFromYaw(config, yaw, source)
  yaw = tonumber(yaw)
  if not yaw then return nil end
  local orientation = type(config.orientation) == "table" and config.orientation or {}
  yaw = yaw + (tonumber(orientation.yawOffset) or 0)
  local format = tostring(orientation.yawFormat or "avionics"):lower()
  local radians = math.rad(yaw)
  if format == "avionics" or format == "south" or format == "south-zero" then
    return normalizeHorizontal({ x = math.sin(radians), y = 0, z = math.cos(radians) }), source or "heading"
  end
  if format == "compass" or format == "bearing" then
    return normalizeHorizontal({ x = math.sin(radians), y = 0, z = -math.cos(radians) }), source or "bearing"
  end
  return normalizeHorizontal({ x = -math.sin(radians), y = 0, z = math.cos(radians) }), source or "yaw"
end

local function headingFromOrientationValue(config, value, source)
  local poseHeading, poseSource = headingFromPose(config, value)
  if poseHeading then return poseHeading, source and (source .. ":" .. poseSource) or poseSource end
  local vector = extractVector(value)
  vector = normalizeHorizontal(vector)
  if vector then return vector, source and (source .. "-vector") or "orientation-vector" end
  local cardinal, cardinalSource = headingFromCardinal(value)
  if cardinal then return cardinal, source and (source .. ":" .. cardinalSource) or cardinalSource end
  if type(value) == "number" then return headingFromYaw(config, value, source or "yaw") end
  if type(value) == "table" then
    for _, key in ipairs({ "yaw", "heading", "bearing", "angle", "rotation" }) do
      local heading, headingSource = headingFromYaw(config, value[key], source and (source .. ":" .. key) or key)
      if heading then return heading, headingSource end
    end
    for _, key in ipairs({ "facing", "direction", "cardinal" }) do
      local heading, headingSource = headingFromCardinal(value[key])
      if heading then return heading, source and (source .. ":" .. headingSource) or headingSource end
    end
  end
end

local function callPeripheral(name, method)
  if not name then return nil end
  local ok, value = pcall(peripheral.call, name, method)
  if ok then return value end
end

local function avionicsNames(config)
  return {
    navigationTable = findPeripheralByType("navigationTablePeripheral", config, "navigation_table"),
    gimbalSensor = findPeripheralByType("gimbalSensorPeripheral", config, "gimbal_sensor"),
    altitudeSensor = findPeripheralByType("altitudeSensorPeripheral", config, "altitude_sensor"),
    physicsAssembler = findPeripheralByType("physicsAssemblerPeripheral", config, "physics_assembler"),
    velocitySensors = findPeripheralsByType("velocity_sensor"),
  }
end

local function avionicsSnapshot(config, detail)
  local names = avionicsNames(config)
  local state = { names = names }
  if names.navigationTable then
    state.navigationTable = names.navigationTable
    state.navHeading = callPeripheral(names.navigationTable, "getHeading")
    if state.navHeading ~= nil then
      state.heading, state.headingSource = headingFromYaw(config, state.navHeading, "navigation_table.getHeading")
    elseif detail then
      state.navHeadingRad = callPeripheral(names.navigationTable, "getHeadingRad")
      state.navOrientation = callPeripheral(names.navigationTable, "getOrientation")
      if state.navHeadingRad ~= nil then
        state.heading, state.headingSource = headingFromYaw(config, math.deg(tonumber(state.navHeadingRad) or 0), "navigation_table.getHeadingRad")
      else
        state.heading, state.headingSource = headingFromOrientationValue(config, state.navOrientation, "navigation_table.getOrientation")
      end
    end
  end
  if names.gimbalSensor and detail then
    state.gimbalSensor = names.gimbalSensor
    state.gimbalAngles = callPeripheral(names.gimbalSensor, "getAngles")
    state.gimbalAngularRates = callPeripheral(names.gimbalSensor, "getAngularRates")
    state.gravity = callPeripheral(names.gimbalSensor, "getGravity")
    state.linearAcceleration = callPeripheral(names.gimbalSensor, "getLinearAcceleration")
  end
  if names.altitudeSensor then
    state.altitudeSensor = names.altitudeSensor
    state.altitude = callPeripheral(names.altitudeSensor, "getHeight")
    state.verticalSpeed = callPeripheral(names.altitudeSensor, "getVerticalSpeed")
  end
  if names.physicsAssembler and detail then
    state.physicsAssembler = names.physicsAssembler
    state.assemblerMass = callPeripheral(names.physicsAssembler, "getMass")
    state.centerOfMass = callPeripheral(names.physicsAssembler, "getCenterOfMass")
    state.subLevelId = callPeripheral(names.physicsAssembler, "getSubLevelId")
    state.subLevelName = callPeripheral(names.physicsAssembler, "getSubLevelName")
  end
  if detail then
    local bodyVelocity = {}
    for _, name in ipairs(names.velocitySensors or {}) do
      local axis = callPeripheral(name, "getAxis")
      local value = callPeripheral(name, "getVelocity")
      if axis and value ~= nil then bodyVelocity[tostring(axis):lower()] = value end
    end
    if bodyVelocity.x or bodyVelocity.y or bodyVelocity.z then state.bodyVelocity = bodyVelocity end
  end
  return state
end

local function orientationHeading(config, name)
  if not name then return nil end
  for _, method in ipairs({ "getLogicalPose", "getPose", "getOrientation", "getRotation", "getFacing", "getDirection", "getYaw", "getHeading", "getBearing" }) do
    local ok, value = pcall(peripheral.call, name, method)
    if ok and value ~= nil then
      local heading, source = headingFromOrientationValue(config, value, method)
      if heading then return heading, source, value end
    end
  end
end

local function headingFromVelocity(velocity, minimumSpeed)
  local vector = extractVector(velocity)
  if not vector then return nil end
  local horizontal = math.sqrt((tonumber(vector.x) or 0) ^ 2 + (tonumber(vector.z) or 0) ^ 2)
  if horizontal < (tonumber(minimumSpeed) or 0.25) then return nil end
  return normalizeHorizontal(vector), "velocity"
end

local function callVector(name, candidates)
  for _, method in ipairs(candidates) do
    local ok, a, b, c = pcall(peripheral.call, name, method)
    if ok and a ~= nil then
      if b ~= nil and c ~= nil and tonumber(a) and tonumber(b) and tonumber(c) then
        return { x = tonumber(a), y = tonumber(b), z = tonumber(c) }, { a, b, c }
      end
      local vector = extractVector(a)
      if vector then return vector, a end
      return nil, a
    end
  end
end

local function coordinateVector(name)
  local values = {}
  local keys = {
    x = { "getX", "getWorldX", "getShipX" },
    y = { "getY", "getWorldY", "getShipY" },
    z = { "getZ", "getWorldZ", "getShipZ" },
  }
  for axis, candidates in pairs(keys) do
    values[axis] = callFirst(name, candidates)
  end
  if tonumber(values.x) and tonumber(values.y) and tonumber(values.z) then
    return { x = tonumber(values.x), y = tonumber(values.y), z = tonumber(values.z) }, values
  end
  return nil, values
end

local function shortText(value)
  local text = textutils.serialize(value)
  if #text > 120 then return text:sub(1, 117) .. "..." end
  return text
end

local function waypointList()
  local waypoints = loadWaypoints()
  local names = {}
  for name in pairs(waypoints) do names[#names + 1] = name end
  table.sort(names)
  return waypoints, names
end

local function scheduleList()
  local schedules = loadSchedules()
  local names = {}
  for name in pairs(schedules) do names[#names + 1] = name end
  table.sort(names)
  return schedules, names
end

local function distance(a, b)
  if not a or not b then return nil end
  local dx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
  local dy = (tonumber(a.y) or 0) - (tonumber(b.y) or 0)
  local dz = (tonumber(a.z) or 0) - (tonumber(b.z) or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function scheduleStopArrival(config, state, stop)
  stop = withoutFinalHeading(stop)
  local position = state and state.position
  if type(position) ~= "table" or type(stop) ~= "table" then return false, nil end
  local navigation = type(config.navigation) == "table" and config.navigation or {}
  local radius = math.max(0.001, tonumber(navigation.arrivalRadius) or 1)
  if type(config.hardware) == "table" and config.hardware.airshipMode == true then
    radius = math.max(radius, tonumber(navigation.airshipArrivalRadius) or 6)
  end
  local dx = (tonumber(stop.x) or 0) - (tonumber(position.x) or 0)
  local dy = (tonumber(stop.y) or 0) - (tonumber(position.y) or 0)
  local dz = (tonumber(stop.z) or 0) - (tonumber(position.z) or 0)
  local directDistance = math.sqrt(dx * dx + dy * dy + dz * dz)
  local arrived = directDistance <= radius
  local details = {
    xError = dx,
    yError = dy,
    zError = dz,
    distance = directDistance,
    arrivalRadius = radius,
    axesReached = arrived,
    settled = arrived,
    headingReached = true,
    arrived = arrived,
  }
  local ok, directorArrived, directorDetails = pcall(ScheduleDirector.arrivalStatus, state, stop, config)
  if ok and type(directorDetails) == "table" then
    for key, value in pairs(directorDetails) do if details[key] == nil then details[key] = value end end
    details.directorArrived = directorArrived == true
  end
  return arrived, details
end

local gpsFix
local snapshot
local lastAutomationDebug

local function automationSummary(notes)
  if type(notes) ~= "table" then return nil end
  for _, pattern in ipairs({ "forward held", "align brake", "final brake", "final capture", "cruise", "yaw", "heading" }) do
    for _, note in ipairs(notes) do
      if tostring(note):find(pattern, 1, true) then return tostring(note) end
    end
  end
  return notes[1] and tostring(notes[1]) or nil
end

local function promptTarget()
  term.clear()
  term.setCursorPos(1, 1)
  print("Set Aircraft Target")
  write("Name: ")
  local name = read()
  write("X: ")
  local x = tonumber(read())
  write("Y: ")
  local y = tonumber(read())
  write("Z: ")
  local z = tonumber(read())
  if not x or not y or not z then printError("Coordinates must be numbers."); sleep(1.5); return end
  local target = { name = name ~= "" and name or nil, x = x, y = y, z = z }
  saveTarget(target)
  print("Target saved.")
  sleep(1)
end

local function promptWaypoint(config)
  term.clear()
  term.setCursorPos(1, 1)
  print("Save Waypoint")
  write("Name: ")
  local name = read()
  if name == "" then printError("Name is required."); sleep(1.5); return end
  local current = snapshot(config)
  local position = current.position
  if position then
    print("Use current position " .. string.format("%.1f %.1f %.1f", position.x, position.y, position.z) .. "? [Y/n]")
    local answer = read():lower()
    if answer == "n" or answer == "no" then position = nil end
  end
  if not position then
    write("X: ")
    local x = tonumber(read())
    write("Y: ")
    local y = tonumber(read())
    write("Z: ")
    local z = tonumber(read())
    if not x or not y or not z then printError("Coordinates must be numbers."); sleep(1.5); return end
    position = { x = x, y = y, z = z }
  end
  local waypoints = loadWaypoints()
  waypoints[name] = { name = name, x = position.x, y = position.y, z = position.z }
  saveWaypoints(waypoints)
  print("Waypoint saved.")
  sleep(1)
end

local function promptSchedule()
  term.clear()
  term.setCursorPos(1, 1)
  print("Create Coordinate Schedule")
  write("Schedule name: ")
  local name = read()
  if name == "" then printError("Name is required."); sleep(1.5); return end
  write("Number of stops: ")
  local count = tonumber(read())
  if not count or count < 1 then printError("Stop count must be at least 1."); sleep(1.5); return end
  local stops = {}
  for index = 1, math.floor(count) do
    print("Stop " .. index)
    write("  Label: ")
    local label = read()
    write("  X: ")
    local x = tonumber(read())
    write("  Y: ")
    local y = tonumber(read())
    write("  Z: ")
    local z = tonumber(read())
    if not x or not y or not z then printError("Coordinates must be numbers."); sleep(1.5); return end
    local stop = { name = label ~= "" and label or ("Stop " .. index), x = x, y = y, z = z }
    stops[#stops + 1] = stop
  end
  write("Dwell seconds at each stop: ")
  local dwell = math.max(0, tonumber(read()) or 0)
  write("Loop schedule? y/N: ")
  local loop = tostring(read() or ""):lower():sub(1, 1) == "y"
  local schedules = loadSchedules()
  schedules[name] = { name = name, stops = stops, dwell = dwell, loop = loop }
  saveSchedules(schedules)
  print("Schedule saved.")
  sleep(1)
end

local startSchedule
local serverAutomationTick
local renderMonitorStatus

local function hasPeripheralType(name, wanted)
  local ok, value = pcall(peripheral.getType, name)
  if not ok then return false end
  if type(value) == "table" then
    for _, item in ipairs(value) do if item == wanted then return true end end
    return false
  end
  return value == wanted
end

local function monitorList(config)
  local monitors = {}
  for _, name in ipairs(peripheral.getNames()) do
    if hasPeripheralType(name, "monitor") then
      local width, height
      local ok, wrapped = pcall(peripheral.wrap, name)
      if ok and wrapped and wrapped.getSize then width, height = wrapped.getSize() end
      monitors[#monitors + 1] = {
        name = name,
        selected = type(config) == "table" and config.monitorPeripheral == name,
        width = width,
        height = height,
      }
    end
  end
  table.sort(monitors, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return monitors
end

local function setMonitorPeripheral(config, name)
  name = tostring(name or "")
  if name == "" or name == "none" or name == "clear" then
    config.monitorPeripheral = nil
    return true
  end
  if not peripheral.isPresent(name) or not hasPeripheralType(name, "monitor") then return false, "monitor unavailable" end
  config.monitorPeripheral = name
  return true
end

local function promptRunSchedule()
  term.clear()
  term.setCursorPos(1, 1)
  print("Run Schedule")
  local schedules, names = scheduleList()
  if #names == 0 then print("No schedules saved."); sleep(1.5); return end
  for _, name in ipairs(names) do print("- " .. name .. " (" .. tostring(#(schedules[name].stops or {})) .. " stops)") end
  write("Schedule name: ")
  local name = read()
  local ok, err = startSchedule(name)
  if ok then print("Schedule armed. Run navtool automate to advance it.") else printError(err) end
  sleep(1.5)
end

function startSchedule(name)
  local schedules = loadSchedules()
  local schedule = schedules[name]
  if not schedule or type(schedule.stops) ~= "table" or #schedule.stops == 0 then return false, "schedule not found or empty" end
  local active = { name = name, index = 1, startedAt = os.epoch and os.epoch("utc") or os.time() }
  saveActiveSchedule(active)
  saveTarget(schedule.stops[1])
  saveMode("navigate")
  return true, schedule.stops[1]
end

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return side
    end
  end
end

gpsFix = function(config)
  local gpsConfig = type(config.gps) == "table" and config.gps or {}
  if gpsConfig.enabled == false or type(gps) ~= "table" or type(gps.locate) ~= "function" then return nil, "gps disabled or unavailable" end
  if not openModem() then return nil, "no modem" end
  local timeout = tonumber(gpsConfig.timeout) or 0.5
  local ok, x, y, z = pcall(gps.locate, timeout, false)
  if not ok or not x or not y or not z then return nil, "no gps fix" end
  local now = os.clock()
  local position = { x = x, y = y, z = z }
  local velocity
  if lastGpsFix and lastGpsFix.time and now > lastGpsFix.time then
    local dt = now - lastGpsFix.time
    velocity = {
      x = (position.x - lastGpsFix.position.x) / dt,
      y = (position.y - lastGpsFix.position.y) / dt,
      z = (position.z - lastGpsFix.position.z) / dt,
    }
  end
  lastGpsFix = { position = position, time = now }
  return { position = position, velocity = velocity, rawPosition = position }
end

local function sublevelSnapshot(config)
  if not sublevelAvailable(config) then return nil end
  local pose = callSublevel("getLogicalPose") or callSublevel("getLastPose")
  return {
    available = true,
    pose = pose,
    rawPosition = pose,
    position = extractVector(pose),
    velocity = extractVector(callSublevel("getLinearVelocity") or callSublevel("getVelocity")),
    angularVelocity = callSublevel("getAngularVelocity"),
    centerOfMass = callSublevel("getCenterOfMass"),
    mass = callSublevel("getMass"),
    subLevelId = callSublevel("getUniqueId"),
    subLevelName = callSublevel("getName"),
  }
end

local function legacyPeripheralSnapshot(name)
  if not name then return nil end
  local pose = callFirst(name, { "getLogicalPose", "getPose" })
  local position = extractVector(pose)
  local rawPosition
  if not position then position, rawPosition = callVector(name, { "getPosition", "getShipPosition", "getWorldPosition", "getBlockPosition" }) end
  if not position then position, rawPosition = coordinateVector(name) end
  local velocity, rawVelocity = callVector(name, { "getLinearVelocity", "getVelocity", "getShipVelocity" })
  return {
    peripheral = name,
    pose = pose,
    rawPosition = rawPosition,
    position = position,
    rawVelocity = rawVelocity,
    velocity = velocity,
    angularVelocity = callFirst(name, { "getAngularVelocity" }),
    mass = callFirst(name, { "getMass" }),
  }
end

snapshot = function(config, options)
  options = options or {}
  local name = telemetryName(config)
  local subState = sublevelSnapshot(config)
  local legacyState = legacyPeripheralSnapshot(name)
  local avionicsState = avionicsSnapshot(config, options.detail == true)
  local orientationPeripheral = orientationName(config, name) or (avionicsState and avionicsState.navigationTable)
  local target = loadTarget()
  local waypoints, names, schedules, scheduleNames
  local includeLibrary = options.library ~= false
  local includeSchedule = options.schedule ~= false
  if includeLibrary then waypoints, names = waypointList() else waypoints, names = {}, {} end
  if includeLibrary then schedules, scheduleNames = scheduleList() else schedules, scheduleNames = {}, {} end
  local activeSchedule = includeSchedule and loadActiveSchedule() or nil
  if includeSchedule and activeSchedule and not includeLibrary then
    local allSchedules = loadSchedules()
    schedules = allSchedules[activeSchedule.name] and { [activeSchedule.name] = allSchedules[activeSchedule.name] } or {}
  end
  local mode = loadMode().mode or "standby"
  local heading, headingSource, rawOrientation = orientationHeading(config, orientationPeripheral)
  if avionicsState and avionicsState.heading then
    heading, headingSource, rawOrientation = avionicsState.heading, avionicsState.headingSource, avionicsState.navOrientation or avionicsState.navHeading
  end
  local position = (subState and subState.position) or (legacyState and legacyState.position)
  local velocity = (subState and subState.velocity) or (legacyState and legacyState.velocity)
  local gpsData, gpsErr
  if options.gps ~= false and (not position or not velocity) then gpsData, gpsErr = gpsFix(config) end
  position = position or (gpsData and gpsData.position)
  velocity = velocity or (gpsData and gpsData.velocity)
  if position and avionicsState and tonumber(avionicsState.altitude) then
    position = { x = position.x, y = tonumber(avionicsState.altitude), z = position.z }
  end
  if velocity and avionicsState and tonumber(avionicsState.verticalSpeed) then
    velocity = { x = velocity.x, y = tonumber(avionicsState.verticalSpeed), z = velocity.z }
  end
  local pose = (subState and subState.pose) or (legacyState and legacyState.pose)
  if not heading then heading, headingSource = headingFromPose(config, pose) end
  local source = subState and "sublevel" or (legacyState and legacyState.peripheral) or (gpsData and "gps") or "none"
  local scheduleArrival
  if activeSchedule and schedules and position then
    local schedule = schedules[activeSchedule.name]
    local stops = schedule and schedule.stops
    local index = math.max(1, math.min(stops and #stops or 1, tonumber(activeSchedule.index) or 1))
    local stop = stops and stops[index]
    if stop then
      local arrived, details = scheduleStopArrival(config, {
        position = position,
        velocity = velocity,
        heading = heading,
      }, stop)
      scheduleArrival = details or {}
      scheduleArrival.arrived = arrived == true
    end
  end
  return {
    version = VERSION,
    capabilities = { hardware = Hardware ~= nil, hardwareSource = HardwareSource, schedules = true, waypoints = true },
    telemetry = position ~= nil or heading ~= nil,
    source = source,
    peripheral = legacyState and legacyState.peripheral,
    sublevel = subState and subState.available or false,
    orientationPeripheral = orientationPeripheral,
    navigationTable = avionicsState and avionicsState.navigationTable,
    gimbalSensor = avionicsState and avionicsState.gimbalSensor,
    altitudeSensor = avionicsState and avionicsState.altitudeSensor,
    physicsAssembler = avionicsState and avionicsState.physicsAssembler,
    pose = pose,
    rawOrientation = rawOrientation,
    heading = heading,
    headingSource = headingSource,
    rawPosition = (subState and subState.rawPosition) or (legacyState and legacyState.rawPosition) or (gpsData and gpsData.rawPosition),
    position = position,
    rawVelocity = legacyState and legacyState.rawVelocity,
    velocity = velocity,
    bodyVelocity = avionicsState and avionicsState.bodyVelocity,
    angularVelocity = (subState and subState.angularVelocity) or (legacyState and legacyState.angularVelocity) or (avionicsState and avionicsState.gimbalAngularRates),
    gimbalAngles = avionicsState and avionicsState.gimbalAngles,
    gravity = avionicsState and avionicsState.gravity,
    linearAcceleration = avionicsState and avionicsState.linearAcceleration,
    altitude = avionicsState and avionicsState.altitude,
    verticalSpeed = avionicsState and avionicsState.verticalSpeed,
    centerOfMass = (subState and subState.centerOfMass) or (avionicsState and avionicsState.centerOfMass),
    mass = (subState and subState.mass) or (legacyState and legacyState.mass) or (avionicsState and avionicsState.assemblerMass),
    subLevelId = (subState and subState.subLevelId) or (avionicsState and avionicsState.subLevelId),
    subLevelName = (subState and subState.subLevelName) or (avionicsState and avionicsState.subLevelName),
    gpsError = gpsErr,
    target = target,
    distanceToTarget = distance(position, target),
    waypoints = waypoints,
    waypointNames = names,
    schedules = schedules,
    scheduleNames = scheduleNames,
    activeSchedule = activeSchedule,
    scheduleArrival = scheduleArrival,
    automation = lastAutomationDebug,
    mode = mode,
  }
end

local setScheduleStop

local function handleHardwareCommand(config, request)
  if not Hardware then return false end
  if request.command == "hardware-list" then
    local description = Hardware.describe(config)
    description.modes = description.modes or {}
    description.modes.airship = type(config.hardware) == "table" and config.hardware.airshipMode == true
    return true, { ok = true, hardware = description }
  elseif request.command == "hardware-assign" then
    local okAssign, result = Hardware.assign(config, request)
    if okAssign then saveConfig(config); return true, { ok = true, assignment = result, hardware = Hardware.describe(config) } end
    return true, { ok = false, error = result }
  elseif request.command == "hardware-unassign" then
    local okUnassign, result = Hardware.unassign(config, request)
    if okUnassign then saveConfig(config); return true, { ok = true, assignment = result, hardware = Hardware.describe(config) } end
    return true, { ok = false, error = result }
  elseif request.command == "hardware-test" then
    local okTest, result = Hardware.test(config, request.control, request.strength)
    return true, okTest and { ok = true } or { ok = false, error = result }
  elseif request.command == "hardware-mode" or request.command == "hardware-airship" then
    local okMode, result = Hardware.setMode(config, request)
    if okMode then saveConfig(config); return true, { ok = true, hardware = result } end
    return true, { ok = false, error = result }
  end
  return false
end

local function handleWaypointCommand(config, request)
  if request.command == "waypoint-list" then
    local waypoints, names = waypointList()
    return true, { ok = true, waypoints = waypoints, names = names }
  elseif request.command == "save-waypoint" and type(request.waypoint) == "table" then
    local waypoint = request.waypoint
    local name = tostring(waypoint.name or "")
    local x, y, z = tonumber(waypoint.x), tonumber(waypoint.y), tonumber(waypoint.z)
    if name ~= "" and x and y and z then
      local waypoints = loadWaypoints()
      waypoints[name] = { name = name, x = x, y = y, z = z }
      saveWaypoints(waypoints)
      return true, { ok = true, waypoint = waypoints[name] }
    end
    return true, { ok = false, error = "invalid waypoint" }
  elseif request.command == "delete-waypoint" then
    local waypoints = loadWaypoints()
    waypoints[tostring(request.name or "")] = nil
    saveWaypoints(waypoints)
    return true, { ok = true }
  elseif request.command == "goto-waypoint" then
    local waypoints = loadWaypoints()
    local waypoint = waypoints[tostring(request.name or "")]
    if waypoint then
      saveTarget(waypoint)
      saveMode("navigate")
      return true, { ok = true, target = waypoint }
    end
    return true, { ok = false, error = "waypoint not found" }
  end
  return false
end

local function handleScheduleCommand(config, request)
  if request.command == "schedule-list" then
    local schedules, names = scheduleList()
    return true, { ok = true, schedules = schedules, names = names, active = loadActiveSchedule() }
  elseif request.command == "save-schedule" and type(request.schedule) == "table" then
    local schedule = request.schedule
    local name = tostring(schedule.name or "")
    local stops = type(schedule.stops) == "table" and schedule.stops or {}
    if name == "" or #stops == 0 then return true, { ok = false, error = "invalid schedule" } end
    local normalized = {}
    for index, stop in ipairs(stops) do
      local x, y, z = tonumber(stop.x), tonumber(stop.y), tonumber(stop.z)
      if not x or not y or not z then return true, { ok = false, error = "invalid schedule stop" } end
      normalized[#normalized + 1] = { name = stop.name or ("Stop " .. index), x = x, y = y, z = z }
    end
    local schedules = loadSchedules()
    schedules[name] = { name = name, stops = normalized, dwell = math.max(0, tonumber(schedule.dwell) or 0), loop = schedule.loop == true }
    saveSchedules(schedules)
    return true, { ok = true, schedule = schedules[name] }
  elseif request.command == "delete-schedule" then
    local schedules = loadSchedules()
    local name = tostring(request.name or "")
    schedules[name] = nil
    saveSchedules(schedules)
    local active = loadActiveSchedule()
    if active and active.name == name then saveActiveSchedule(nil); saveMode("standby") end
    return true, { ok = true }
  elseif request.command == "run-schedule" then
    local ok, result = startSchedule(tostring(request.name or ""))
    return true, ok and { ok = true, target = result } or { ok = false, error = result }
  elseif request.command == "stop-schedule" then
    saveActiveSchedule(nil)
    saveMode("standby")
    clearOutputs(config)
    return true, { ok = true }
  elseif request.command == "hardware-mode" or request.command == "hardware-airship" then
    config.hardware = type(config.hardware) == "table" and config.hardware or {}
    if tostring(request.mode or "") == "airship" then
      config.hardware.airshipMode = request.enabled == true
      saveConfig(config)
      return true, { ok = true, hardware = { modes = { airship = config.hardware.airshipMode == true } } }
    end
    return true, { ok = false, error = "invalid hardware mode" }
  elseif request.command == "skip-stop" then
    local active = loadActiveSchedule()
    if not active then return true, { ok = false, error = "no active schedule" } end
    local schedules = loadSchedules()
    local schedule = schedules[active.name]
    if not schedule or type(schedule.stops) ~= "table" or #schedule.stops == 0 then return true, { ok = false, error = "no active schedule" } end
    local currentIndex = math.max(1, math.min(#schedule.stops, tonumber(active.index) or 1))
    active.dwellIndex, active.dwellUntil, active.paused = nil, nil, nil
    if currentIndex >= #schedule.stops then
      if schedule.loop then active.index = 1 else saveActiveSchedule(nil); saveMode("standby"); clearOutputs(config); return true, { ok = true, status = "complete" } end
    else
      active.index = currentIndex + 1
    end
    setScheduleStop(active, schedule, active.index)
    return true, { ok = true, stop = active.index, target = schedule.stops[active.index] }
  elseif request.command == "pause-schedule" then
    local active = loadActiveSchedule()
    if active then active.paused = true; saveActiveSchedule(active) end
    saveMode("standby")
    return true, active and { ok = true, clearOutputs = true } or { ok = false, error = "no active schedule" }
  elseif request.command == "resume-schedule" then
    local active = loadActiveSchedule()
    if active then active.paused = nil; saveActiveSchedule(active); saveMode("navigate"); return true, { ok = true } end
    return true, { ok = false, error = "no active schedule" }
  end
  return false
end

local function server(config, debug)
  if not config.network or not config.network.enabled then
    printError("Networking is disabled in /navtool/config.lua")
    return
  end
  local modem = openModem()
  if not modem then printError("No wired or wireless modem found."); return end
  local channel = config.network.channel or config.network.protocol or "cc-navtool"
  local host = config.network.host or "navtool-aircraft"
  rednet.host(channel, host)
  print("navtool remote server online")
  print("Host: " .. host)
  print("Channel: " .. channel)
  local manualUntil = {}
  local lastAutomation = 0
  local pendingClearOutputs = false
  local automationOutputController = makeOutputController(config)
  local function clearExpiredManual()
    local now = os.clock()
    for control, expiresAt in pairs(manualUntil) do
      if expiresAt <= now then
        pcall(setOutput, config, control, 0)
        manualUntil[control] = nil
      end
    end
  end
  local function requestLoop()
  while true do
    clearExpiredManual()
    local sender, request = rednet.receive(channel, 0.05)
    clearExpiredManual()
    if type(request) == "table" then
      if debug then print("Request from " .. tostring(sender) .. ": " .. tostring(request.command)) end
      local ok, err = pcall(function()
        local valid = (config.network.sharedKey or "") == "" or request.key == config.network.sharedKey
        local response = { ok = false, error = "unauthorized" }
        local responseSent = false
        local function sendResponse(value)
          value = type(value) == "table" and value or { ok = false, error = "invalid response" }
          value.requestId = request.requestId
          value.command = request.command
          rednet.send(sender, value, channel)
        end
        if valid then
        local handled, handledResponse = handleHardwareCommand(config, request)
        if not handled then handled, handledResponse = handleWaypointCommand(config, request) end
        if not handled then handled, handledResponse = handleScheduleCommand(config, request) end
        if handled then
          response = handledResponse
          if response and response.clearOutputs then pendingClearOutputs = true; response.clearOutputs = nil end
        elseif request.command == "ping" then
          response = { ok = true, pong = true, id = os.getComputerID and os.getComputerID() or nil }
        elseif request.command == "live-status" then
          response = { ok = true, data = snapshot(config, { library = false, gps = false }) }
        elseif request.command == "status" then
          response = { ok = true, data = snapshot(config) }
        elseif request.command == "hardware-list" then
          local description = Hardware and Hardware.describe(config) or nil
          if description then
            description.modes = description.modes or {}
            description.modes.airship = type(config.hardware) == "table" and config.hardware.airshipMode == true
            response = { ok = true, hardware = description }
          else
            response = { ok = false, error = "hardware unavailable" }
          end
        elseif request.command == "hardware-assign" then
          local okAssign, result = Hardware and Hardware.assign(config, request)
          if okAssign then saveConfig(config); response = { ok = true, assignment = result, hardware = Hardware.describe(config) }
          else response = { ok = false, error = result or "hardware unavailable" } end
        elseif request.command == "hardware-unassign" then
          local okUnassign, result = Hardware and Hardware.unassign(config, request)
          if okUnassign then saveConfig(config); response = { ok = true, assignment = result, hardware = Hardware.describe(config) }
          else response = { ok = false, error = result or "hardware unavailable" } end
        elseif request.command == "hardware-test" then
          local okTest, result = Hardware and Hardware.test(config, request.control, request.strength)
          response = okTest and { ok = true } or { ok = false, error = result or "hardware unavailable" }
        elseif request.command == "hardware-mode" or request.command == "hardware-airship" then
          local okMode, result = Hardware and Hardware.setMode(config, request)
          if okMode then saveConfig(config); response = { ok = true, hardware = result }
          else response = { ok = false, error = result or "hardware unavailable" } end
        elseif request.command == "orientation-status" then
          config.orientation = type(config.orientation) == "table" and config.orientation or {}
          local state = snapshot(config, { library = false, schedule = false, gps = false })
          response = { ok = true, yawOffset = tonumber(config.orientation.yawOffset) or 0, heading = state.heading, headingSource = state.headingSource }
        elseif request.command == "orientation-set" then
          config.orientation = type(config.orientation) == "table" and config.orientation or {}
          local offset = tonumber(request.yawOffset)
          if offset then
            config.orientation.yawOffset = ((offset + 180) % 360) - 180
            saveConfig(config)
            response = { ok = true, yawOffset = config.orientation.yawOffset }
          else
            response = { ok = false, error = "invalid yaw offset" }
          end
        elseif request.command == "set-target" and type(request.target) == "table" then
          saveTarget(request.target)
          response = { ok = true, target = request.target }
        elseif request.command == "clear-target" then
          if fs.exists(TARGET_PATH) then fs.delete(TARGET_PATH) end
          response = { ok = true }
        elseif request.command == "set-mode" then
          local mode = tostring(request.mode or "standby")
          if mode == "standby" or mode == "navigate" or mode == "hover" or mode == "return-home" then
            sendResponse({ ok = true, mode = mode })
            responseSent = true
            if mode ~= "navigate" then saveActiveSchedule(nil) end
            saveMode(mode)
            if mode == "standby" then pendingClearOutputs = true end
            response = { ok = true, mode = mode }
          else
            response = { ok = false, error = "unsupported mode" }
          end
        elseif request.command == "manual-control" then
          local control = tostring(request.control or "")
          local output = config.outputs and config.outputs[control]
          local hasTargets = type(output) == "table" and type(output.targets) == "table" and #output.targets > 0
          if type(output) ~= "table" or (not output.side and not hasTargets) then
            response = { ok = false, error = "unsupported control" }
          else
            local safety = type(config.safety) == "table" and config.safety or {}
            local duration = math.max(0, math.min(tonumber(safety.maximumRemotePulse) or 2.0, tonumber(request.duration) or 0.25))
            local strength = tonumber(request.strength) or outputMaximum(config, output)
            if next(manualUntil) == nil and (tonumber(strength) or 0) > 0 then
              automationOutputController(nil, true)
              saveActiveSchedule(nil)
              saveMode("standby")
            end
            local ok, value = pcall(setOutput, config, control, strength)
            if ok then
              if duration > 0 and (tonumber(strength) or 0) > 0 then
                manualUntil[control] = os.clock() + duration
              else
                manualUntil[control] = nil
              end
              response = { ok = true, control = control, value = value or 0, duration = duration }
            else
              response = { ok = false, error = "output failed" }
            end
          end
        elseif request.command == "airship-vertical-control" then
          local safety = type(config.safety) == "table" and config.safety or {}
          local strength = math.max(0, math.min(tonumber(safety.maximumOutput) or 15, tonumber(request.strength) or 0))
          local okAirship, value = setAirshipVerticalOutput(config, strength)
          response = okAirship and { ok = true, control = "airship-vertical", value = value or 0 } or { ok = false, error = value }
        elseif request.command == "airship-vertical-status" then
          local okAirship, value = airshipVerticalOutput(config)
          response = okAirship and { ok = true, control = "airship-vertical", value = value or 0 } or { ok = false, error = value }
        elseif request.command == "monitor-list" then
          response = { ok = true, monitors = monitorList(config), selected = config.monitorPeripheral }
        elseif request.command == "monitor-set" then
          local okMonitor, result = setMonitorPeripheral(config, request.monitor)
          if okMonitor then
            saveConfig(config)
            response = { ok = true, monitors = monitorList(config), selected = config.monitorPeripheral }
          else
            response = { ok = false, error = result }
          end
        elseif request.command == "stop" or request.command == "outputs-off" then
          manualUntil = {}
          automationOutputController(nil, true)
          clearOutputs(config)
          saveActiveSchedule(nil)
          saveMode("standby")
          response = { ok = true }
        else
          response = { ok = false, error = "unsupported command" }
        end
        end
        if not responseSent then sendResponse(response) end
        if pendingClearOutputs then
          pendingClearOutputs = false
          automationOutputController(nil, true)
          clearOutputs(config)
        end
        if debug then print("Reply to " .. tostring(sender) .. ": " .. tostring(response.ok)) end
      end)
      if not ok then
        printError("Request failed: " .. tostring(err))
        pcall(rednet.send, sender, { ok = false, error = "server error: " .. tostring(err), requestId = request.requestId, command = request.command }, channel)
      end
    end
  end
  end

  local function automationLoop()
  while true do
    if next(manualUntil) == nil and serverAutomationTick then
      local now = os.clock()
      local interval = math.max(0.25, tonumber(config.networkUpdateInterval) or tonumber(config.updateInterval) or 0.25)
      if now - lastAutomation >= interval then
        lastAutomation = now
        local mode = loadMode().mode or "standby"
        local activeSchedule = loadActiveSchedule()
        local target = loadTarget()
        if activeSchedule or (mode ~= "standby" and (mode == "hover" or target)) then
          local ok, state, requested, applied, notes = pcall(serverAutomationTick, config, automationOutputController)
          if ok then
            if renderMonitorStatus then pcall(renderMonitorStatus, config, state, requested, applied, notes) end
          else
            printError("Automation tick failed: " .. tostring(state))
          end
        else
          local state = snapshot(config, { library = false, schedule = false, gps = false })
          if renderMonitorStatus then pcall(renderMonitorStatus, config, state, {}, {}, { "standby" }) end
        end
      end
    end
    sleep(0.05)
  end
  end

  parallel.waitForAny(requestLoop, automationLoop)
end

local function status(config)
  local state = snapshot(config, { detail = true })
  print("CC-NavTool " .. VERSION)
  print("Telemetry: " .. (state.telemetry and "online" or "not found"))
  print("Source: " .. tostring(state.source or state.peripheral or "unknown"))
  print("Sublevel API: " .. tostring(state.sublevel))
  if state.peripheral then print("Peripheral: " .. state.peripheral) end
  if state.peripheral then print("Methods: " .. table.concat(methods(state.peripheral), ", ")) end
  if state.orientationPeripheral then print("Orientation peripheral: " .. state.orientationPeripheral) end
  if state.navigationTable then print("Navigation table: " .. state.navigationTable) end
  if state.gimbalSensor then print("Gimbal sensor: " .. state.gimbalSensor) end
  if state.altitudeSensor then print("Altitude sensor: " .. state.altitudeSensor) end
  if state.physicsAssembler then print("Physics assembler: " .. state.physicsAssembler) end
  print("Position: " .. shortText(state.position))
  print("Velocity: " .. shortText(state.velocity))
  print("Body velocity: " .. shortText(state.bodyVelocity))
  print("Heading: " .. shortText(state.heading) .. " via " .. tostring(state.headingSource or "unknown"))
  print("Attitude: " .. shortText(state.gimbalAngles))
  print("Altitude: " .. shortText(state.altitude) .. " vertical " .. shortText(state.verticalSpeed))
  if state.telemetry and not state.position then print("Raw position: " .. shortText(state.rawPosition or state.pose)) end
  if state.telemetry and not state.velocity then print("Raw velocity: " .. shortText(state.rawVelocity)) end
  if state.gpsError then print("GPS: " .. tostring(state.gpsError)) end
  print("Target: " .. textutils.serialize(state.target))
  print("Mode: " .. tostring(state.mode or "standby"))
  print("Waypoints: " .. tostring(#(state.waypointNames or {})))
  print("Schedules: " .. tostring(#(state.scheduleNames or {})))
  print("Active schedule: " .. textutils.serialize(state.activeSchedule))
  print("Networking: " .. ((config.network and config.network.enabled) and "enabled" or "disabled"))
end

local function setOrientationOffset(config, value)
  local offset = tonumber(value)
  if not offset then
    print("Current orientation yawOffset: " .. tostring(config.orientation and config.orientation.yawOffset or 0))
    print("Usage: navtool orientation <degrees>")
    print("Try 90 or -90 if the craft thinks it is pointed 90 degrees off target.")
    return
  end
  config.orientation = type(config.orientation) == "table" and config.orientation or {}
  config.orientation.yawOffset = offset
  saveConfig(config)
  print("Orientation yawOffset set to " .. tostring(offset) .. " degrees.")
  print("Restart navtool for the running flight controller to use it.")
end

local function diagnose(config)
  print("CC-NavTool telemetry diagnostics")
  print("CC:Sable sublevel available: " .. tostring(sublevelAvailable(config)))
  print("Configured telemetryPeripheral: " .. tostring(config.telemetryPeripheral))
  print("Configured orientationPeripheral: " .. tostring(config.orientationPeripheral))
  print("Configured navigationTablePeripheral: " .. tostring(config.navigationTablePeripheral))
  print("Configured gimbalSensorPeripheral: " .. tostring(config.gimbalSensorPeripheral))
  print("Configured altitudeSensorPeripheral: " .. tostring(config.altitudeSensorPeripheral))
  print("Configured physicsAssemblerPeripheral: " .. tostring(config.physicsAssemblerPeripheral))
  print("Detected telemetryPeripheral: " .. tostring(telemetryName(config)))
  print("Detected orientationPeripheral: " .. tostring(orientationName(config, telemetryName(config))))
  local avionics = avionicsNames(config)
  print("Detected navigation_table: " .. tostring(avionics.navigationTable))
  print("Detected gimbal_sensor: " .. tostring(avionics.gimbalSensor))
  print("Detected altitude_sensor: " .. tostring(avionics.altitudeSensor))
  print("Detected physics_assembler: " .. tostring(avionics.physicsAssembler))
  print("Detected velocity_sensor count: " .. tostring(#(avionics.velocitySensors or {})))
  if sublevelAvailable(config) then
    print("Sublevel pose: " .. shortText(callSublevel("getLogicalPose") or callSublevel("getLastPose")))
    print("Sublevel velocity: " .. shortText(callSublevel("getLinearVelocity") or callSublevel("getVelocity")))
    print("Sublevel angular velocity: " .. shortText(callSublevel("getAngularVelocity")))
    print("Sublevel mass: " .. shortText(callSublevel("getMass")))
  end
  local fix, gpsErr = gpsFix(config)
  print("GPS position: " .. shortText(fix and fix.position))
  print("GPS velocity: " .. shortText(fix and fix.velocity))
  if gpsErr then print("GPS error: " .. tostring(gpsErr)) end
  print("")
  local candidates = {
    "getLogicalPose", "getPose", "getPosition", "getShipPosition", "getWorldPosition", "getBlockPosition",
    "getLinearVelocity", "getVelocity", "getShipVelocity", "getAngularVelocity", "getMass",
    "getOrientation", "getRotation", "getFacing", "getDirection", "getYaw", "getHeading", "getHeadingRad", "getBearing", "getBearingRad",
    "getAngles", "getAnglesRad", "getAngularRates", "getAngularRatesRad", "getGravity", "getLinearAcceleration",
    "getHeight", "getVerticalSpeed", "getAirPressure", "getAxis", "getCenterOfMass", "getSubLevelId", "getSubLevelName",
    "getX", "getY", "getZ", "getWorldX", "getWorldY", "getWorldZ", "getShipX", "getShipY", "getShipZ",
  }
  for _, name in ipairs(peripheral.getNames()) do
    print("Peripheral: " .. name .. " (" .. tostring(peripheral.getType(name)) .. ")")
    local available = methods(name)
    print("Methods: " .. table.concat(available, ", "))
    for _, method in ipairs(candidates) do
      if has(available, method) then
        local ok, a, b, c = pcall(peripheral.call, name, method)
        if ok then
          if b ~= nil or c ~= nil then
            print("  " .. method .. " => " .. shortText({ a, b, c }))
          else
            print("  " .. method .. " => " .. shortText(a))
          end
        else
          print("  " .. method .. " failed: " .. tostring(a))
        end
      end
    end
    print("")
  end
  local state = snapshot(config, { detail = true })
  print("Normalized position: " .. shortText(state.position))
  print("Normalized velocity: " .. shortText(state.velocity))
  print("Normalized body velocity: " .. shortText(state.bodyVelocity))
  print("Normalized heading: " .. shortText(state.heading) .. " via " .. tostring(state.headingSource or "unknown"))
  print("Normalized attitude: " .. shortText(state.gimbalAngles))
  print("Normalized altitude: " .. shortText(state.altitude))
end

local function scaledStrength(config, outputName, ratio)
  local output = config.outputs and config.outputs[outputName]
  if type(output) ~= "table" then return 0 end
  return math.max(0, math.min(outputMaximum(config, output), math.ceil(outputMaximum(config, output) * math.max(0, math.min(1, ratio)))))
end

local function horizontalDistance(a, b)
  if not a or not b then return nil end
  local dx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
  local dz = (tonumber(a.z) or 0) - (tonumber(b.z) or 0)
  return math.sqrt(dx * dx + dz * dz)
end

local function automationOutputs(config, state)
  local mode = state.mode or "standby"
  local outputs = {}
  local notes = {}
  local automation = type(config.automation) == "table" and config.automation or {}
  local navigation = type(config.navigation) == "table" and config.navigation or {}
  local altitudeDeadband = tonumber(automation.altitudeDeadband) or 1.5
  local verticalScale = tonumber(automation.verticalScale) or 12
  local thrustStartDistance = tonumber(automation.thrustStartDistance) or navigation.arrivalRadius or 5
  local thrustFullDistance = tonumber(automation.thrustFullDistance) or navigation.slowdownRadius or 50
  local steeringDeadband = tonumber(automation.steeringDeadband) or 0.12
  local steeringScale = tonumber(automation.steeringScale) or 0.8
  local headingMinimumSpeed = tonumber(automation.headingMinimumSpeed) or 0.25
  local headingUnknownForwardRatio = tonumber(automation.headingUnknownForwardRatio) or 0.25
  local steeringInvert = automation.steeringInvert == true
  if mode == "standby" then
    notes[#notes + 1] = "standby"
    return outputs, notes
  end
  if not state.telemetry or not state.position then
    notes[#notes + 1] = "no telemetry position"
    return outputs, notes
  end
  if mode == "navigate" or mode == "return-home" then
    if not state.target then
      notes[#notes + 1] = "no target"
      return outputs, notes
    end
    local altitudeError = (tonumber(state.target.y) or state.position.y) - state.position.y
    if altitudeError > altitudeDeadband then
      outputs.up = scaledStrength(config, "up", math.abs(altitudeError) / verticalScale)
    elseif altitudeError < -altitudeDeadband then
      outputs.down = scaledStrength(config, "down", math.abs(altitudeError) / verticalScale)
    end
    local horizontal = horizontalDistance(state.position, state.target)
    if horizontal and horizontal > thrustStartDistance then
      local forwardRatio = math.min(1, horizontal / thrustFullDistance)
      local targetHeading = normalizeHorizontal({ x = (tonumber(state.target.x) or state.position.x) - state.position.x, z = (tonumber(state.target.z) or state.position.z) - state.position.z })
      local heading, headingSource = state.heading, state.headingSource
      if not heading then heading, headingSource = headingFromPose(config, state.pose) end
      if not heading then heading, headingSource = headingFromVelocity(state.velocity, headingMinimumSpeed) end
      if heading and targetHeading then
        local turn = heading.z * targetHeading.x - heading.x * targetHeading.z
        local alignment = math.max(0, math.min(1, heading.x * targetHeading.x + heading.z * targetHeading.z))
        if steeringInvert then turn = -turn end
        if math.abs(turn) > steeringDeadband then
          local strength = scaledStrength(config, turn > 0 and "left" or "right", math.min(1, math.abs(turn) / steeringScale))
          if turn > 0 then outputs.left = strength else outputs.right = strength end
        end
        outputs.forward = scaledStrength(config, "forward", forwardRatio * alignment)
        notes[#notes + 1] = string.format("turn %.2f align %.2f via %s", turn, alignment, headingSource or "unknown")
      else
        if headingUnknownForwardRatio > 0 then
          outputs.forward = scaledStrength(config, "forward", forwardRatio * math.max(0, math.min(1, headingUnknownForwardRatio)))
        end
        notes[#notes + 1] = "heading unknown; bootstrapping forward"
      end
    end
    notes[#notes + 1] = string.format("alt %.1f", altitudeError)
    notes[#notes + 1] = horizontal and string.format("horizontal %.1f", horizontal) or "horizontal unknown"
  elseif mode == "hover" then
    local velocity = extractVector(state.velocity)
    local verticalVelocity = velocity and velocity.y or 0
    if verticalVelocity > 0.2 then
      outputs.down = scaledStrength(config, "down", math.min(1, math.abs(verticalVelocity) / 4))
    elseif verticalVelocity < -0.2 then
      outputs.up = scaledStrength(config, "up", math.min(1, math.abs(verticalVelocity) / 4))
    end
    notes[#notes + 1] = string.format("vertical velocity %.2f", verticalVelocity)
  else
    notes[#notes + 1] = "unsupported mode"
  end
  return outputs, notes
end

local function nowSeconds()
  return os.epoch and (os.epoch("utc") / 1000) or os.clock()
end

local function stopReached(config, state, stop)
  if type(stop) ~= "table" then return false end
  local arrived = scheduleStopArrival(config, state, stop)
  return arrived == true
end

setScheduleStop = function(active, schedule, index)
  active.index = index
  active.dwellIndex = nil
  active.dwellUntil = nil
  saveTarget(schedule.stops[index])
  saveMode("navigate")
  saveActiveSchedule(active)
end

local function advanceScheduleStop(config, active, schedule, index, state)
  local stop = schedule.stops[index]
  if not stopReached(config, state, stop) then
    if active.dwellUntil or active.dwellIndex then
      active.dwellUntil = nil
      active.dwellIndex = nil
      saveActiveSchedule(active)
    end
    return false, "travel"
  end

  local dwell = math.max(0, tonumber(schedule.dwell) or 0)
  local now = nowSeconds()
  if dwell > 0 then
    if active.dwellIndex ~= index or not active.dwellUntil then
      active.dwellIndex = index
      active.dwellUntil = now + dwell
      saveActiveSchedule(active)
      return false, "dwell"
    end
    if now < active.dwellUntil then return false, "dwell" end
  end

  active.dwellIndex = nil
  active.dwellUntil = nil
  if index >= #schedule.stops then
    if schedule.loop == true then
      setScheduleStop(active, schedule, 1)
      return true, "loop"
    end
    saveActiveSchedule(nil)
    saveMode("standby")
    clearOutputs(config)
    return true, "complete"
  end

  setScheduleStop(active, schedule, index + 1)
  return true, "advance"
end

serverAutomationTick = function(config, outputController)
  local state = snapshot(config, { library = false, gps = false })
  local active = state.activeSchedule
  if active then
    if active.paused == true then
      state.mode = "standby"
      local requested, notes = automationOutputs(config, state)
      local applied = outputController and outputController(requested, true) or applyOutputs(config, requested)
      notes[#notes + 1] = "schedule paused"
      lastAutomationDebug = { requested = requested, applied = applied, notes = notes, summary = automationSummary(notes) }
      state.automation = lastAutomationDebug
      return state, requested, applied, notes
    end
    local schedules = loadSchedules()
    local schedule = schedules[active.name]
    if not schedule or type(schedule.stops) ~= "table" or #schedule.stops == 0 then
      saveActiveSchedule(nil)
      saveMode("standby")
      clearOutputs(config)
      state = snapshot(config, { library = false, gps = false })
    else
      local index = math.max(1, math.min(#schedule.stops, tonumber(active.index) or 1))
      local stop = schedule.stops[index]
      if not state.target or state.target.name ~= stop.name or tonumber(state.target.x) ~= tonumber(stop.x) or tonumber(state.target.y) ~= tonumber(stop.y) or tonumber(state.target.z) ~= tonumber(stop.z) then
        saveTarget(stop)
        saveMode("navigate")
        state = snapshot(config, { library = false, gps = false })
      end
      local advanced = advanceScheduleStop(config, active, schedule, index, state)
      if advanced then
        state = snapshot(config, { library = false, gps = false })
      end
    end
  end
  local requested, notes = automationOutputs(config, state)
  local applied = outputController and outputController(requested, state.mode == "standby") or applyOutputs(config, requested)
  lastAutomationDebug = { requested = requested, applied = applied, notes = notes, summary = automationSummary(notes) }
  state.automation = lastAutomationDebug
  return state, requested, applied, notes
end

local function automate(config)
  local interval = math.max(0.05, tonumber(config.updateInterval) or 0.05)
  local outputController = makeOutputController(config)
  print("CC-NavTool automation")
  print("Redstone outputs are bounded by config safety limits.")
  print("Press Q to stop automation and return to standby.")
  while true do
    local state = snapshot(config, { library = false })
    local active = state.activeSchedule
    local requested, notes = automationOutputs(config, state)
    local applied = outputController(requested, state.mode == "standby")
    term.clear()
    term.setCursorPos(1, 1)
    print("CC-NavTool Automate")
    print("Telemetry: " .. (state.telemetry and "online" or "offline"))
    print("Mode: " .. tostring(state.mode or "standby"))
    if not active then
      print("Active schedule: none")
      print("Use the GUI or remote to run a saved schedule.")
    else
      local schedules = loadSchedules()
      local schedule = schedules[active.name]
      if not schedule or type(schedule.stops) ~= "table" or #schedule.stops == 0 then
        print("Active schedule is missing. Clearing.")
        saveActiveSchedule(nil)
        saveMode("standby")
      else
        local index = math.max(1, math.min(#schedule.stops, tonumber(active.index) or 1))
        local stop = schedule.stops[index]
        if not state.target or state.target.name ~= stop.name or tonumber(state.target.x) ~= tonumber(stop.x) or tonumber(state.target.y) ~= tonumber(stop.y) or tonumber(state.target.z) ~= tonumber(stop.z) then
          saveTarget(stop)
          saveMode("navigate")
        end
        print("Schedule: " .. active.name)
        print("Stop: " .. index .. "/" .. #schedule.stops .. " " .. tostring(stop.name or ""))
        print(string.format("Target: %.1f %.1f %.1f", tonumber(stop.x) or 0, tonumber(stop.y) or 0, tonumber(stop.z) or 0))
        if state.distanceToTarget then print(string.format("Distance: %.1f", state.distanceToTarget)) else print("Distance: unknown") end
        local advanced, phase = advanceScheduleStop(config, active, schedule, index, state)
        local dwellRemaining = active.dwellUntil and math.max(0, active.dwellUntil - nowSeconds()) or 0
        if phase == "dwell" then print(string.format("Dwell: %.1fs remaining", dwellRemaining))
        elseif phase == "advance" then print("Advancing to next stop.")
        elseif phase == "loop" then print("Looping schedule.")
        elseif phase == "complete" then print("Schedule complete. Returning to standby.")
        else print("Schedule phase: travel") end
        if advanced then state = snapshot(config, { library = false }) end
      end
    end
    print("")
    print("Outputs: " .. textutils.serialize(applied))
    print("Notes: " .. table.concat(notes, ", "))
    local timer = os.startTimer(interval)
    local event, value
    repeat event, value = os.pullEvent() until event == "timer" and value == timer or event == "key"
    if event == "key" and value == keys.q then saveActiveSchedule(nil); saveMode("standby"); outputController(nil, true); clearOutputs(config); return end
  end
end

local function screen(config)
  if config.monitorPeripheral and peripheral.isPresent(config.monitorPeripheral) then
    local monitor = peripheral.wrap(config.monitorPeripheral)
    if monitor then monitor.setTextScale(0.5); return monitor, config.monitorPeripheral end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local monitor = peripheral.wrap(name)
      if monitor then monitor.setTextScale(0.5); return monitor, name end
    end
  end
  return term.current(), nil
end

local function color(target, background, foreground)
  if target.isColor and target.isColor() then
    target.setBackgroundColor(background)
    target.setTextColor(foreground)
  end
end

local function writeAt(target, x, y, text)
  target.setCursorPos(x, y)
  target.write(text)
end

local function line(target, x, y, label, value)
  writeAt(target, x, y, label .. tostring(value or "unknown"))
end

local function drawBox(target, x1, y1, x2, y2, title)
  color(target, colors.gray, colors.white)
  for y = y1, y2 do
    target.setCursorPos(x1, y)
    target.write(string.rep(" ", x2 - x1 + 1))
  end
  if title then writeAt(target, x1 + 1, y1, title) end
  color(target, colors.black, colors.white)
end

local function drawButton(target, id, label, x1, y1, x2, y2, background)
  buttons[id] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
  local width = x2 - x1 + 1
  if #label > width then label = label:sub(1, width) end
  color(target, background or colors.gray, colors.white)
  for y = y1, y2 do
    target.setCursorPos(x1, y)
    target.write(string.rep(" ", x2 - x1 + 1))
  end
  writeAt(target, x1 + math.floor((width - #label) / 2), y1 + math.floor((y2 - y1) / 2), label)
  color(target, colors.black, colors.white)
end

local function drawButtonRow(target, items, y, x1, x2)
  local width = x2 - x1 + 1
  local gap = 1
  local buttonWidth = math.max(1, math.floor((width - gap * (#items - 1)) / #items))
  for index, item in ipairs(items) do
    local left = x1 + (index - 1) * (buttonWidth + gap)
    local right = index == #items and x2 or math.min(x2, left + buttonWidth - 1)
    drawButton(target, item[1], item[2], left, y, right, y, item[3])
  end
end

local function hitButton(x, y)
  for id, button in pairs(buttons) do
    if x >= button.x1 and x <= button.x2 and y >= button.y1 and y <= button.y2 then return id end
  end
end

local function compact(value)
  local text = textutils.serialize(value)
  if #text > 38 then return text:sub(1, 35) .. "..." end
  return text
end

local function vectorText(value)
  if type(value) ~= "table" then return "unknown" end
  local source = value.position or value.pos or value.translation or value
  local x, y, z = tonumber(source.x or source[1]), tonumber(source.y or source[2]), tonumber(source.z or source[3])
  if not x or not y or not z then return compact(value) end
  return string.format("%.1f %.1f %.1f", x, y, z)
end

local function targetText(target)
  if not target then return "none" end
  local name = target.name and (target.name .. " ") or ""
  return string.format("%s%.1f %.1f %.1f", name, tonumber(target.x) or 0, tonumber(target.y) or 0, tonumber(target.z) or 0)
end

renderMonitorStatus = function(config, state, requested, applied, notes)
  local name = config and config.monitorPeripheral
  if not name or not peripheral.isPresent(name) or not hasPeripheralType(name, "monitor") then return false end
  local monitor = peripheral.wrap(name)
  if not monitor then return false end
  pcall(monitor.setTextScale, tonumber(config.monitorTextScale) or 0.5)
  local width, height = monitor.getSize()
  color(monitor, colors.black, colors.white)
  monitor.clear()
  color(monitor, colors.blue, colors.white)
  monitor.setCursorPos(1, 1)
  monitor.write(string.rep(" ", width))
  writeAt(monitor, 2, 1, "CC-NavTool Monitor")
  color(monitor, colors.black, colors.white)

  state = state or snapshot(config, { library = false, schedule = false, gps = false })
  requested = requested or {}
  applied = applied or {}
  notes = notes or {}
  local y = 3
  line(monitor, 2, y, "Mode: ", state.mode or "standby"); y = y + 1
  line(monitor, 2, y, "Telemetry: ", state.telemetry and "ONLINE" or "OFFLINE"); y = y + 1
  line(monitor, 2, y, "Source: ", state.source or state.peripheral or "none"); y = y + 1
  line(monitor, 2, y, "Position: ", vectorText(state.position)); y = y + 1
  line(monitor, 2, y, "Velocity: ", vectorText(state.velocity)); y = y + 1
  line(monitor, 2, y, "Heading: ", vectorText(state.heading)); y = y + 1
  line(monitor, 2, y, "Target: ", targetText(state.target)); y = y + 1
  if state.distanceToTarget then line(monitor, 2, y, "Distance: ", string.format("%.1f", state.distanceToTarget)); y = y + 1 end
  if state.activeSchedule then
    line(monitor, 2, y, "Schedule: ", tostring(state.activeSchedule.name) .. " #" .. tostring(state.activeSchedule.index)); y = y + 1
  end
  y = y + 1
  line(monitor, 2, y, "Applied: ", string.format("F%s Rev%s L%s Rt%s U%s D%s", applied.forward or 0, applied.reverse or 0, applied.left or 0, applied.right or 0, applied.up or 0, applied.down or 0)); y = y + 1
  line(monitor, 2, y, "Request: ", string.format("F%s Rev%s L%s Rt%s U%s D%s", requested.forward or 0, requested.reverse or 0, requested.left or 0, requested.right or 0, requested.up or 0, requested.down or 0)); y = y + 1
  for _, note in ipairs(notes) do
    if y > height then break end
    writeAt(monitor, 2, y, tostring(note):sub(1, math.max(1, width - 2)))
    y = y + 1
  end
  return true
end

local function drawInterface(config, target, menu, state)
  buttons = {}
  state = state or snapshot(config)
  local width, height = target.getSize()
  color(target, colors.black, colors.white)
  target.clear()
  color(target, colors.blue, colors.white)
  target.setCursorPos(1, 1)
  target.write(string.rep(" ", width))
  writeAt(target, 2, 1, "CC-NavTool Aircraft " .. VERSION)
  color(target, colors.black, colors.white)
  drawBox(target, 2, 3, width - 1, 8, " STATUS ")
  line(target, 4, 4, "Telemetry: ", state.telemetry and "ONLINE" or "OFFLINE")
  line(target, 4, 5, "Peripheral: ", state.peripheral or "none")
  line(target, 4, 6, "Network: ", (config.network and config.network.enabled) and "enabled" or "disabled")
  line(target, 4, 7, "Target: ", targetText(state.target))
  line(target, 4, 8, "Mode: ", state.mode or "standby")
  line(target, math.max(28, math.floor(width / 2)), 4, "Position: ", vectorText(state.position))
  line(target, math.max(28, math.floor(width / 2)), 5, "Velocity: ", vectorText(state.velocity))
  line(target, math.max(28, math.floor(width / 2)), 6, "Heading: ", vectorText(state.heading))
  line(target, math.max(28, math.floor(width / 2)), 7, "Waypoints: ", #(state.waypointNames or {}))
  line(target, math.max(28, math.floor(width / 2)), 8, "Schedules: ", #(state.scheduleNames or {}))
  drawButtonRow(target, {
    { "details", "DETAILS", colors.lightBlue },
    { "menu-routes", menu == "routes" and "ROUTES ^" or "ROUTES", colors.green },
    { "menu-flight", menu == "flight" and "FLIGHT ^" or "FLIGHT", colors.cyan },
    { "menu-system", menu == "system" and "SYSTEM ^" or "SYSTEM", colors.blue },
  }, 10, 2, width - 2)
  if menu == "routes" then
    drawBox(target, 2, 12, width - 2, 15, " ROUTES ")
    drawButtonRow(target, {
      { "target", "SET TARGET", colors.green },
      { "clear", "CLEAR TARGET", colors.orange },
    }, 13, 4, width - 4)
    drawButtonRow(target, {
      { "waypoint", "SAVE WP", colors.lime },
      { "schedule", "NEW SCHED", colors.green },
      { "run-schedule", "RUN SCHED", colors.cyan },
    }, 14, 4, width - 4)
  elseif menu == "flight" then
    drawBox(target, 2, 12, width - 2, 15, " FLIGHT ")
    drawButtonRow(target, {
      { "mode-nav", "NAV MODE", colors.cyan },
      { "standby", "STANDBY", colors.gray },
    }, 13, 4, width - 4)
    drawButtonRow(target, {
      { "automate", "AUTOMATE", colors.cyan },
      { "stop", "OUTPUTS OFF", colors.red },
    }, 14, 4, width - 4)
  elseif menu == "system" then
    drawBox(target, 2, 12, width - 2, 15, " SYSTEM ")
    drawButtonRow(target, {
      { "refresh", "REFRESH", colors.blue },
      { "server", "START SERVER", colors.lime },
    }, 13, 4, width - 4)
    drawButtonRow(target, {
      { "update", "UPDATE", colors.purple },
      { "uninstall", "UNINSTALL", colors.brown },
    }, 14, 4, width - 4)
  else
    writeAt(target, 2, 12, "Choose Routes, Flight, or System for actions.")
  end
  drawButton(target, "exit", "EXIT", 2, height - 2, width - 2, height - 1, colors.gray)
  writeAt(target, 2, height, "Touch/click. Q exits. Server blocks this screen while running.")
end

local function showDetails(config, target)
  local state = snapshot(config)
  local width, height = target.getSize()
  buttons = {}
  color(target, colors.black, colors.white)
  target.clear()
  color(target, colors.blue, colors.white)
  target.setCursorPos(1, 1)
  target.write(string.rep(" ", width))
  writeAt(target, 2, 1, "Aircraft Telemetry Details")
  color(target, colors.black, colors.white)
  line(target, 2, 3, "Telemetry: ", state.telemetry and "ONLINE" or "OFFLINE")
  line(target, 2, 4, "Peripheral: ", state.peripheral or "none")
  line(target, 2, 5, "Target: ", targetText(state.target))
  line(target, 2, 6, "Mode: ", state.mode or "standby")
  line(target, 2, 7, "Position: ", vectorText(state.position))
  line(target, 2, 8, "Velocity: ", vectorText(state.velocity))
  line(target, 2, 9, "Heading: ", vectorText(state.heading) .. " via " .. tostring(state.headingSource or "unknown"))
  line(target, 2, 10, "Orientation peripheral: ", state.orientationPeripheral or "none")
  line(target, 2, 11, "Angular velocity: ", compact(state.angularVelocity))
  line(target, 2, 12, "Mass: ", state.mass)
  line(target, 2, 14, "Network host: ", config.network and config.network.host)
  line(target, 2, 15, "Channel: ", config.network and (config.network.channel or config.network.protocol))
  line(target, 2, 16, "Raw orientation: ", compact(state.rawOrientation or state.pose))
  local y = 18
  for _, name in ipairs(state.waypointNames or {}) do
    if y >= height - 3 then break end
    line(target, 2, y, "WP " .. name .. ": ", targetText(state.waypoints[name]))
    y = y + 1
  end
  for _, name in ipairs(state.scheduleNames or {}) do
    if y >= height - 3 then break end
    local schedule = state.schedules[name]
    line(target, 2, y, "SCH " .. name .. ": ", tostring(#(schedule.stops or {})) .. " stops")
    y = y + 1
  end
  drawButton(target, "back", "BACK", 2, height - 2, width - 2, height - 1, colors.gray)
end

local function interface(config)
  local target, monitorName = screen(config)
  local menu
  local state = snapshot(config)
  local refreshTimer
  local function scheduleRefresh(delay)
    refreshTimer = os.startTimer(delay or 1.0)
  end
  drawInterface(config, target, menu, state)
  scheduleRefresh()
  while true do
    local event, side, x, y = os.pullEvent()
    if event == "key" and side == keys.q then return end
    if event == "timer" and side == refreshTimer then
      refreshTimer = nil
      if buttons["menu-routes"] then
        state = snapshot(config)
        drawInterface(config, target, menu, state)
      end
      scheduleRefresh()
    end
    if event == "mouse_click" then
      -- mouse_click returns button, x, y. Keep the terminal coordinates.
    elseif event == "monitor_touch" and side ~= monitorName then
      x, y = nil, nil
    elseif event ~= "monitor_touch" then
      x, y = nil, nil
    end
    local action = x and hitButton(x, y)
    if action == "menu-routes" then menu = menu == "routes" and nil or "routes"; drawInterface(config, target, menu, state)
    elseif action == "menu-flight" then menu = menu == "flight" and nil or "flight"; drawInterface(config, target, menu, state)
    elseif action == "menu-system" then menu = menu == "system" and nil or "system"; drawInterface(config, target, menu, state)
    elseif action == "refresh" then state = snapshot(config); drawInterface(config, target, menu, state)
    elseif action == "details" then showDetails(config, target)
    elseif action == "back" then drawInterface(config, target, menu, state)
    elseif action == "target" then promptTarget(); state = snapshot(config); drawInterface(config, target, menu, state)
    elseif action == "waypoint" then promptWaypoint(config); state = snapshot(config); drawInterface(config, target, menu, state)
    elseif action == "schedule" then promptSchedule(); state = snapshot(config); drawInterface(config, target, menu, state)
    elseif action == "run-schedule" then promptRunSchedule(); state = snapshot(config); drawInterface(config, target, menu, state)
    elseif action == "automate" then automate(config); state = snapshot(config); drawInterface(config, target, menu, state)
    elseif action == "mode-nav" then saveMode("navigate"); state.mode = "navigate"; drawInterface(config, target, menu, state)
    elseif action == "standby" then saveMode("standby"); state.mode = "standby"; drawInterface(config, target, menu, state)
    elseif action == "clear" then if fs.exists(TARGET_PATH) then fs.delete(TARGET_PATH) end; state.target = nil; drawInterface(config, target, menu, state)
    elseif action == "stop" then clearOutputs(config); saveMode("standby"); state.mode = "standby"; drawInterface(config, target, menu, state)
    elseif action == "server" then target.clear(); writeAt(target, 2, 2, "Starting remote server..."); server(config); return
    elseif action == "update" then target.clear(); writeAt(target, 2, 2, "Updating aircraft package..."); shell.run(ROOT .. "/update.lua"); return
    elseif action == "uninstall" then target.clear(); writeAt(target, 2, 2, "Running uninstall..."); shell.run(ROOT .. "/uninstall.lua"); return
    elseif action == "exit" then return end
  end
end

local command = (args[1] or "ui"):lower()
if command == "update" then shell.run(ROOT .. "/update.lua"); return end
if command == "uninstall" then shell.run(ROOT .. "/uninstall.lua"); return end
if command == "version" then print(VERSION); return end

local config, err = loadConfig()
if not config then printError("Config error: " .. err); return end
if config._migrated then config._migrated = nil; saveConfig(config) end
if command == "setup" or command == "onboarding" then onboarding(config, true); return end
config = onboarding(config, false)
if command == "status" then status(config)
elseif command == "orientation" or command == "yaw-offset" then setOrientationOffset(config, args[2])
elseif command == "diagnose" then diagnose(config)
elseif command == "server" then server(config, args[2] == "debug")
elseif command == "ui" or command == "run" then interface(config)
elseif command == "automate" then automate(config)
elseif command == "outputs-off" or command == "stop" then clearOutputs(config); print("Outputs cleared.")
else
  print("Usage: navtool ui|status|diagnose|orientation|server|automate|setup|update|uninstall|outputs-off|version")
end
