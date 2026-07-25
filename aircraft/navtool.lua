local VERSION = "0.3.0-dev"
local ROOT = "/navtool"
local CONFIG_PATH = ROOT .. "/config.lua"
local TARGET_PATH = ROOT .. "/target.db"
local WAYPOINTS_PATH = ROOT .. "/waypoints.db"
local MODE_PATH = ROOT .. "/mode.db"
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

local function saveTarget(target)
  local file = fs.open(TARGET_PATH, "w")
  file.write(textutils.serialize(target))
  file.close()
end

local function extractVector(value)
  if type(value) ~= "table" then return nil end
  local source = value.position or value.pos or value.translation or value
  local x, y, z = tonumber(source.x or source[1]), tonumber(source.y or source[2]), tonumber(source.z or source[3])
  if x and y and z then return { x = x, y = y, z = z } end
end

local function waypointList()
  local waypoints = loadWaypoints()
  local names = {}
  for name in pairs(waypoints) do names[#names + 1] = name end
  table.sort(names)
  return waypoints, names
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
  saveTarget({ name = name ~= "" and name or nil, x = x, y = y, z = z })
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
  local telemetry = telemetryName(config)
  local position = extractVector(callFirst(telemetry, { "getLogicalPose", "getPose" }))
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
  local waypoints, names = waypointList()
  local mode = loadMode().mode or "standby"
  if not name then return { version = VERSION, telemetry = false, target = target, waypoints = waypoints, waypointNames = names, mode = mode } end
  return {
    version = VERSION,
    telemetry = true,
    peripheral = name,
    pose = callFirst(name, { "getLogicalPose", "getPose" }),
    velocity = callFirst(name, { "getLinearVelocity", "getVelocity" }),
    angularVelocity = callFirst(name, { "getAngularVelocity" }),
    mass = callFirst(name, { "getMass" }),
    target = target,
    waypoints = waypoints,
    waypointNames = names,
    mode = mode,
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
        elseif request.command == "set-mode" then
          local mode = tostring(request.mode or "standby")
          if mode == "standby" or mode == "navigate" or mode == "hover" or mode == "return-home" then
            saveMode(mode)
            response = { ok = true, mode = mode }
          else
            response = { ok = false, error = "unsupported mode" }
          end
        elseif request.command == "waypoint-list" then
          local waypoints, names = waypointList()
          response = { ok = true, waypoints = waypoints, names = names }
        elseif request.command == "save-waypoint" and type(request.waypoint) == "table" then
          local waypoint = request.waypoint
          local name = tostring(waypoint.name or "")
          local x, y, z = tonumber(waypoint.x), tonumber(waypoint.y), tonumber(waypoint.z)
          if name ~= "" and x and y and z then
            local waypoints = loadWaypoints()
            waypoints[name] = { name = name, x = x, y = y, z = z }
            saveWaypoints(waypoints)
            response = { ok = true, waypoint = waypoints[name] }
          else
            response = { ok = false, error = "invalid waypoint" }
          end
        elseif request.command == "delete-waypoint" then
          local name = tostring(request.name or "")
          local waypoints = loadWaypoints()
          waypoints[name] = nil
          saveWaypoints(waypoints)
          response = { ok = true }
        elseif request.command == "goto-waypoint" then
          local name = tostring(request.name or "")
          local waypoints = loadWaypoints()
          if waypoints[name] then
            saveTarget(waypoints[name])
            saveMode("navigate")
            response = { ok = true, target = waypoints[name] }
          else
            response = { ok = false, error = "waypoint not found" }
          end
        elseif request.command == "stop" or request.command == "outputs-off" then
          clearOutputs(config)
          saveMode("standby")
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
  print("Mode: " .. tostring(state.mode or "standby"))
  print("Waypoints: " .. tostring(#(state.waypointNames or {})))
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

local function drawInterface(config, target)
  buttons = {}
  local state = snapshot(config)
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
  line(target, math.max(28, math.floor(width / 2)), 4, "Position: ", vectorText(state.pose))
  line(target, math.max(28, math.floor(width / 2)), 5, "Velocity: ", vectorText(state.velocity))
  line(target, math.max(28, math.floor(width / 2)), 6, "Mass: ", state.mass)
  line(target, math.max(28, math.floor(width / 2)), 7, "Waypoints: ", #(state.waypointNames or {}))
  local left = 2
  local right = math.max(18, math.floor(width / 2) - 1)
  local farLeft = right + 2
  local farRight = width - 2
  drawButton(target, "refresh", "REFRESH", left, 10, right, 10, colors.blue)
  drawButton(target, "details", "DETAILS", farLeft, 10, farRight, 10, colors.lightBlue)
  drawButton(target, "target", "SET TARGET", left, 11, right, 11, colors.green)
  drawButton(target, "waypoint", "SAVE WP", farLeft, 11, farRight, 11, colors.lime)
  drawButton(target, "mode-nav", "NAV MODE", left, 12, right, 12, colors.cyan)
  drawButton(target, "mode-hover", "HOVER MODE", farLeft, 12, farRight, 12, colors.cyan)
  drawButton(target, "server", "START SERVER", left, 13, right, 13, colors.lime)
  drawButton(target, "standby", "STANDBY", farLeft, 13, farRight, 13, colors.gray)
  drawButton(target, "clear", "CLEAR TARGET", left, 14, right, 14, colors.orange)
  drawButton(target, "stop", "OUTPUTS OFF", farLeft, 14, farRight, 14, colors.red)
  drawButton(target, "update", "UPDATE", left, 15, right, 15, colors.purple)
  drawButton(target, "uninstall", "UNINSTALL", farLeft, 15, farRight, 15, colors.brown)
  drawButton(target, "exit", "EXIT", left, 17, farRight, 18, colors.gray)
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
  line(target, 2, 7, "Pose: ", compact(state.pose))
  line(target, 2, 8, "Velocity: ", compact(state.velocity))
  line(target, 2, 9, "Angular velocity: ", compact(state.angularVelocity))
  line(target, 2, 10, "Mass: ", state.mass)
  line(target, 2, 12, "Network host: ", config.network and config.network.host)
  line(target, 2, 13, "Protocol: ", config.network and config.network.protocol)
  local y = 15
  for _, name in ipairs(state.waypointNames or {}) do
    if y >= height - 3 then break end
    line(target, 2, y, "WP " .. name .. ": ", targetText(state.waypoints[name]))
    y = y + 1
  end
  drawButton(target, "back", "BACK", 2, height - 2, width - 2, height - 1, colors.gray)
end

local function interface(config)
  local target, monitorName = screen(config)
  drawInterface(config, target)
  while true do
    local event, side, x, y = os.pullEvent()
    if event == "key" and side == keys.q then return end
    if event == "mouse_click" then
      -- mouse_click returns button, x, y. Keep the terminal coordinates.
    elseif event == "monitor_touch" and side ~= monitorName then
      x, y = nil, nil
    elseif event ~= "monitor_touch" then
      x, y = nil, nil
    end
    local action = x and hitButton(x, y)
    if action == "refresh" then drawInterface(config, target)
    elseif action == "details" then showDetails(config, target)
    elseif action == "back" then drawInterface(config, target)
    elseif action == "target" then promptTarget(); drawInterface(config, target)
    elseif action == "waypoint" then promptWaypoint(config); drawInterface(config, target)
    elseif action == "mode-nav" then saveMode("navigate"); drawInterface(config, target)
    elseif action == "mode-hover" then saveMode("hover"); drawInterface(config, target)
    elseif action == "standby" then saveMode("standby"); drawInterface(config, target)
    elseif action == "clear" then if fs.exists(TARGET_PATH) then fs.delete(TARGET_PATH) end; drawInterface(config, target)
    elseif action == "stop" then clearOutputs(config); saveMode("standby"); drawInterface(config, target)
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
if command == "status" then status(config)
elseif command == "server" then server(config)
elseif command == "ui" or command == "run" then interface(config)
elseif command == "outputs-off" or command == "stop" then clearOutputs(config); print("Outputs cleared.")
else
  print("Usage: navtool ui|status|server|update|uninstall|outputs-off|version")
end
