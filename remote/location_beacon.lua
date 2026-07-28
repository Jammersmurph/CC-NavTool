local Beacon = {}

local CONFIG_PATH = "/navremote/config.lua"
local STATUS_PATH = "/navremote/data/beacon_status.lua"

local function serialize(value)
  if type(textutils) == "table" and type(textutils.serialize) == "function" then
    return textutils.serialize(value)
  end
  local parts = { "{" }
  for key, item in pairs(value) do
    parts[#parts + 1] = "[" .. string.format("%q", key) .. "]="
    if type(item) == "string" then
      parts[#parts + 1] = string.format("%q", item)
    else
      parts[#parts + 1] = tostring(item)
    end
    parts[#parts + 1] = ","
  end
  parts[#parts + 1] = "}"
  return table.concat(parts)
end

local function writeStatus(status)
  status.updated = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)
  local directory = fs.getDir(STATUS_PATH)
  if directory ~= "" and not fs.exists(directory) then fs.makeDir(directory) end
  local file = fs.open(STATUS_PATH, "w")
  if not file then return end
  file.write("return " .. serialize(status))
  file.close()
end

local function hasType(name, wanted)
  if type(peripheral.hasType) == "function" then
    local ok, value = pcall(peripheral.hasType, name, wanted)
    if ok and value then return true end
  end
  return peripheral.getType(name) == wanted
end

local function wirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    if hasType(name, "modem") then
      local modem = peripheral.wrap(name)
      local ok, wireless = pcall(modem.isWireless)
      if ok and wireless then return name, modem end
    end
  end
end

local function loadConfig()
  local ok, value = pcall(dofile, CONFIG_PATH)
  if ok and type(value) == "table" then return value end
  return {}
end

function Beacon.run()
  while true do
    local config = loadConfig()
    local beacon = type(config.locationBeacon) == "table" and config.locationBeacon or {}
    local profile = config.profiles and config.profiles[config.activeProfile]
    local interval = math.max(1, tonumber(beacon.interval) or 3)
    local port = math.max(1, math.min(65535, tonumber(beacon.port) or 9999))
    local modemName, modem = wirelessModem()

    if beacon.enabled == false then
      writeStatus({ enabled = false, ok = false, reason = "beacon disabled", modem = modemName, port = port })
    elseif not modem then
      -- NavRemote itself may still use a wired modem. Location broadcasting simply
      -- remains unavailable until a wireless or Ender modem is attached.
      writeStatus({ enabled = true, ok = false, reason = "no wireless modem", port = port })
    elseif not profile then
      writeStatus({ enabled = true, ok = false, reason = "no active profile", modem = modemName, port = port })
    elseif type(gps) ~= "table" or type(gps.locate) ~= "function" then
      writeStatus({ enabled = true, ok = false, reason = "gps unavailable", modem = modemName, port = port })
    else
      modem.open(port)
      local ok, x, y, z = pcall(gps.locate, 2, false)
      if x and y and z then
        modem.transmit(port, port, {
          type = "NAVREMOTE_LOCATION",
          version = 1,
          id = os.getComputerID(),
          label = os.getComputerLabel() or ("NavRemote " .. os.getComputerID()),
          x = x, y = y, z = z,
          key = profile.sharedKey or "",
          aircraftHost = profile.host or "navtool-aircraft",
          rednetChannel = profile.channel or "cc-navtool",
        })
        writeStatus({ enabled = true, ok = true, reason = "transmitted", modem = modemName, port = port, x = x, y = y, z = z })
      else
        writeStatus({ enabled = true, ok = false, reason = ok and "gps unavailable" or "gps error", modem = modemName, port = port })
      end
    end

    sleep(interval)
  end
end

return Beacon
