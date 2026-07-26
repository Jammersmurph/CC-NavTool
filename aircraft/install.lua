-- CC-NavTool onboard installer
local ROOT = "/navtool"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/develop/aircraft/"
local FILES = {
  { remote = "navtool.lua", localPath = ROOT .. "/navtool.lua" },
  { remote = "runtime.lua", localPath = ROOT .. "/runtime.lua" },
  { remote = "flightcore.lua", localPath = ROOT .. "/flightcore.lua" },
  { remote = "lib/pid.lua", localPath = ROOT .. "/lib/pid.lua" },
  { remote = "lib/avionics.lua", localPath = ROOT .. "/lib/avionics.lua" },
  { remote = "lib/flight_director.lua", localPath = ROOT .. "/lib/flight_director.lua" },
  { remote = "lib/control_core.lua", localPath = ROOT .. "/lib/control_core.lua" },
  { remote = "lib/recorder.lua", localPath = ROOT .. "/lib/recorder.lua" },
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

if not http then
  printError("HTTP API is disabled. Enable it in the CC:Tweaked server config.")
  return
end

fs.makeDir(ROOT)
fs.makeDir(ROOT .. "/lib")
fs.makeDir(ROOT .. "/logs")

print("Installing headless NavTool aircraft service...")
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

local launcher = fs.open("/navtool.lua", "w")
launcher.write('local a={...}; if #a==0 then a[1]="server" end; shell.run("/navtool/runtime.lua", table.unpack(a))\n')
launcher.close()

local flightLauncher = fs.open("/flightcore.lua", "w")
flightLauncher.write('shell.run("/navtool/flightcore.lua", ...)\n')
flightLauncher.close()

print("Headless NavTool aircraft service installed.")
print("Start: navtool")
print("Reconfigure networking: navtool setup")
print("Control and saved navigation data belong to NavRemote.")
print("Standalone flight test console: flightcore")
