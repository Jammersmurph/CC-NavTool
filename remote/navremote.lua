local VERSION = "0.3.0-dev"
local ROOT = "/navremote"
local CONFIG_PATH = ROOT .. "/config.lua"
local args = { ... }
local buttons = {}

local function loadConfig()
  local ok, config = pcall(dofile, CONFIG_PATH)
  if not ok or type(config) ~= "table" then return nil, tostring(config) end
  return config
end

local function saveConfig(config)
  local file = fs.open(CONFIG_PATH, "w")
  file.write("return " .. textutils.serialize(config) .. "\n")
  file.close()
end

local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      return name
    end
  end
end

local command = (args[1] or "menu"):lower()
if command == "uninstall" then shell.run(ROOT .. "/uninstall.lua"); return end
if command == "update" then shell.run(ROOT .. "/update.lua"); return end
if command == "version" then print(VERSION); return end

local config, err = loadConfig()
if not config then printError("Config error: " .. err); return end
if command ~= "config" and not openModem() then printError("No wired or wireless modem found."); return end

local function request(command, extra)
  local hostId = rednet.lookup(config.protocol or "cc-navtool", config.host or "navtool-aircraft")
  if not hostId then return nil, "Aircraft host not found" end
  local payload = extra or {}
  payload.command = command
  payload.key = config.sharedKey or ""
  rednet.send(hostId, payload, config.protocol or "cc-navtool")
  local sender, response = rednet.receive(config.protocol or "cc-navtool", config.timeout or 3)
  if sender ~= hostId or type(response) ~= "table" then return nil, "No valid response" end
  if not response.ok then return nil, response.error or "Command rejected" end
  return response
end

local function screen()
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

local function drawHeader(target, title)
  local width = target.getSize()
  color(target, colors.blue, colors.white)
  target.setCursorPos(1, 1)
  target.write(string.rep(" ", width))
  writeAt(target, 2, 1, title)
  color(target, colors.black, colors.white)
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

local function showStatus(target)
  local response, requestErr = request("status")
  if not response then printError(requestErr); return end
  local data = response.data or {}
  target = target or term.current()
  color(target, colors.black, colors.white)
  target.clear()
  writeAt(target, 2, 1, "CC-NavTool Remote " .. VERSION)
  writeAt(target, 2, 3, "Host: " .. tostring(config.host))
  writeAt(target, 2, 4, "Telemetry: " .. (data.telemetry and "ONLINE" or "OFFLINE"))
  writeAt(target, 2, 5, "Aircraft version: " .. tostring(data.version))
  if data.peripheral then writeAt(target, 2, 6, "Peripheral: " .. tostring(data.peripheral)) end
  writeAt(target, 2, 8, "Target: " .. compact(data.target))
  writeAt(target, 2, 9, "Pose: " .. compact(data.pose))
  writeAt(target, 2, 10, "Velocity: " .. compact(data.velocity))
  writeAt(target, 2, 11, "Mode: " .. tostring(data.mode or "standby"))
  writeAt(target, 2, 12, "Waypoints: " .. tostring(#(data.waypointNames or {})))
  writeAt(target, 2, 13, "Schedules: " .. tostring(#(data.scheduleNames or {})))
end

local function setTarget()
  write("Name: ")
  local name = read()
  write("X: ")
  local x = tonumber(read())
  write("Y: ")
  local y = tonumber(read())
  write("Z: ")
  local z = tonumber(read())
  if not x or not y or not z then printError("Coordinates must be numbers."); return end
  local response, requestErr = request("set-target", { target = { name = name, x = x, y = y, z = z } })
  if response then print("Destination saved on aircraft.") else printError(requestErr) end
end

local function saveWaypoint()
  term.clear()
  term.setCursorPos(1, 1)
  print("Save Aircraft Waypoint")
  write("Name: ")
  local name = read()
  write("X: ")
  local x = tonumber(read())
  write("Y: ")
  local y = tonumber(read())
  write("Z: ")
  local z = tonumber(read())
  if name == "" or not x or not y or not z then printError("Name and numeric coordinates are required."); sleep(1.5); return end
  local response, requestErr = request("save-waypoint", { waypoint = { name = name, x = x, y = y, z = z } })
  if response then print("Waypoint saved on aircraft.") else printError(requestErr) end
  sleep(1)
end

local function waypointManager(target)
  local response, requestErr = request("waypoint-list")
  local width, height = target.getSize()
  color(target, colors.black, colors.white)
  target.clear()
  drawHeader(target, "Saved Destinations")
  if not response then
    line(target, 2, 3, "Error: ", requestErr)
  else
    local names = response.names or {}
    if #names == 0 then line(target, 2, 3, "Saved destinations: ", "none") end
    local y = 3
    for _, name in ipairs(names) do
      if y >= height - 5 then break end
      line(target, 2, y, name .. ": ", targetText(response.waypoints[name]))
      y = y + 1
    end
  end
  drawButton(target, "wp-add", "ADD", 2, height - 4, math.floor(width / 3), height - 3, colors.green)
  drawButton(target, "wp-goto", "GOTO", math.floor(width / 3) + 2, height - 4, math.floor(width * 2 / 3), height - 3, colors.cyan)
  drawButton(target, "wp-delete", "DELETE", math.floor(width * 2 / 3) + 2, height - 4, width - 2, height - 3, colors.red)
  drawButton(target, "back", "BACK", 2, height - 2, width - 2, height - 1, colors.gray)
end

local function waypointNamePrompt(command)
  term.clear()
  term.setCursorPos(1, 1)
  write("Waypoint name: ")
  local name = read()
  if name == "" then return end
  local response, requestErr = request(command, { name = name })
  if response then print("Done.") else printError(requestErr) end
  sleep(1)
end

local function createSchedule()
  term.clear()
  term.setCursorPos(1, 1)
  print("Create Coordinate Schedule")
  write("Schedule name: ")
  local name = read()
  write("Number of stops: ")
  local count = tonumber(read())
  if name == "" or not count or count < 1 then printError("Name and stop count are required."); sleep(1.5); return end
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
    stops[#stops + 1] = { name = label ~= "" and label or ("Stop " .. index), x = x, y = y, z = z }
  end
  local response, requestErr = request("save-schedule", { schedule = { name = name, stops = stops } })
  if response then print("Schedule saved on aircraft.") else printError(requestErr) end
  sleep(1)
end

local function scheduleNamePrompt(command)
  term.clear()
  term.setCursorPos(1, 1)
  write("Schedule name: ")
  local name = read()
  if name == "" then return end
  local response, requestErr = request(command, { name = name })
  if response then print("Done.") else printError(requestErr) end
  sleep(1)
end

local function scheduleManager(target)
  local response, requestErr = request("schedule-list")
  local width, height = target.getSize()
  color(target, colors.black, colors.white)
  target.clear()
  drawHeader(target, "Coordinate Schedules")
  if not response then
    line(target, 2, 3, "Error: ", requestErr)
  else
    local names = response.names or {}
    if #names == 0 then line(target, 2, 3, "Schedules: ", "none") end
    local y = 3
    if response.active then
      line(target, 2, y, "Active: ", tostring(response.active.name) .. " stop " .. tostring(response.active.index))
      y = y + 1
    end
    for _, name in ipairs(names) do
      if y >= height - 5 then break end
      local schedule = response.schedules[name]
      line(target, 2, y, name .. ": ", tostring(#(schedule.stops or {})) .. " stops")
      y = y + 1
    end
  end
  drawButton(target, "sch-add", "ADD", 2, height - 4, math.floor(width / 4), height - 3, colors.green)
  drawButton(target, "sch-run", "RUN", math.floor(width / 4) + 2, height - 4, math.floor(width / 2), height - 3, colors.cyan)
  drawButton(target, "sch-delete", "DELETE", math.floor(width / 2) + 2, height - 4, math.floor(width * 3 / 4), height - 3, colors.red)
  drawButton(target, "sch-stop", "STOP", math.floor(width * 3 / 4) + 2, height - 4, width - 2, height - 3, colors.orange)
  drawButton(target, "back", "BACK", 2, height - 2, width - 2, height - 1, colors.gray)
end

local function setMode(mode)
  local response, requestErr = request("set-mode", { mode = mode })
  if not response then return requestErr end
end

local function editConfig()
  term.clear()
  term.setCursorPos(1, 1)
  print("Remote Configuration")
  write("Host [" .. tostring(config.host or "navtool-aircraft") .. "]: ")
  local host = read()
  write("Protocol [" .. tostring(config.protocol or "cc-navtool") .. "]: ")
  local protocol = read()
  write("Shared key [hidden, blank keeps]: ")
  local key = read("*")
  write("Timeout seconds [" .. tostring(config.timeout or 3) .. "]: ")
  local timeout = tonumber(read())
  if host ~= "" then config.host = host end
  if protocol ~= "" then config.protocol = protocol end
  if key ~= "" then config.sharedKey = key end
  if timeout then config.timeout = timeout end
  saveConfig(config)
  print("Config saved.")
  sleep(1)
end

local function drawMenu(target, message)
  buttons = {}
  local response, requestErr = request("status")
  local data = response and response.data or {}
  local width, height = target.getSize()
  local left = 2
  local right = math.max(18, math.floor(width / 2) - 1)
  local farLeft = right + 2
  local farRight = width - 2
  color(target, colors.black, colors.white)
  target.clear()
  drawHeader(target, "CC-NavTool Remote " .. VERSION)
  line(target, 2, 3, "Aircraft: ", config.host)
  line(target, 2, 4, "Telemetry: ", data.telemetry and "ONLINE" or "OFFLINE")
  line(target, 2, 5, "Target: ", targetText(data.target))
  line(target, 2, 6, "Mode: ", data.mode or "standby")
  line(target, math.max(28, math.floor(width / 2)), 3, "Version: ", data.version)
  line(target, math.max(28, math.floor(width / 2)), 4, "Position: ", vectorText(data.pose))
  line(target, math.max(28, math.floor(width / 2)), 5, "Velocity: ", vectorText(data.velocity))
  line(target, math.max(28, math.floor(width / 2)), 6, "Waypoints: ", #(data.waypointNames or {}))
  line(target, math.max(28, math.floor(width / 2)), 7, "Schedules: ", #(data.scheduleNames or {}))
  if requestErr then writeAt(target, 2, 7, "Error: " .. requestErr) end
  if message then writeAt(target, 2, 7, message) end
  drawButton(target, "status", "DETAILS", left, 8, right, 8, colors.lightBlue)
  drawButton(target, "target", "SET DEST", farLeft, 8, farRight, 8, colors.green)
  drawButton(target, "waypoints", "WAYPOINTS", left, 9, right, 9, colors.lime)
  drawButton(target, "mode-nav", "NAV MODE", farLeft, 9, farRight, 9, colors.cyan)
  drawButton(target, "mode-hover", "HOVER", left, 10, right, 10, colors.cyan)
  drawButton(target, "mode-standby", "STANDBY", farLeft, 10, farRight, 10, colors.gray)
  drawButton(target, "schedules", "SCHEDULES", left, 11, right, 11, colors.green)
  drawButton(target, "automate", "ARM AUTO", farLeft, 11, farRight, 11, colors.cyan)
  drawButton(target, "clear", "CLEAR DEST", left, 12, right, 12, colors.orange)
  drawButton(target, "stop", "OUTPUTS OFF", farLeft, 12, farRight, 12, colors.red)
  drawButton(target, "config", "CONFIG", left, 13, right, 14, colors.blue)
  drawButton(target, "refresh", "REFRESH", farLeft, 13, farRight, 14, colors.cyan)
  drawButton(target, "update", "UPDATE", left, 15, right, 16, colors.purple)
  drawButton(target, "uninstall", "UNINSTALL", farLeft, 15, farRight, 16, colors.brown)
  drawButton(target, "exit", "EXIT", left, 17, farRight, 18, colors.gray)
  writeAt(target, 2, height, "Touch/click. Q exits. Aircraft must run navtool server.")
end

local function menu()
  local target, monitorName = screen()
  drawMenu(target)
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
    if action == "status" then local _, height = target.getSize(); showStatus(target); writeAt(target, 2, height, "Touch anywhere to return."); os.pullEvent(); drawMenu(target)
    elseif action == "refresh" then drawMenu(target)
    elseif action == "target" then color(target, colors.black, colors.white); target.clear(); target.setCursorPos(1, 1); local previous = term.redirect(target); setTarget(); term.redirect(previous); sleep(1); drawMenu(target)
    elseif action == "waypoints" then waypointManager(target)
    elseif action == "schedules" then scheduleManager(target)
    elseif action == "wp-add" then local previous = term.redirect(target); saveWaypoint(); term.redirect(previous); drawMenu(target)
    elseif action == "wp-goto" then local previous = term.redirect(target); waypointNamePrompt("goto-waypoint"); term.redirect(previous); drawMenu(target)
    elseif action == "wp-delete" then local previous = term.redirect(target); waypointNamePrompt("delete-waypoint"); term.redirect(previous); drawMenu(target)
    elseif action == "sch-add" then local previous = term.redirect(target); createSchedule(); term.redirect(previous); drawMenu(target)
    elseif action == "sch-run" then local previous = term.redirect(target); scheduleNamePrompt("run-schedule"); term.redirect(previous); drawMenu(target)
    elseif action == "sch-delete" then local previous = term.redirect(target); scheduleNamePrompt("delete-schedule"); term.redirect(previous); drawMenu(target)
    elseif action == "sch-stop" then local ok, e = request("stop-schedule"); drawMenu(target, ok and "Schedule stopped." or e)
    elseif action == "automate" then local previous = term.redirect(target); scheduleNamePrompt("run-schedule"); term.redirect(previous); drawMenu(target)
    elseif action == "back" then drawMenu(target)
    elseif action == "mode-nav" then drawMenu(target, setMode("navigate") or "Mode set to navigate.")
    elseif action == "mode-hover" then drawMenu(target, setMode("hover") or "Mode set to hover.")
    elseif action == "mode-standby" then drawMenu(target, setMode("standby") or "Mode set to standby.")
    elseif action == "clear" then local ok, e = request("clear-target"); drawMenu(target, ok and "Destination cleared." or e)
    elseif action == "stop" then local ok, e = request("outputs-off"); drawMenu(target, ok and "Aircraft outputs cleared." or e)
    elseif action == "config" then editConfig(); drawMenu(target)
    elseif action == "update" then target.clear(); writeAt(target, 2, 2, "Updating remote..."); shell.run(ROOT .. "/update.lua"); return
    elseif action == "uninstall" then target.clear(); writeAt(target, 2, 2, "Running uninstall..."); shell.run(ROOT .. "/uninstall.lua"); return
    elseif action == "exit" then return end
  end
end

if command == "status" then showStatus()
elseif command == "target" then setTarget()
elseif command == "waypoint" then saveWaypoint()
elseif command == "schedule" then createSchedule()
elseif command == "stop" then local ok, e = request("outputs-off"); if ok then print("Aircraft outputs cleared.") else printError(e) end
elseif command == "config" then editConfig()
else menu() end
