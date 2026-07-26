local ROOT = "/navtool"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/develop/aircraft/"
local FILES = {
  { remote = "navtool.lua", localPath = ROOT .. "/navtool.lua" },
  { remote = "runtime.lua", localPath = ROOT .. "/runtime.lua" },
  { remote = "hardware.lua", localPath = ROOT .. "/hardware.lua" },
  { remote = "location_patch.lua", localPath = ROOT .. "/location_patch.lua" },
  { remote = "location_network.lua", localPath = ROOT .. "/location_network.lua" },
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
  local temporary = localPath .. ".new"
  local file = fs.open(temporary, "w")
  if not file then return false, "Could not write " .. temporary end
  file.write(body)
  file.close()
  if fs.exists(localPath) then fs.delete(localPath) end
  fs.move(temporary, localPath)
  return true
end

if not http then printError("HTTP API is disabled."); return end
fs.makeDir(ROOT)
fs.makeDir(ROOT .. "/lib")
fs.makeDir(ROOT .. "/logs")
print("Updating headless NavTool aircraft service from develop...")
for _, item in ipairs(FILES) do
  write("  " .. item.remote .. " ... ")
  local ok, err = download(item.remote, item.localPath)
  if not ok then printError("failed: " .. tostring(err)); return end
  print("done")
end

local launcher = fs.open("/navtool.lua", "w")
if launcher then
  launcher.write('local a={...}; if #a==0 then a[1]="server" end; shell.run("/navtool/runtime.lua", table.unpack(a))\n')
  launcher.close()
end

local flightLauncher = fs.open("/flightcore.lua", "w")
if flightLauncher then
  flightLauncher.write('shell.run("/navtool/flightcore.lua", ...)\n')
  flightLauncher.close()
end

print("Onboard update complete. Config and logs preserved.")
print("Start the aircraft service with: navtool")
print("Reconfigure networking with: navtool setup")
