local VERSION = "0.3.0-dev"
local ROOT = "/navremote"
local CONFIG_PATH = ROOT .. "/config.lua"
local args = { ... }

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

local function showStatus()
  local response, requestErr = request("status")
  if not response then printError(requestErr); return end
  local data = response.data or {}
  term.clear()
  term.setCursorPos(1, 1)
  print("CC-NavTool Remote " .. VERSION)
  print("Host: " .. tostring(config.host))
  print("Telemetry: " .. (data.telemetry and "online" or "offline"))
  print("Aircraft version: " .. tostring(data.version))
  if data.peripheral then print("Peripheral: " .. tostring(data.peripheral)) end
  print("Target: " .. textutils.serialize(data.target))
  print("Pose: " .. textutils.serialize(data.pose))
  print("Velocity: " .. textutils.serialize(data.velocity))
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

local function menu()
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    print("CC-NavTool Remote")
    print("Aircraft: " .. tostring(config.host))
    print("")
    print("1. Aircraft status")
    print("2. Set destination")
    print("3. Clear destination")
    print("4. Emergency outputs off")
    print("5. Update remote")
    print("6. Exit")
    write("> ")
    local choice = read()
    if choice == "1" then showStatus(); print("\nPress Enter"); read()
    elseif choice == "2" then setTarget(); sleep(1)
    elseif choice == "3" then local ok, e = request("clear-target"); if ok then print("Destination cleared.") else printError(e) end; sleep(1)
    elseif choice == "4" then local ok, e = request("outputs-off"); if ok then print("Aircraft outputs cleared.") else printError(e) end; sleep(1)
    elseif choice == "5" then shell.run(ROOT .. "/update.lua"); return
    elseif choice == "6" then return end
  end
end

local command = (args[1] or "menu"):lower()
if command == "status" then showStatus()
elseif command == "target" then setTarget()
elseif command == "stop" then local ok, e = request("outputs-off"); if ok then print("Aircraft outputs cleared.") else printError(e) end
elseif command == "update" then shell.run(ROOT .. "/update.lua")
elseif command == "version" then print(VERSION)
else menu() end
