local VERSION = "0.3.0-dev"
local ROOT = "/navremote"
local CONFIG_PATH = ROOT .. "/config.lua"
local args = { ... }
local buttons = {}
local config
local hostCache = {}

local function loadConfig()
  local ok, config = pcall(dofile, CONFIG_PATH)
  if not ok or type(config) ~= "table" then return nil, tostring(config) end
  if type(config.profiles) ~= "table" then
    config.profiles = {
      default = {
        channel = config.channel or config.protocol or "cc-navtool",
        host = config.host or "navtool-aircraft",
        sharedKey = config.sharedKey or "",
        timeout = config.timeout or 3,
      }
    }
    config.activeProfile = "default"
    config._migrated = true
  end
  if not config.activeProfile or not config.profiles[config.activeProfile] then
    for name in pairs(config.profiles) do config.activeProfile = name; break end
  end
  for _, profile in pairs(config.profiles or {}) do
    if profile.channel == nil and profile.protocol ~= nil then
      profile.channel = profile.protocol
      profile.protocol = nil
      config._migrated = true
    end
  end
  return config
end

local function saveConfig(config)
  config._migrated = nil
  local file = fs.open(CONFIG_PATH, "w")
  file.write("return " .. textutils.serialize(config) .. "\n")
  file.close()
end

local function profileNames()
  local names = {}
  for name in pairs(config.profiles or {}) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function activeProfile()
  return (config.profiles and config.profiles[config.activeProfile]) or config
end

local function setActiveProfile(name)
  if config.profiles and config.profiles[name] then
    config.activeProfile = name
    saveConfig(config)
    return true
  end
  return false
end

local function discoverHosts(channel)
  local ok, result = pcall(rednet.lookup, channel or "cc-navtool")
  local hosts = {}
  if not ok or type(result) ~= "table" then return hosts end
  for key, value in pairs(result) do
    if type(key) == "string" and type(value) == "number" then
      hosts[#hosts + 1] = { name = key, id = value }
    elseif type(key) == "number" and type(value) == "string" then
      hosts[#hosts + 1] = { name = value, id = key }
    end
  end
  table.sort(hosts, function(a, b) return a.name < b.name end)
  return hosts
end

local function chooseDiscoveredHost(channel)
  local hosts = discoverHosts(channel)
  if #hosts == 0 then
    print("No navtool servers found on channel " .. tostring(channel) .. ".")
    return nil
  end
  print("Discovered navtool servers:")
  for index, host in ipairs(hosts) do
    print("  " .. index .. ". " .. host.name .. " (ID " .. tostring(host.id) .. ")")
  end
  write("Select number, hostname, or blank for manual: ")
  local choice = read()
  if choice == "" then return nil end
  local index = tonumber(choice)
  if index and hosts[index] then return hosts[index].name end
  return choice
end

local function printProfiles()
  print("Remote Profiles")
  for _, name in ipairs(profileNames()) do
    local profile = config.profiles[name]
    local marker = name == config.activeProfile and "* " or "  "
    print(marker .. name .. " -> " .. tostring(profile.host or "navtool-aircraft"))
  end
end

local function addProfile()
  term.clear()
  term.setCursorPos(1, 1)
  print("Add Remote Profile")
  write("Profile name: ")
  local name = read()
  if name == "" then printError("Profile name is required."); sleep(1.5); return end
  write("Channel [cc-navtool]: ")
  local channel = read()
  channel = channel ~= "" and channel or "cc-navtool"
  print("Scanning for hosted aircraft...")
  local host = chooseDiscoveredHost(channel)
  if not host then
    write("Host [navtool-aircraft]: ")
    host = read()
  end
  write("Shared key: ")
  local key = read("*")
  write("Timeout seconds [3]: ")
  local timeout = tonumber(read())
  config.profiles[name] = {
    host = host ~= "" and host or "navtool-aircraft",
    channel = channel,
    sharedKey = key,
    timeout = timeout or 3,
  }
  config.activeProfile = name
  saveConfig(config)
  print("Profile saved and selected.")
  sleep(1)
end

local function selectProfilePrompt()
  term.clear()
  term.setCursorPos(1, 1)
  printProfiles()
  write("Select profile: ")
  local name = read()
  if setActiveProfile(name) then print("Selected " .. name) else printError("Profile not found") end
  sleep(1)
end

local function deleteProfilePrompt()
  term.clear()
  term.setCursorPos(1, 1)
  printProfiles()
  write("Delete profile: ")
  local name = read()
  if name == "" then return end
  if not config.profiles[name] then printError("Profile not found"); sleep(1); return end
  local count = #profileNames()
  if count <= 1 then printError("Cannot delete the only profile."); sleep(1.5); return end
  config.profiles[name] = nil
  if config.activeProfile == name then config.activeProfile = profileNames()[1] end
  saveConfig(config)
  print("Profile deleted.")
  sleep(1)
end

local function openModem()
  local fallback
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      local ok, wireless = pcall(modem.isWireless)
      if ok and wireless then
        if not rednet.isOpen(name) then rednet.open(name) end
        return name
      end
      fallback = fallback or name
    end
  end
  if fallback then
    if not rednet.isOpen(fallback) then rednet.open(fallback) end
    return fallback
  end
end

local command = (args[1] or "menu"):lower()
if command == "uninstall" then shell.run(ROOT .. "/uninstall.lua"); return end
if command == "update" then shell.run(ROOT .. "/update.lua"); return end
if command == "version" then print(VERSION); return end

local err
config, err = loadConfig()
if not config then printError("Config error: " .. err); return end
if config._migrated then saveConfig(config) end
if command ~= "config" and command ~= "profile" and not openModem() then printError("No wired or wireless modem found."); return end

local function request(command, extra)
  local connection = activeProfile()
  local channel = connection.channel or connection.protocol or "cc-navtool"
  local host = connection.host or "navtool-aircraft"
  local cacheKey = channel .. "\0" .. host
  local hostId = hostCache[cacheKey]
  if not hostId then
    hostId = rednet.lookup(channel, host)
    if hostId then hostCache[cacheKey] = hostId end
  end
  if not hostId then return nil, "Aircraft host not found: " .. host .. " on " .. channel end
  local payload = extra or {}
  payload.command = command
  payload.key = connection.sharedKey or ""
  rednet.send(hostId, payload, channel)
  local timeout = math.max(1, tonumber(connection.timeout) or 3)
  local deadline = os.clock() + timeout
  repeat
    local remaining = math.max(0.05, deadline - os.clock())
    local sender, response = rednet.receive(channel, remaining)
    if sender == hostId and type(response) == "table" then
      if not response.ok then return nil, response.error or "Command rejected" end
      return response
    end
  until os.clock() >= deadline
  hostCache[cacheKey] = nil
  return nil, "No response from aircraft"
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

local function statusVectorText(data, key)
  if not data or not data.version then return "not refreshed" end
  return vectorText(data[key])
end

local function targetText(target)
  if not target then return "none" end
  local name = target.name and (target.name .. " ") or ""
  return string.format("%s%.1f %.1f %.1f", name, tonumber(target.x) or 0, tonumber(target.y) or 0, tonumber(target.z) or 0)
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

local function showStatus(target)
  local response, requestErr = request("status")
  if not response then printError(requestErr); return end
  local data = response.data or {}
  local connection = activeProfile()
  target = target or term.current()
  color(target, colors.black, colors.white)
  target.clear()
  writeAt(target, 2, 1, "CC-NavTool Remote " .. VERSION)
  writeAt(target, 2, 3, "Profile: " .. tostring(config.activeProfile))
  writeAt(target, 2, 4, "Host: " .. tostring(connection.host))
  writeAt(target, 2, 5, "Telemetry: " .. (data.telemetry and "ONLINE" or "OFFLINE"))
  writeAt(target, 2, 6, "Aircraft version: " .. tostring(data.version))
  if data.peripheral then writeAt(target, 2, 7, "Peripheral: " .. tostring(data.peripheral)) end
  writeAt(target, 2, 8, "Target: " .. compact(data.target))
  writeAt(target, 2, 9, "Position: " .. vectorText(data.position))
  writeAt(target, 2, 10, "Velocity: " .. vectorText(data.velocity))
  writeAt(target, 2, 11, "Heading: " .. vectorText(data.heading) .. " via " .. tostring(data.headingSource or "unknown"))
  writeAt(target, 2, 12, "Mode: " .. tostring(data.mode or "standby"))
  writeAt(target, 2, 13, "Waypoints: " .. tostring(#(data.waypointNames or {})))
  writeAt(target, 2, 14, "Schedules: " .. tostring(#(data.scheduleNames or {})))
end

local function pingAircraft()
  local response, err = request("ping")
  if not response then printError(err); return end
  print("Aircraft replied.")
  if response.id then print("Computer ID: " .. tostring(response.id)) end
end

local function diagnoseRednet()
  local connection = activeProfile()
  local channel = connection.channel or connection.protocol or "cc-navtool"
  local host = connection.host or "navtool-aircraft"
  print("Profile: " .. tostring(config.activeProfile))
  print("Host: " .. tostring(host))
  print("Channel: " .. tostring(channel))
  local hostId = rednet.lookup(channel, host)
  print("Lookup ID: " .. tostring(hostId))
  if not hostId then return end
  rednet.send(hostId, { command = "ping", key = connection.sharedKey or "" }, channel)
  print("Sent ping. Listening for 5 seconds...")
  local deadline = os.clock() + 5
  repeat
    local remaining = deadline - os.clock()
    if remaining <= 0 then break end
    local sender, message, protocol = rednet.receive(nil, remaining)
    if sender then
      print("From " .. tostring(sender) .. " protocol " .. tostring(protocol) .. ":")
      print(textutils.serialize(message))
    end
  until os.clock() >= deadline
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

local function profileManager(target)
  local width, height = target.getSize()
  color(target, colors.black, colors.white)
  target.clear()
  drawHeader(target, "Remote Host Profiles")
  local y = 3
  for _, name in ipairs(profileNames()) do
    if y >= height - 5 then break end
    local profile = config.profiles[name]
    local marker = name == config.activeProfile and "* " or "  "
    line(target, 2, y, marker .. name .. ": ", tostring(profile.host or "navtool-aircraft"))
    y = y + 1
  end
  drawButton(target, "profile-add", "ADD", 2, height - 4, math.floor(width / 3), height - 3, colors.green)
  drawButton(target, "profile-select", "SELECT", math.floor(width / 3) + 2, height - 4, math.floor(width * 2 / 3), height - 3, colors.cyan)
  drawButton(target, "profile-delete", "DELETE", math.floor(width * 2 / 3) + 2, height - 4, width - 2, height - 3, colors.red)
  drawButton(target, "back", "BACK", 2, height - 2, width - 2, height - 1, colors.gray)
end

local function setMode(mode)
  local response, requestErr = request("set-mode", { mode = mode })
  if not response then return requestErr end
end

local function editConfig()
  local connection = activeProfile()
  term.clear()
  term.setCursorPos(1, 1)
  print("Remote Profile Configuration")
  print("Profile: " .. tostring(config.activeProfile))
  write("Host [" .. tostring(connection.host or "navtool-aircraft") .. "]: ")
  local host = read()
  write("Channel [" .. tostring(connection.channel or connection.protocol or "cc-navtool") .. "]: ")
  local channel = read()
  write("Shared key [hidden, blank keeps]: ")
  local key = read("*")
  write("Timeout seconds [" .. tostring(connection.timeout or 3) .. "]: ")
  local timeout = tonumber(read())
  if host ~= "" then connection.host = host end
  if channel ~= "" then connection.channel = channel; connection.protocol = nil end
  if key ~= "" then connection.sharedKey = key end
  if timeout then connection.timeout = timeout end
  saveConfig(config)
  print("Config saved.")
  sleep(1)
end

local function manualPulse(control, strength, duration)
  local response, err = request("manual-control", { control = control, strength = strength or 3, duration = duration or 0.35 })
  if err == "unsupported command" then return nil, "Update/restart navtool server." end
  return response, err
end

local function manualRelease(control)
  local response, err = request("manual-control", { control = control, strength = 0, duration = 0 })
  if err == "unsupported command" then return nil, "Update/restart navtool server." end
  return response, err
end

local function manualKey(key)
  if key == keys.w or key == keys.up then return "forward"
  elseif key == keys.s or key == keys.down then return "reverse"
  elseif key == keys.a or key == keys.left then return "left"
  elseif key == keys.d or key == keys.right then return "right"
  elseif key == keys.space then return "up"
  elseif key == keys.leftShift then return "down" end
end

local function drawManualControl(target, message)
  buttons = {}
  local width, height = target.getSize()
  color(target, colors.black, colors.white)
  target.clear()
  drawHeader(target, "Manual Control")
  writeAt(target, 2, 3, "Each press sends a short bounded pulse, then releases.")
  writeAt(target, 2, 4, "Keys: W/A/S/D, arrows, Space up, Shift down.")
  if message then writeAt(target, 2, 5, message) end
  local center = math.floor(width / 2)
  local buttonWidth = math.max(9, math.floor(width / 4))
  drawButton(target, "manual-forward", "FORWARD", center - math.floor(buttonWidth / 2), 7, center + math.floor(buttonWidth / 2), 7, colors.green)
  drawButton(target, "manual-left", "LEFT", 2, 9, 2 + buttonWidth, 9, colors.cyan)
  drawButton(target, "manual-stop", "STOP", center - math.floor(buttonWidth / 2), 9, center + math.floor(buttonWidth / 2), 9, colors.red)
  drawButton(target, "manual-right", "RIGHT", width - buttonWidth - 2, 9, width - 2, 9, colors.cyan)
  drawButton(target, "manual-reverse", "REVERSE", center - math.floor(buttonWidth / 2), 11, center + math.floor(buttonWidth / 2), 11, colors.orange)
  drawButton(target, "manual-up", "UP", 2, 13, center - 2, 13, colors.lime)
  drawButton(target, "manual-down", "DOWN", center + 1, 13, width - 2, 13, colors.brown)
  drawButton(target, "back", "BACK", 2, height - 2, width - 2, height - 1, colors.gray)
  writeAt(target, 2, height, "Manual control forces standby and stops active schedules.")
end

local function drawMenu(target, message, menu, data, requestErr)
  buttons = {}
  local connection = activeProfile()
  data = data or {}
  local width, height = target.getSize()
  color(target, colors.black, colors.white)
  target.clear()
  drawHeader(target, "CC-NavTool Remote " .. VERSION)
  line(target, 2, 3, "Profile: ", config.activeProfile)
  line(target, 2, 4, "Aircraft: ", connection.host)
  line(target, 2, 5, "Telemetry: ", data.telemetry and "ONLINE" or "OFFLINE")
  line(target, 2, 6, "Target: ", targetText(data.target))
  line(target, 2, 7, "Mode: ", data.mode or "standby")
  line(target, math.max(28, math.floor(width / 2)), 3, "Version: ", data.version)
  line(target, math.max(28, math.floor(width / 2)), 4, "Position: ", statusVectorText(data, "position"))
  line(target, math.max(28, math.floor(width / 2)), 5, "Velocity: ", statusVectorText(data, "velocity"))
  line(target, math.max(28, math.floor(width / 2)), 6, "Heading: ", statusVectorText(data, "heading"))
  line(target, math.max(28, math.floor(width / 2)), 7, "Waypoints: ", #(data.waypointNames or {}))
  if requestErr then writeAt(target, 2, 8, "Error: " .. requestErr) end
  if message then writeAt(target, 2, 8, message) end
  drawButtonRow(target, {
    { "status", "DETAILS", colors.lightBlue },
    { "menu-nav", menu == "nav" and "NAV ^" or "NAV", colors.cyan },
    { "menu-library", menu == "library" and "LIBRARY ^" or "LIBRARY", colors.green },
    { "menu-system", menu == "system" and "SYSTEM ^" or "SYSTEM", colors.blue },
  }, 9, 2, width - 2)
  if menu == "nav" then
    drawButtonRow(target, {
      { "target", "SET DEST", colors.green },
      { "manual", "MANUAL", colors.lime },
      { "clear", "CLEAR DEST", colors.orange },
    }, 11, 2, width - 2)
    drawButtonRow(target, {
      { "automate", "ARM AUTO", colors.cyan },
      { "mode-nav", "NAV MODE", colors.cyan },
      { "mode-standby", "STANDBY", colors.gray },
      { "stop", "OUTPUTS OFF", colors.red },
    }, 12, 2, width - 2)
  elseif menu == "library" then
    drawButtonRow(target, {
      { "waypoints", "WAYPOINTS", colors.lime },
      { "schedules", "SCHEDULES", colors.green },
      { "profiles", "PROFILES", colors.blue },
    }, 11, 2, width - 2)
  elseif menu == "system" then
    drawButtonRow(target, {
      { "config", "CONFIG", colors.blue },
      { "refresh", "REFRESH", colors.cyan },
    }, 11, 2, width - 2)
    drawButtonRow(target, {
      { "update", "UPDATE", colors.purple },
      { "uninstall", "UNINSTALL", colors.brown },
    }, 12, 2, width - 2)
  else
    writeAt(target, 2, 11, "Choose Nav, Library, or System for actions.")
  end
  drawButton(target, "exit", "EXIT", 2, height - 2, width - 2, height - 1, colors.gray)
  writeAt(target, 2, height, "Touch/click. Q exits. Aircraft must run navtool server.")
end

local function menu()
  local target, monitorName = screen()
  local activeMenu
  local heldControls = {}
  local manualTimer
  local autoRefreshTimer
  local profile = activeProfile()
  local autoRefreshEnabled = config.autoRefresh ~= false and profile.autoRefresh ~= false
  local pendingLive
  local statusData = {}
  local statusErr
  local function refreshStatus(silent)
    local response, requestErr = request("live-status")
    statusData = response and response.data or statusData or {}
    if response then statusErr = nil elseif not silent then statusErr = requestErr end
  end
  local function sendLiveStatus(silent)
    if pendingLive and pendingLive.deadline > os.clock() then return end
    if pendingLive and pendingLive.cacheKey then hostCache[pendingLive.cacheKey] = nil end
    pendingLive = nil
    local connection = activeProfile()
    local channel = connection.channel or connection.protocol or "cc-navtool"
    local host = connection.host or "navtool-aircraft"
    local cacheKey = channel .. "\0" .. host
    local hostId = hostCache[cacheKey]
    if not hostId then
      hostId = rednet.lookup(channel, host)
      if hostId then hostCache[cacheKey] = hostId end
    end
    if not hostId then
      if not silent then statusErr = "Aircraft host not found: " .. host .. " on " .. channel end
      pendingLive = { deadline = os.clock() + 5.0 }
      return
    end
    local payload = { command = "live-status", key = connection.sharedKey or "" }
    rednet.send(hostId, payload, channel)
    pendingLive = { hostId = hostId, channel = channel, cacheKey = cacheKey, deadline = os.clock() + math.max(1, tonumber(connection.timeout) or 3) }
  end
  local function hasHeldManualControls()
    for _, held in pairs(heldControls) do if held then return true end end
    return false
  end
  local function scheduleManualRenewal()
    if hasHeldManualControls() and not manualTimer then manualTimer = os.startTimer(0.15) end
  end
  local function scheduleAutoRefresh(delay)
    if autoRefreshEnabled then autoRefreshTimer = os.startTimer(delay or 1.0) end
  end
  drawMenu(target, "Press REFRESH for live aircraft status.", activeMenu, statusData, statusErr)
  scheduleAutoRefresh(0.1)
  while true do
    local event, side, x, y = os.pullEvent()
    if event == "key" and side == keys.q then return end
    if event == "rednet_message" and pendingLive then
      local sender, response, channel = side, x, y
      if sender == pendingLive.hostId and channel == pendingLive.channel and type(response) == "table" then
        pendingLive = nil
        if response.ok then
          statusData = response.data or statusData or {}
          statusErr = nil
          if buttons["menu-nav"] then drawMenu(target, nil, activeMenu, statusData, statusErr) end
        else
          statusErr = response.error or "Command rejected"
        end
      end
    end
    if event == "mouse_click" then
      -- mouse_click returns button, x, y. Keep the terminal coordinates.
    elseif event == "monitor_touch" and side ~= monitorName then
      x, y = nil, nil
    elseif event ~= "monitor_touch" then
      x, y = nil, nil
    end
    if buttons["manual-forward"] and event == "timer" and side == manualTimer then
      manualTimer = nil
      for control, held in pairs(heldControls) do
        if held then manualPulse(control, 3, 0.35) end
      end
      scheduleManualRenewal()
    elseif event == "timer" and side == autoRefreshTimer then
      autoRefreshTimer = nil
      if buttons["menu-nav"] then
        sendLiveStatus(true)
      end
      scheduleAutoRefresh()
    elseif buttons["manual-forward"] and (event == "key" or event == "key_up") then
      local control = manualKey(side)
      if control then
        if event == "key" then
          heldControls[control] = true
          manualPulse(control, 3, 0.35)
          scheduleManualRenewal()
        else
          heldControls[control] = nil
          manualRelease(control)
        end
      end
    end
    local action = x and hitButton(x, y)
    if action == "menu-nav" then activeMenu = activeMenu == "nav" and nil or "nav"; drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "menu-library" then activeMenu = activeMenu == "library" and nil or "library"; drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "menu-system" then activeMenu = activeMenu == "system" and nil or "system"; drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "status" then local _, height = target.getSize(); showStatus(target); writeAt(target, 2, height, "Touch anywhere to return."); os.pullEvent(); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "refresh" then refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "target" then color(target, colors.black, colors.white); target.clear(); target.setCursorPos(1, 1); local previous = term.redirect(target); setTarget(); term.redirect(previous); sleep(1); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "manual" then drawManualControl(target)
    elseif action == "manual-forward" then local ok, e = manualPulse("forward"); drawManualControl(target, ok and "Forward pulse sent." or e)
    elseif action == "manual-reverse" then local ok, e = manualPulse("reverse"); drawManualControl(target, ok and "Reverse pulse sent." or e)
    elseif action == "manual-left" then local ok, e = manualPulse("left"); drawManualControl(target, ok and "Left pulse sent." or e)
    elseif action == "manual-right" then local ok, e = manualPulse("right"); drawManualControl(target, ok and "Right pulse sent." or e)
    elseif action == "manual-up" then local ok, e = manualPulse("up"); drawManualControl(target, ok and "Up pulse sent." or e)
    elseif action == "manual-down" then local ok, e = manualPulse("down"); drawManualControl(target, ok and "Down pulse sent." or e)
    elseif action == "manual-stop" then heldControls = {}; manualTimer = nil; local ok, e = request("outputs-off"); if ok then statusData.mode = "standby" end; drawManualControl(target, ok and "Outputs cleared." or e)
    elseif action == "waypoints" then waypointManager(target)
    elseif action == "schedules" then scheduleManager(target)
    elseif action == "profiles" then profileManager(target)
    elseif action == "wp-add" then local previous = term.redirect(target); saveWaypoint(); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "wp-goto" then local previous = term.redirect(target); waypointNamePrompt("goto-waypoint"); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "wp-delete" then local previous = term.redirect(target); waypointNamePrompt("delete-waypoint"); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "sch-add" then local previous = term.redirect(target); createSchedule(); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "sch-run" then local previous = term.redirect(target); scheduleNamePrompt("run-schedule"); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "sch-delete" then local previous = term.redirect(target); scheduleNamePrompt("delete-schedule"); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "sch-stop" then local ok, e = request("stop-schedule"); if ok then refreshStatus() end; drawMenu(target, ok and "Schedule stopped." or e, activeMenu, statusData, statusErr)
    elseif action == "automate" then local previous = term.redirect(target); scheduleNamePrompt("run-schedule"); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "profile-add" then local previous = term.redirect(target); addProfile(); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "profile-select" then local previous = term.redirect(target); selectProfilePrompt(); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "profile-delete" then local previous = term.redirect(target); deleteProfilePrompt(); term.redirect(previous); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "back" then heldControls = {}; manualTimer = nil; drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "mode-nav" then local err = setMode("navigate"); if not err then statusData.mode = "navigate" end; drawMenu(target, err or "Mode set to navigate.", activeMenu, statusData, statusErr)
    elseif action == "mode-hover" then local err = setMode("hover"); if not err then statusData.mode = "hover" end; drawMenu(target, err or "Mode set to hover.", activeMenu, statusData, statusErr)
    elseif action == "mode-standby" then local err = setMode("standby"); if not err then statusData.mode = "standby" end; drawMenu(target, err or "Mode set to standby.", activeMenu, statusData, statusErr)
    elseif action == "clear" then local ok, e = request("clear-target"); if ok then statusData.target = nil end; drawMenu(target, ok and "Destination cleared." or e, activeMenu, statusData, statusErr)
    elseif action == "stop" then local ok, e = request("outputs-off"); if ok then statusData.mode = "standby" end; drawMenu(target, ok and "Aircraft outputs cleared." or e, activeMenu, statusData, statusErr)
    elseif action == "config" then editConfig(); refreshStatus(); drawMenu(target, nil, activeMenu, statusData, statusErr)
    elseif action == "update" then target.clear(); writeAt(target, 2, 2, "Updating remote..."); shell.run(ROOT .. "/update.lua"); return
    elseif action == "uninstall" then target.clear(); writeAt(target, 2, 2, "Running uninstall..."); shell.run(ROOT .. "/uninstall.lua"); return
    elseif action == "exit" then return end
  end
end

if command == "status" then showStatus()
elseif command == "ping" then pingAircraft()
elseif command == "diagnose-rednet" then diagnoseRednet()
elseif command == "target" then setTarget()
elseif command == "waypoint" then saveWaypoint()
elseif command == "schedule" then createSchedule()
elseif command == "stop" then local ok, e = request("outputs-off"); if ok then print("Aircraft outputs cleared.") else printError(e) end
elseif command == "config" then editConfig()
elseif command == "profile" then printProfiles()
else menu() end
