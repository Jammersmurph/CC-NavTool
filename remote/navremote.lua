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

local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      return name
    end
  end
end

local config, err = loadConfig()
if not config then printError("Config error: " .. err); return end
if not openModem() then printError("No wired or wireless modem found."); return end

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

local function compact(value)
  local text = textutils.serialize(value)
  if #text > 38 then return text:sub(1, 35) .. "..." end
  return text
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
  writeAt(target, 2, 1, "CC-NavTool Remote " .. VERSION)
  writeAt(target, 2, 3, "Aircraft: " .. tostring(config.host))
  writeAt(target, 2, 4, "Telemetry: " .. (data.telemetry and "ONLINE" or "OFFLINE"))
  writeAt(target, 2, 5, "Target: " .. compact(data.target))
  if requestErr then writeAt(target, 2, 7, "Error: " .. requestErr) end
  if message then writeAt(target, 2, 7, message) end
  drawButton(target, "status", "STATUS", left, 8, right, 10, colors.blue)
  drawButton(target, "target", "SET DEST", farLeft, 8, farRight, 10, colors.green)
  drawButton(target, "clear", "CLEAR DEST", left, 12, right, 14, colors.orange)
  drawButton(target, "stop", "OUTPUTS OFF", farLeft, 12, farRight, 14, colors.red)
  drawButton(target, "update", "UPDATE", left, 16, right, 17, colors.purple)
  drawButton(target, "exit", "EXIT", farLeft, 16, farRight, 17, colors.gray)
  writeAt(target, 2, height, "Touch/click a button. Q exits.")
end

local function menu()
  local target, monitorName = screen()
  drawMenu(target)
  while true do
    local event, side, x, y = os.pullEvent()
    if event == "key" and side == keys.q then return end
    if event == "mouse_click" then x, y = side, x
    elseif event == "monitor_touch" and side ~= monitorName then x, y = nil, nil
    elseif event ~= "monitor_touch" then x, y = nil, nil end
    local action = x and hitButton(x, y)
    if action == "status" then local _, height = target.getSize(); showStatus(target); writeAt(target, 2, height, "Touch anywhere to return."); os.pullEvent(); drawMenu(target)
    elseif action == "target" then color(target, colors.black, colors.white); target.clear(); target.setCursorPos(1, 1); local previous = term.redirect(target); setTarget(); term.redirect(previous); sleep(1); drawMenu(target)
    elseif action == "clear" then local ok, e = request("clear-target"); drawMenu(target, ok and "Destination cleared." or e)
    elseif action == "stop" then local ok, e = request("outputs-off"); drawMenu(target, ok and "Aircraft outputs cleared." or e)
    elseif action == "update" then target.clear(); writeAt(target, 2, 2, "Updating remote..."); shell.run(ROOT .. "/update.lua"); return
    elseif action == "exit" then return end
  end
end

local command = (args[1] or "menu"):lower()
if command == "status" then showStatus()
elseif command == "target" then setTarget()
elseif command == "stop" then local ok, e = request("outputs-off"); if ok then print("Aircraft outputs cleared.") else printError(e) end
elseif command == "update" then shell.run(ROOT .. "/update.lua")
elseif command == "version" then print(VERSION)
else menu() end
