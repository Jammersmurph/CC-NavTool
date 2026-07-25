local VERSION = "0.3.0-dev"
local ROOT = "/navtool"
local CONFIG_PATH = ROOT .. "/config.lua"
local TARGET_PATH = ROOT .. "/target.db"
local args = { ... }

local function loadConfig()
  local ok, config = pcall(dofile, CONFIG_PATH)
  if not ok or type(config) ~= "table" then return nil, tostring(config) end
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

local function telemetryName(config)
  if config.telemetryPeripheral and peripheral.isPresent(config.telemetryPeripheral) then
    return config.telemetryPeripheral
  end
  for _, name in ipairs(peripheral.getNames()) do
    local available = methods(name)
    if has(available, "getLogicalPose") or (has(available, "getLinearVelocity") and has(available, "getAngularVelocity")) then
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
    if output.side and not cleared[output.side] then
      pcall(redstone.setAnalogOutput, output.side, 0)
      pcall(redstone.setOutput, output.side, false)
      cleared[output.side] = true
    end
  end
end

local function loadTarget()
  if not fs.exists(TARGET_PATH) then return nil end
  local file = fs.open(TARGET_PATH, "r")
  local data = textutils.unserialize(file.readAll())
  file.close()
  return data
end

local function saveTarget(target)
  local file = fs.open(TARGET_PATH, "w")
  file.write(textutils.serialize(target))
  file.close()
end

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return side
    end
  end
end

local function snapshot(config)
  local name = telemetryName(config)
  local target = loadTarget()
  if not name then return { version = VERSION, telemetry = false, target = target } end
  return {
    version = VERSION,
    telemetry = true,
    peripheral = name,
    pose = callFirst(name, { "getLogicalPose", "getPose" }),
    velocity = callFirst(name, { "getLinearVelocity", "getVelocity" }),
    angularVelocity = callFirst(name, { "getAngularVelocity" }),
    mass = callFirst(name, { "getMass" }),
    target = target,
  }
end

local function server(config)
  if not config.network or not config.network.enabled then
    printError("Networking is disabled in /navtool/config.lua")
    return
  end
  local modem = openModem()
  if not modem then printError("No wired or wireless modem found."); return end
  local protocol = config.network.protocol or "cc-navtool"
  local host = config.network.host or "navtool-aircraft"
  rednet.host(protocol, host)
  print("navtool remote server online")
  print("Host: " .. host)
  while true do
    local sender, request = rednet.receive(protocol)
    if type(request) == "table" then
      local valid = (config.network.sharedKey or "") == "" or request.key == config.network.sharedKey
      local response = { ok = false, error = "unauthorized" }
      if valid then
        if request.command == "status" then
          response = { ok = true, data = snapshot(config) }
        elseif request.command == "set-target" and type(request.target) == "table" then
          saveTarget(request.target)
          response = { ok = true, target = request.target }
        elseif request.command == "clear-target" then
          if fs.exists(TARGET_PATH) then fs.delete(TARGET_PATH) end
          response = { ok = true }
        elseif request.command == "stop" or request.command == "outputs-off" then
          clearOutputs(config)
          response = { ok = true }
        else
          response = { ok = false, error = "unsupported command" }
        end
      end
      rednet.send(sender, response, protocol)
    end
  end
end

local function status(config)
  local state = snapshot(config)
  print("CC-NavTool " .. VERSION)
  print("Telemetry: " .. (state.telemetry and "online" or "not found"))
  if state.peripheral then print("Peripheral: " .. state.peripheral) end
  print("Target: " .. textutils.serialize(state.target))
  print("Networking: " .. ((config.network and config.network.enabled) and "enabled" or "disabled"))
end

local config, err = loadConfig()
if not config then printError("Config error: " .. err); return end
local command = (args[1] or "status"):lower()
if command == "status" then status(config)
elseif command == "server" then server(config)
elseif command == "update" then shell.run(ROOT .. "/update.lua")
elseif command == "outputs-off" or command == "stop" then clearOutputs(config); print("Outputs cleared.")
elseif command == "version" then print(VERSION)
else
  print("Usage: navtool status|server|update|outputs-off|version")
end
