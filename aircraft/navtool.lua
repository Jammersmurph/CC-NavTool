local VERSION = "0.3.0-dev"
local ROOT = "/navtool"
local CONFIG_PATH = ROOT .. "/config.lua"
local TARGET_PATH = ROOT .. "/target.db"
local args = { ... }
local buttons = {}

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

local function drawButton(target, id, label, x1, y1, x2, y2, background)
  buttons[id] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
  color(target, background or colors.gray, colors.white)
  for y = y1, y2 do
    target.setCursorPos(x1, y)
    target.write(string.rep(" ", x2 - x1 + 1))
  end
  writeAt(target, x1 + math.floor((x2 - x1 + 1 - #label) / 2), y1 + math.floor((y2 - y1) / 2), label)
  color(target, colors.black, colors.white)
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

local function drawInterface(config, target)
  buttons = {}
  local state = snapshot(config)
  local width, height = target.getSize()
  color(target, colors.black, colors.white)
  target.clear()
  writeAt(target, 2, 1, "CC-NavTool Aircraft " .. VERSION)
  writeAt(target, 2, 3, "Telemetry: " .. (state.telemetry and "ONLINE" or "OFFLINE"))
  writeAt(target, 2, 4, "Peripheral: " .. tostring(state.peripheral or "none"))
  writeAt(target, 2, 5, "Network: " .. ((config.network and config.network.enabled) and "enabled" or "disabled"))
  writeAt(target, 2, 6, "Target: " .. compact(state.target))
  writeAt(target, 2, 7, "Velocity: " .. compact(state.velocity))
  writeAt(target, 2, 8, "Mass: " .. tostring(state.mass or "unknown"))
  local left = 2
  local right = math.max(18, math.floor(width / 2) - 1)
  local farLeft = right + 2
  local farRight = width - 2
  drawButton(target, "refresh", "REFRESH", left, 9, right, 11, colors.blue)
  drawButton(target, "server", "START SERVER", farLeft, 9, farRight, 11, colors.green)
  drawButton(target, "clear", "CLEAR TARGET", left, 13, right, 15, colors.orange)
  drawButton(target, "stop", "OUTPUTS OFF", farLeft, 13, farRight, 15, colors.red)
  drawButton(target, "exit", "EXIT", left, 17, farRight, 18, colors.gray)
  writeAt(target, 2, height, "Touch/click a button. Q exits.")
end

local function interface(config)
  local target, monitorName = screen(config)
  drawInterface(config, target)
  while true do
    local event, side, x, y = os.pullEvent()
    if event == "key" and side == keys.q then return end
    if event == "mouse_click" then x, y = side, x
    elseif event == "monitor_touch" and side ~= monitorName then x, y = nil, nil
    elseif event ~= "monitor_touch" then x, y = nil, nil end
    local action = x and hitButton(x, y)
    if action == "refresh" then drawInterface(config, target)
    elseif action == "clear" then if fs.exists(TARGET_PATH) then fs.delete(TARGET_PATH) end; drawInterface(config, target)
    elseif action == "stop" then clearOutputs(config); drawInterface(config, target)
    elseif action == "server" then target.clear(); writeAt(target, 2, 2, "Starting remote server..."); server(config); return
    elseif action == "exit" then return end
  end
end

local config, err = loadConfig()
if not config then printError("Config error: " .. err); return end
local command = (args[1] or "ui"):lower()
if command == "status" then status(config)
elseif command == "server" then server(config)
elseif command == "ui" or command == "run" then interface(config)
elseif command == "update" then shell.run(ROOT .. "/update.lua")
elseif command == "outputs-off" or command == "stop" then clearOutputs(config); print("Outputs cleared.")
elseif command == "version" then print(VERSION)
else
  print("Usage: navtool ui|status|server|update|outputs-off|version")
end
