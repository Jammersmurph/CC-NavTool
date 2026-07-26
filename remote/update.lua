local ROOT = "/navremote"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/develop/remote/"
local FILES = {
  { remote = "controller.lua", localPath = ROOT .. "/controller.lua" },
  { remote = "controller_runtime.lua", localPath = ROOT .. "/controller_runtime.lua" },
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
fs.makeDir(ROOT .. "/data")
fs.makeDir(ROOT .. "/data/profiles")
print("Updating NavRemote from develop...")
for _, item in ipairs(FILES) do
  write("  " .. item.remote .. " ... ")
  local ok, err = download(item.remote, item.localPath)
  if not ok then printError("failed: " .. tostring(err)); return end
  print("done")
end
local launcher = fs.open("/navremote.lua", "w")
if launcher then
  launcher.write('local a={...}; if a[1]=="legacy" then table.remove(a,1); shell.run("/navremote/navremote.lua", table.unpack(a)) else shell.run("/navremote/runtime.lua", table.unpack(a)) end\n')
  launcher.close()
end
print("NavRemote update complete. Config and local controller data preserved.")
print("Aircraft discovery is available from the Aircraft page with F.")
print("The location beacon runs silently when a wireless modem and GPS are available.")
