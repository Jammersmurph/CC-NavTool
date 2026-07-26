-- CC-NavTool remote installer
local ROOT = "/navremote"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/develop/remote/"
local FILES = {
  { remote = "controller.lua", localPath = ROOT .. "/controller.lua" },
  { remote = "controller_runtime.lua", localPath = ROOT .. "/controller_runtime.lua" },
  { remote = "ui_runtime.lua", localPath = ROOT .. "/ui_runtime.lua" },
  { remote = "runtime.lua", localPath = ROOT .. "/runtime.lua" },
  { remote = "location_beacon.lua", localPath = ROOT .. "/location_beacon.lua" },
  { remote = "storage.lua", localPath = ROOT .. "/storage.lua" },
  { remote = "navremote.lua", localPath = ROOT .. "/navremote.lua" },
  { remote = "update.lua", localPath = ROOT .. "/update.lua" },
  { remote = "uninstall.lua", localPath = ROOT .. "/uninstall.lua" },
  { remote = "version.txt", localPath = ROOT .. "/version.txt" },
}

local function download(remote, localPath)
  local response, err = http.get(BASE .. remote)
  if not response then return false, err end
  local body = response.readAll()
  response.close()
  local directory = fs.getDir(localPath)
  if directory ~= "" and not fs.exists(directory) then fs.makeDir(directory) end
  local file = fs.open(localPath, "w")
  if not file then return false, "Could not write " .. localPath end
  file.write(body)
  file.close()
  return true
end

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
local launcher = fs.open("/navremote.lua", "w")
launcher.write('local a={...}; if a[1]=="legacy" then table.remove(a,1); shell.run("/navremote/navremote.lua", table.unpack(a)) else shell.run("/navremote/runtime.lua", table.unpack(a)) end\n')
launcher.close()
print("NavRemote installed.")
print("Run: navremote")
print("Legacy interface: navremote legacy")
print("Q goes back, X quits, and desktop icons support mouse clicks.")
print("Aircraft discovery is available from the Aircraft page with F.")
print("The location beacon runs silently when a wireless modem and GPS are available.")
print("All targets, routes, schedules, logs, and cached state are stored locally under /navremote/data.")
