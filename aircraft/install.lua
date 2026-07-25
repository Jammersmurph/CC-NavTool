-- CC-NavTool onboard installer
local ROOT = "/navtool"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/develop/aircraft/"
local FILES = {
  { remote = "navtool.lua", localPath = ROOT .. "/navtool.lua" },
  { remote = "update.lua", localPath = ROOT .. "/update.lua" },
  { remote = "uninstall.lua", localPath = ROOT .. "/uninstall.lua" },
  { remote = "version.txt", localPath = ROOT .. "/version.txt" },
}

local function download(remote, localPath)
  local response, err = http.get(BASE .. remote)
  if not response then return false, err end
  local body = response.readAll()
  response.close()
  local file = fs.open(localPath, "w")
  if not file then return false, "Could not write " .. localPath end
  file.write(body)
  file.close()
  return true
end

if not http then
  printError("HTTP API is disabled. Enable it in the CC:Tweaked server config.")
  return
end

fs.makeDir(ROOT)
fs.makeDir(ROOT .. "/logs")
fs.makeDir(ROOT .. "/profiles")

print("Installing onboard CC-NavTool...")
for _, item in ipairs(FILES) do
  write("  " .. item.remote .. " ... ")
  local ok, err = download(item.remote, item.localPath)
  if not ok then printError("failed: " .. tostring(err)); return end
  print("done")
end

if not fs.exists(ROOT .. "/config.lua") then
  local ok, err = download("config.example.lua", ROOT .. "/config.lua")
  if not ok then printError("Config install failed: " .. tostring(err)); return end
  print("  Created onboard configuration")
else
  print("  Preserved onboard configuration")
end

if not fs.exists(ROOT .. "/waypoints.db") then
  local file = fs.open(ROOT .. "/waypoints.db", "w")
  file.write("{}\n")
  file.close()
end

local launcher = fs.open("/navtool.lua", "w")
launcher.write('shell.run("/navtool/navtool.lua", ...)\n')
launcher.close()

print("Onboard navtool installed.")
print("Run: navtool")
print("Uninstall: navtool uninstall")
print("Remote networking is disabled by default.")
