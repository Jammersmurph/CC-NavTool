local Storage = {}

local ROOT = "/navremote/data"
local INDEX_PATH = ROOT .. "/index.db"

local function ensureDir(path)
  if not fs.exists(path) then fs.makeDir(path) end
end

local function read(path, fallback)
  if not fs.exists(path) then return fallback end
  local file = fs.open(path, "r")
  if not file then return fallback end
  local value = textutils.unserialize(file.readAll())
  file.close()
  if value == nil then return fallback end
  return value
end

local function write(path, value)
  local directory = fs.getDir(path)
  if directory ~= "" then ensureDir(directory) end
  local temporary = path .. ".new"
  local file = fs.open(temporary, "w")
  if not file then return false, "Could not write " .. path end
  file.write(textutils.serialize(value))
  file.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(temporary, path)
  return true
end

local function safeName(value)
  value = tostring(value or "default")
  value = value:gsub("[^%w%-%._]", "_")
  if value == "" then value = "default" end
  return value
end

local function profilePath(name)
  return ROOT .. "/profiles/" .. safeName(name) .. ".db"
end

local function defaults(name)
  return {
    version = 2,
    profile = name,
    target = nil,
    targets = {},
    routes = {},
    schedules = {},
    activeRoute = nil,
    activeSchedule = nil,
    preferences = {
      desktopCategory = "HOME",
      selectedIcon = 1,
      autoRefresh = true,
      arrivalRadius = 5,
      manualStrength = 2,
    },
    lastStatus = nil,
    eventLog = {},
  }
end

function Storage.init()
  ensureDir(ROOT)
  ensureDir(ROOT .. "/profiles")
  if not fs.exists(INDEX_PATH) then write(INDEX_PATH, { profiles = {} }) end
end

function Storage.load(profileName)
  Storage.init()
  local data = read(profilePath(profileName), defaults(profileName))
  if type(data) ~= "table" then data = defaults(profileName) end
  data.version = math.max(tonumber(data.version) or 1, 2)
  data.profile = profileName
  data.targets = type(data.targets) == "table" and data.targets or {}
  data.routes = type(data.routes) == "table" and data.routes or {}
  data.schedules = type(data.schedules) == "table" and data.schedules or {}
  data.preferences = type(data.preferences) == "table" and data.preferences or {}
  if data.preferences.desktopCategory == nil then data.preferences.desktopCategory = "HOME" end
  if data.preferences.selectedIcon == nil then data.preferences.selectedIcon = 1 end
  if data.preferences.autoRefresh == nil then data.preferences.autoRefresh = true end
  if data.preferences.arrivalRadius == nil then data.preferences.arrivalRadius = 5 end
  if data.preferences.manualStrength == nil then data.preferences.manualStrength = 2 end
  data.eventLog = type(data.eventLog) == "table" and data.eventLog or {}
  return data
end

function Storage.save(profileName, data)
  Storage.init()
  data.profile = profileName
  data.version = 2
  local ok, err = write(profilePath(profileName), data)
  if not ok then return false, err end
  local index = read(INDEX_PATH, { profiles = {} })
  index.profiles = type(index.profiles) == "table" and index.profiles or {}
  index.profiles[profileName] = { updated = os.epoch and os.epoch("utc") or nil }
  write(INDEX_PATH, index)
  return true
end

function Storage.log(data, level, message)
  data.eventLog = type(data.eventLog) == "table" and data.eventLog or {}
  data.eventLog[#data.eventLog + 1] = {
    time = os.epoch and os.epoch("utc") or nil,
    clock = textutils.formatTime and textutils.formatTime(os.time(), true) or tostring(os.time()),
    level = level or "INFO",
    message = tostring(message),
  }
  while #data.eventLog > 100 do table.remove(data.eventLog, 1) end
end

function Storage.names(map)
  local names = {}
  for name in pairs(map or {}) do names[#names + 1] = name end
  table.sort(names)
  return names
end

return Storage
