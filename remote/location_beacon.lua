local Beacon = {}

local CONFIG_PATH = "/navremote/config.lua"

local function wirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
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
  local modemName, modem = wirelessModem()
  if not modem then
    -- NavRemote itself may still use a wired modem. Location broadcasting simply
    -- remains unavailable until a wireless or Ender modem is attached.
    while true do sleep(3600) end
  end

  while true do
    local config = loadConfig()
    local beacon = type(config.locationBeacon) == "table" and config.locationBeacon or {}
    local profile = config.profiles and config.profiles[config.activeProfile]
    local interval = math.max(1, tonumber(beacon.interval) or 3)
    local port = math.max(1, math.min(65535, tonumber(beacon.port) or 9999))

    if beacon.enabled ~= false and profile then
      modem.open(port)
      local x, y, z = gps.locate(2, false)
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
      end
    end

    sleep(interval)
  end
end

return Beacon
