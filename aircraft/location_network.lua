local LocationNetwork = {}

local remotes = {}
local followId
local config
local callbacks

local function wirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      local ok, wireless = pcall(modem.isWireless)
      if ok and wireless then return name, modem end
    end
  end
end

local function now()
  return os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)
end

local function copyRemote(item)
  return {
    id = item.id,
    label = item.label,
    x = item.x, y = item.y, z = item.z,
    seen = item.seen,
    distance = item.distance,
  }
end

local function prune()
  local ttl = tonumber(config.locationTracking and config.locationTracking.timeout) or 12
  local cutoff = now() - ttl * 1000
  for id, item in pairs(remotes) do
    if (item.seen or 0) < cutoff then
      remotes[id] = nil
      if followId == id then followId = nil end
    end
  end
end

function LocationNetwork.configure(newConfig, newCallbacks)
  config = newConfig or {}
  callbacks = newCallbacks or {}
end

function LocationNetwork.list()
  prune()
  local result = {}
  for _, item in pairs(remotes) do result[#result + 1] = copyRemote(item) end
  table.sort(result, function(a, b)
    local al, bl = tostring(a.label or ""), tostring(b.label or "")
    if al == bl then return tonumber(a.id) < tonumber(b.id) end
    return al < bl
  end)
  return result
end

local function resolveRemote(value)
  prune()
  local wanted = tostring(value or "")
  local numeric = tonumber(wanted)
  if numeric and remotes[numeric] then return remotes[numeric] end
  for _, item in pairs(remotes) do
    if tostring(item.label or "") == wanted then return item end
  end
end

function LocationNetwork.follow(value)
  local item = resolveRemote(value)
  if not item then return false, "NavRemote not found" end
  followId = item.id
  if callbacks and callbacks.setTarget then callbacks.setTarget(item, true) end
  return true, copyRemote(item)
end

function LocationNetwork.autoHome(value)
  local item = resolveRemote(value)
  if not item then return false, "NavRemote not found" end
  followId = nil
  if callbacks and callbacks.setTarget then callbacks.setTarget(item, false) end
  return true, copyRemote(item)
end

function LocationNetwork.stopFollow()
  followId = nil
  return true
end

function LocationNetwork.following()
  return followId
end

function LocationNetwork.run()
  local tracking = config and config.locationTracking or {}
  if tracking.enabled ~= true then
    while true do sleep(3600) end
  end

  local modemName, modem = wirelessModem()
  if not modem then
    printError("NavRemote location tracking requires a wireless or Ender modem.")
    while true do sleep(3600) end
  end

  local port = math.max(1, math.min(65535, tonumber(tracking.port) or 9999))
  modem.open(port)
  print("NavRemote location tracking online on port " .. port .. " via " .. modemName)

  while true do
    local _, side, channel, _, message, distance = os.pullEvent("modem_message")
    if side == modemName and channel == port and type(message) == "table" and message.type == "NAVREMOTE_LOCATION" then
      local network = config.network or {}
      local validKey = tostring(message.key or "") == tostring(network.sharedKey or "")
      local validHost = message.aircraftHost == nil or tostring(message.aircraftHost) == tostring(network.host or "navtool-aircraft")
      local validChannel = message.rednetChannel == nil or tostring(message.rednetChannel) == tostring(network.channel or "cc-navtool")
      local x, y, z = tonumber(message.x), tonumber(message.y), tonumber(message.z)
      local id = tonumber(message.id)
      if validKey and validHost and validChannel and id and x and y and z then
        local item = {
          id = id,
          label = tostring(message.label or ("NavRemote " .. id)),
          x = x, y = y, z = z,
          seen = now(),
          distance = distance,
        }
        remotes[id] = item
        if followId == id and callbacks and callbacks.setTarget then callbacks.setTarget(item, true) end
      end
    end
  end
end

return LocationNetwork
