-- CC-NavTool NavRemote installer (Advanced Computer only)
local ROOT = "/navremote"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/main/remote/"
local FILES = {
  { remote = "controller.lua", localPath = ROOT .. "/controller.lua" },
  { remote = "controller_runtime.lua", localPath = ROOT .. "/controller_runtime.lua" },
  { remote = "input_runtime.lua", localPath = ROOT .. "/input_runtime.lua" },
  { remote = "hardware_patch.lua", localPath = ROOT .. "/hardware_patch.lua" },
  { remote = "hardware_runtime.lua", localPath = ROOT .. "/hardware_runtime.lua" },
  { remote = "runtime.lua", localPath = ROOT .. "/runtime.lua" },
  { remote = "location_beacon.lua", localPath = ROOT .. "/location_beacon.lua" },
  { remote = "storage.lua", localPath = ROOT .. "/storage.lua" },
  { remote = "update.lua", localPath = ROOT .. "/update.lua" },
  { remote = "uninstall.lua", localPath = ROOT .. "/uninstall.lua" },
  { remote = "version.txt", localPath = ROOT .. "/version.txt" },
}

local cacheToken = tostring(os.epoch and os.epoch("utc") or os.clock())

local function download(remote, localPath)
  local response, err = http.get(BASE .. remote .. "?cache=" .. cacheToken)
  if not response then return false, err end
  local body = response.readAll()
  response.close()
  local directory = fs.getDir(localPath)
  if directory ~= "" and not fs.exists(directory) then fs.makeDir(directory) end
  local temporary = localPath .. ".new"
  local file = fs.open(temporary, "w")
  if not file then return false, "Could not write " .. temporary end
  file.write(body)
  file.close()
  if fs.exists(localPath) then fs.delete(localPath) end
  fs.move(temporary, localPath)
  return true
end

local function isPocketComputer()
  return type(pocket) == "table"
end

local function attachedMonitors()
  local result = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then result[#result + 1] = name end
  end
  return result
end

local function seedMonitorPreference(enabled)
  local configPath = ROOT .. "/config.lua"
  if fs.exists(configPath) then
    local ok, remoteConfig = pcall(dofile, configPath)
    if ok and type(remoteConfig) == "table" and remoteConfig.monitorTelemetry == nil then
      remoteConfig.monitorTelemetry = enabled == true
      local configFile = fs.open(configPath, "w")
      if configFile then configFile.write("return " .. textutils.serialize(remoteConfig) .. "\n"); configFile.close() end
    end
  end
  local path = ROOT .. "/data/profiles/default.db"
  local data = nil
  if fs.exists(path) then
    local file = fs.open(path, "r")
    if file then data = textutils.unserialize(file.readAll()); file.close() end
  end
  data = type(data) == "table" and data or { targets = {}, routes = {}, schedules = {}, eventLog = {} }
  data.preferences = type(data.preferences) == "table" and data.preferences or {}
  if data.preferences.monitorTelemetry == nil then data.preferences.monitorTelemetry = enabled == true end
  local file = fs.open(path, "w")
  if file then file.write(textutils.serialize(data)); file.close() end
end

if not term.isColor() then printError("NavRemote requires an Advanced Computer."); return end
if not http then printError("HTTP API is disabled."); return end
fs.makeDir(ROOT)
fs.makeDir(ROOT .. "/data")
fs.makeDir(ROOT .. "/data/profiles")
print("Installing NavRemote...")
for _, item in ipairs(FILES) do
  write("  " .. item.remote .. " ... ")
  local ok, err = download(item.remote, item.localPath)
  if not ok then printError("failed: " .. tostring(err)); return end
  print("done")
end
if not fs.exists(ROOT .. "/config.lua") then
  local ok, err = download("config.example.lua", ROOT .. "/config.lua")
  if not ok then printError("Config install failed: " .. tostring(err)); return end
  print("  Created remote configuration")
else
  print("  Preserved remote configuration")
end
local monitors = attachedMonitors()
if not isPocketComputer() and #monitors > 0 then
  write("Display NavRemote telemetry on attached monitor(s)? [y/N]: ")
  local answer = tostring(read() or ""):lower():sub(1, 1)
  seedMonitorPreference(answer == "y")
end
for _, stale in ipairs({"ui_runtime.lua", "navremote.lua", "update.bootstrap.lua"}) do
  local path = ROOT .. "/" .. stale
  if fs.exists(path) then fs.delete(path) end
end
local launcher = fs.open("/navremote.lua", "w")
if not launcher then printError("Could not create /navremote.lua"); return end
launcher.write('shell.run("/navremote/input_runtime.lua", ...)\n')
launcher.close()
print("NavRemote installed.")
print("Run: navremote")
print("Advanced Computer mouse controls are enabled. Q goes back; X quits.")
print("Local data is stored under /navremote/data.")
