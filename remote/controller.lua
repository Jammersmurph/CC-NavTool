local VERSION = "0.4.0-dev"
local ROOT = "/navremote"
local CONFIG_PATH = ROOT .. "/config.lua"
local Storage = dofile(ROOT .. "/storage.lua")

local config = dofile(CONFIG_PATH)
config.profiles = type(config.profiles) == "table" and config.profiles or {}
config.activeProfile = config.activeProfile or next(config.profiles)
local hostCache = {}
local selected = 1
local message = ""

local icons = {
  { id = "dashboard", label = "Dashboard", glyph = { "#####", "#...#", "#.o.#", "#...#", "#####" } },
  { id = "targets", label = "Targets", glyph = { "..#..", ".###.", "##o##", ".###.", "..#.." } },
  { id = "routes", label = "Routes", glyph = { "#....", ".#...", "..#..", "...#.", "....#" } },
  { id = "schedules", label = "Schedules", glyph = { "#####", "#.#.#", "#####", "#.#.#", "#####" } },
  { id = "modes", label = "Modes", glyph = { "..#..", "..#..", ".###.", "#####", "#####" } },
  { id = "manual", label = "Manual", glyph = { "..#..", ".###.", "#####", ".#.#.", "#...#" } },
  { id = "profiles", label = "Aircraft", glyph = { "#...#", ".#.#.", "..#..", ".#.#.", "#...#" } },
  { id = "logs", label = "Logs", glyph = { "####.", "#...#", "####.", "#....", "#####" } },
  { id = "settings", label = "Settings", glyph = { ".#.#.", "#####", ".###.", "#####", ".#.#." } },
}

local function saveConfig()
  local file = fs.open(CONFIG_PATH, "w")
  file.write("return " .. textutils.serialize(config) .. "\n")
  file.close()
end

local function profile()
  return config.profiles[config.activeProfile]
end

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return true
    end
  end
  return false
end

local function request(command, extra)
  local connection = profile()
  if not connection then return nil, "No aircraft profile selected" end
  local channel = connection.channel or "cc-navtool"
  local host = connection.host or "navtool-aircraft"
  local cacheKey = channel .. "\0" .. host
  local hostId = hostCache[cacheKey] or rednet.lookup(channel, host)
  if not hostId then return nil, "Aircraft offline" end
  hostCache[cacheKey] = hostId
  local payload = extra or {}
  payload.command = command
  payload.key = connection.sharedKey or ""
  rednet.send(hostId, payload, channel)
  local sender, response = rednet.receive(channel, tonumber(connection.timeout) or 3)
  if sender ~= hostId or type(response) ~= "table" then hostCache[cacheKey] = nil; return nil, "No response" end
  if not response.ok then return nil, response.error or "Rejected" end
  return response
end

local function localData()
  return Storage.load(config.activeProfile or "default")
end

local function saveData(data)
  Storage.save(config.activeProfile or "default", data)
end

local function clear(bg)
  term.setBackgroundColor(bg or colors.green)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function writeAt(x, y, text, fg, bg)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.setCursorPos(x, y)
  term.write(tostring(text))
end

local function fill(x, y, w, h, bg)
  term.setBackgroundColor(bg)
  for row = y, y + h - 1 do
    term.setCursorPos(x, row)
    term.write(string.rep(" ", w))
  end
end

local function header(title, status)
  local w = term.getSize()
  fill(1, 1, w, 1, colors.gray)
  writeAt(2, 1, "NavRemote", colors.white, colors.gray)
  writeAt(13, 1, title or "", colors.lightGray, colors.gray)
  local right = status or (config.activeProfile or "NO PROFILE")
  writeAt(math.max(1, w - #right - 1), 1, right, colors.lime, colors.gray)
end

local function footer(text)
  local w, h = term.getSize()
  fill(1, h, w, 1, colors.gray)
  writeAt(2, h, text or "Arrows: move  Enter: open  Q: quit", colors.white, colors.gray)
end

local function drawGlyph(x, y, glyph, active)
  local fg = active and colors.black or colors.white
  local bg = active and colors.lightGray or colors.green
  fill(x - 1, y - 1, 7, 7, bg)
  for row, line in ipairs(glyph) do
    for col = 1, #line do
      local ch = line:sub(col, col)
      writeAt(x + col - 1, y + row - 1, ch == "#" and " " or (ch == "o" and "o" or " "), fg, ch == "#" and fg or bg)
    end
  end
end

local function desktop()
  clear(colors.green)
  header("Aircraft controller", "[ " .. tostring(config.activeProfile or "none") .. " ]")
  local categories = { "Recent", "NavRemote", "Aircraft", "System", "Help" }
  fill(1, 2, 12, 16, colors.gray)
  for i, name in ipairs(categories) do
    local bg = i == 2 and colors.lightGray or colors.gray
    local fg = i == 2 and colors.black or colors.white
    fill(1, i + 2, 12, 1, bg)
    writeAt(2, i + 2, name, fg, bg)
  end
  local startX, startY = 16, 4
  for i, icon in ipairs(icons) do
    local col = (i - 1) % 3
    local row = math.floor((i - 1) / 3)
    local x = startX + col * 12
    local y = startY + row * 5
    drawGlyph(x, y, icon.glyph, i == selected)
    writeAt(x - 1, y + 6, icon.label:sub(1, 9), i == selected and colors.black or colors.white, i == selected and colors.lightGray or colors.green)
  end
  if message ~= "" then writeAt(14, 18, message:sub(1, 36), colors.yellow, colors.green) end
  footer("Arrows: move  Enter: open  R: refresh  Q: quit")
end

local function prompt(label, default)
  clear(colors.black)
  header(label)
  writeAt(2, 4, label .. (default and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local value = read()
  if value == "" then return default end
  return value
end

local function refresh(data)
  local response, err = request("live-status")
  if response then
    data.lastStatus = response.data
    Storage.log(data, "INFO", "Telemetry refreshed")
    saveData(data)
    return response.data
  end
  Storage.log(data, "WARN", err)
  saveData(data)
  return data.lastStatus, err
end

local function listPage(title, map, actionHelp)
  clear(colors.black)
  header(title)
  local names = Storage.names(map)
  if #names == 0 then writeAt(3, 4, "No saved entries", colors.lightGray) end
  for i, name in ipairs(names) do
    if i > 12 then break end
    writeAt(3, i + 3, tostring(i) .. ". " .. name, colors.white)
  end
  footer(actionHelp or "A: add  D: delete  Esc: back")
  return names
end

local function targetsPage(data)
  while true do
    local names = listPage("Targets", data.targets, "A:add  G:go  D:delete  Esc:back")
    local _, key = os.pullEvent("key")
    if key == keys.escape then return end
    if key == keys.a then
      local name = prompt("Target name")
      local x = tonumber(prompt("X")); local y = tonumber(prompt("Y")); local z = tonumber(prompt("Z"))
      if name and x and y and z then data.targets[name] = { name = name, x = x, y = y, z = z }; saveData(data) end
    elseif key == keys.g then
      local name = prompt("Target to activate")
      local target = data.targets[name]
      if target then
        data.target = target; saveData(data)
        local ok, err = request("set-target", { target = target })
        if ok then request("set-mode", { mode = "navigate" }); message = "Navigating to " .. name else message = err end
      end
      return
    elseif key == keys.d then
      local name = prompt("Target to delete")
      if name then data.targets[name] = nil; saveData(data) end
    end
  end
end

local function modesPage()
  local modes = { "standby", "navigate", "hover", "return-home" }
  clear(colors.black); header("Flight modes")
  for i, mode in ipairs(modes) do writeAt(4, i + 3, tostring(i) .. ". " .. mode) end
  footer("1-4: activate  Esc: back")
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.escape then return end
    local index = key - keys.one + 1
    if modes[index] then
      local ok, err = request("set-mode", { mode = modes[index] })
      message = ok and ("Mode: " .. modes[index]) or err
      return
    end
  end
end

local function manualPage()
  clear(colors.black); header("Manual control")
  writeAt(3, 4, "W/S  forward/reverse")
  writeAt(3, 5, "A/D  left/right")
  writeAt(3, 6, "Space/Shift  up/down")
  writeAt(3, 8, "Each key sends a bounded pulse.", colors.yellow)
  footer("Movement keys  X: all outputs off  Esc: back")
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.escape then return end
    local control = key == keys.w and "forward" or key == keys.s and "reverse" or key == keys.a and "left" or key == keys.d and "right" or key == keys.space and "up" or key == keys.leftShift and "down"
    if control then request("manual-control", { control = control, strength = 2, duration = 0.3 }) end
    if key == keys.x then request("outputs-off"); message = "Outputs cleared"; return end
  end
end

local function dashboard(data)
  local status, err = refresh(data)
  clear(colors.black); header("Dashboard", err and "[ OFFLINE ]" or "[ SABLE ONLINE ]")
  status = status or {}
  local p, v = status.position or {}, status.velocity or {}
  writeAt(3, 3, "Aircraft", colors.cyan); writeAt(14, 3, config.activeProfile or "none")
  writeAt(3, 5, "Mode"); writeAt(14, 5, status.mode or "unknown", colors.lime)
  writeAt(3, 6, "Target"); writeAt(14, 6, status.target and (status.target.name or "coordinates") or "none", colors.yellow)
  writeAt(3, 8, "Position", colors.cyan)
  writeAt(3, 9, string.format("X %.1f", tonumber(p.x) or 0)); writeAt(17, 9, string.format("Y %.1f", tonumber(p.y) or 0)); writeAt(31, 9, string.format("Z %.1f", tonumber(p.z) or 0))
  writeAt(3, 11, "Velocity", colors.cyan)
  writeAt(3, 12, string.format("X %.2f", tonumber(v.x) or 0)); writeAt(17, 12, string.format("Y %.2f", tonumber(v.y) or 0)); writeAt(31, 12, string.format("Z %.2f", tonumber(v.z) or 0))
  writeAt(3, 14, "Local library", colors.cyan)
  writeAt(3, 15, "Targets " .. #Storage.names(data.targets)); writeAt(18, 15, "Routes " .. #Storage.names(data.routes)); writeAt(32, 15, "Schedules " .. #Storage.names(data.schedules))
  footer("R: refresh  Esc: back")
  while true do local _, key = os.pullEvent("key"); if key == keys.escape then return elseif key == keys.r then return dashboard(data) end end
end

local function profilesPage()
  clear(colors.black); header("Linked aircraft")
  local names = Storage.names(config.profiles)
  for i, name in ipairs(names) do
    local marker = name == config.activeProfile and ">" or " "
    writeAt(3, i + 3, marker .. " " .. tostring(i) .. ". " .. name .. "  " .. tostring(config.profiles[name].host or ""))
  end
  footer("Number: select  A:add  Esc:back")
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.escape then return end
    if key == keys.a then
      local name = prompt("Profile name")
      if name then
        config.profiles[name] = { channel = prompt("Channel", "cc-navtool"), host = prompt("Host", "navtool-aircraft"), sharedKey = prompt("Shared key", ""), timeout = 3 }
        config.activeProfile = name; saveConfig(); return
      end
    end
    local index = key - keys.one + 1
    if names[index] then config.activeProfile = names[index]; saveConfig(); message = "Selected " .. names[index]; return end
  end
end

local function logsPage(data)
  clear(colors.black); header("Local event log")
  local start = math.max(1, #data.eventLog - 12)
  local y = 3
  for i = start, #data.eventLog do
    local item = data.eventLog[i]
    local color = item.level == "WARN" and colors.yellow or item.level == "ERROR" and colors.red or colors.lime
    writeAt(2, y, "[" .. tostring(item.level) .. "] " .. tostring(item.message):sub(1, 38), color)
    y = y + 1
  end
  footer("Esc: back")
  repeat local _, key = os.pullEvent("key") until key == keys.escape
end

local function placeholder(title)
  clear(colors.black); header(title)
  writeAt(3, 5, "Local " .. title:lower() .. " editor is reserved", colors.lightGray)
  writeAt(3, 6, "for the next controller pass.", colors.lightGray)
  footer("Esc: back")
  repeat local _, key = os.pullEvent("key") until key == keys.escape
end

if not term.isColor() then printError("NavRemote requires an Advanced Computer or color monitor."); return end
if not openModem() then printError("NavRemote requires a modem."); return end
if not config.activeProfile then printError("No aircraft profile configured."); return end

while true do
  desktop()
  local _, key = os.pullEvent("key")
  if key == keys.q then clear(colors.black); return end
  if key == keys.left and selected > 1 then selected = selected - 1
  elseif key == keys.right and selected < #icons then selected = selected + 1
  elseif key == keys.up and selected > 3 then selected = selected - 3
  elseif key == keys.down and selected + 3 <= #icons then selected = selected + 3
  elseif key == keys.r then local data = localData(); refresh(data); message = "Telemetry refreshed"
  elseif key == keys.enter then
    local data = localData()
    local id = icons[selected].id
    if id == "dashboard" then dashboard(data)
    elseif id == "targets" then targetsPage(data)
    elseif id == "modes" then modesPage()
    elseif id == "manual" then manualPage()
    elseif id == "profiles" then profilesPage()
    elseif id == "logs" then logsPage(data)
    elseif id == "routes" then placeholder("Routes")
    elseif id == "schedules" then placeholder("Schedules")
    else placeholder("Settings") end
  end
end
