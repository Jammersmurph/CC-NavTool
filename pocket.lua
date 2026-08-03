-- CC-NavTool wireless pocket remote v0.5.7-nightly
local VERSION = "0.5.7-nightly"
local CONFIG_PATH = "/navtool/remote.lua"
local DEFAULT = {
  channel = "cc-navtool",
  host = "navtool-aircraft",
  sharedKey = "change-me",
  timeout = 3,
}

local function saveConfig(config)
  if not fs.exists("/navtool") then fs.makeDir("/navtool") end
  local file = assert(fs.open(CONFIG_PATH, "w"))
  file.write("return " .. textutils.serialize(config) .. "\n")
  file.close()
end

local function loadConfig()
  if not fs.exists(CONFIG_PATH) then saveConfig(DEFAULT) return DEFAULT end
  local ok, config = pcall(dofile, CONFIG_PATH)
  if ok and type(config) == "table" then return config end
  return DEFAULT
end

local function openWirelessModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.hasType(side, "modem") then
      local modem = peripheral.wrap(side)
      local ok, wireless = pcall(modem.isWireless)
      if ok and wireless then
        if not rednet.isOpen(side) then rednet.open(side) end
        return side
      end
    end
  end
  return nil
end

local function request(config, command, data)
  local channel = config.channel or config.protocol or "cc-navtool"
  local host = rednet.lookup(channel, config.host)
  if not host then return nil, "Aircraft host not found" end
  rednet.send(host, {
    type = "navtool_request",
    key = config.sharedKey,
    command = command,
    data = data,
  }, channel)
  local sender, response = rednet.receive(channel, config.timeout or 3)
  if sender ~= host or type(response) ~= "table" or response.type ~= "navtool_response" then
    return nil, "No valid response"
  end
  if not response.ok then return nil, response.error or "Request rejected" end
  return response.data
end

local function numberPrompt(label)
  write(label .. ": ")
  return tonumber(read())
end

local function showStatus(status)
  term.clear()
  term.setCursorPos(1, 1)
  print("CC-NavTool Remote " .. VERSION)
  print("Craft: " .. tostring(status.host or "unknown"))
  print("Engaged: " .. tostring(status.engaged))
  if status.target then
    print(string.format("Target: %.1f %.1f %.1f", status.target.x, status.target.y, status.target.z))
    if status.target.name then print("Name: " .. status.target.name) end
  else
    print("Target: none")
  end
  if status.position then
    print(string.format("Position: %.1f %.1f %.1f", status.position.x, status.position.y, status.position.z))
  end
  print("Telemetry: " .. tostring(status.telemetry or "not found"))
  print("")
end

local config = loadConfig()
if not openWirelessModem() then
  printError("Attach an Ender Modem to this pocket computer.")
  return
end

while true do
  local status, err = request(config, "status")
  if status then showStatus(status) else printError(err) end
  print("[1] Refresh   [2] Set target")
  print("[3] Engage    [4] Disengage")
  print("[5] Manual    [6] Clear target")
  print("[7] Config    [Q] Quit")
  write("> ")
  local choice = read():lower()
  if choice == "q" then break
  elseif choice == "2" then
    local x, y, z = numberPrompt("X"), numberPrompt("Y"), numberPrompt("Z")
    write("Name (optional): ") local name = read()
    if x and y and z then
      local _, requestErr = request(config, "set_target", { x=x, y=y, z=z, name=name ~= "" and name or nil })
      if requestErr then printError(requestErr) end
    else printError("Coordinates must be numbers") end
  elseif choice == "3" then
    local _, requestErr = request(config, "engage")
    if requestErr then printError(requestErr) end
  elseif choice == "4" then
    local _, requestErr = request(config, "disengage")
    if requestErr then printError(requestErr) end
  elseif choice == "5" then
    write("Control (forward/reverse/left/right/up/down): ") local control = read():lower()
    local strength = numberPrompt("Strength") or 1
    local duration = numberPrompt("Seconds") or 0.25
    local _, requestErr = request(config, "manual", { control=control, strength=strength, duration=duration })
    if requestErr then printError(requestErr) end
  elseif choice == "6" then
    local _, requestErr = request(config, "clear_target")
    if requestErr then printError(requestErr) end
  elseif choice == "7" then
    write("Host name [" .. config.host .. "]: ") local host = read()
    write("Shared key: ") local key = read("*")
    if host ~= "" then config.host = host end
    if key ~= "" then config.sharedKey = key end
    saveConfig(config)
  end
end
