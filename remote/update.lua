local ROOT = "/navremote"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/main/remote/"
local args = { ... }

local function fetchText(url)
  local response, err = http.get(url)
  if not response then return nil, err end
  local body = response.readAll()
  response.close()
  return body
end

local function writeFile(path, body)
  local directory = fs.getDir(path)
  if directory ~= "" and not fs.exists(directory) then fs.makeDir(directory) end
  local temporary = path .. ".new"
  local file = fs.open(temporary, "w")
  if not file then return false, "Could not write " .. temporary end
  file.write(body)
  file.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(temporary, path)
  return true
end

if not term.isColor() then printError("NavRemote requires an Advanced Computer."); return end
if not http then printError("HTTP API is disabled."); return end

if args[1] ~= "--fresh" then
  local newest, err = fetchText(BASE .. "update.lua?cache=" .. tostring(os.epoch and os.epoch("utc") or os.clock()))
  if not newest then printError("Could not download the current updater: " .. tostring(err)); return end
  local bootstrap = ROOT .. "/update.bootstrap.lua"
  local ok, writeErr = writeFile(bootstrap, newest)
  if not ok then printError(writeErr); return end
  local result = shell.run(bootstrap, "--fresh")
  if fs.exists(bootstrap) then fs.delete(bootstrap) end
  return result
end

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

fs.makeDir(ROOT)
fs.makeDir(ROOT .. "/data")
fs.makeDir(ROOT .. "/data/profiles")
print("Updating NavRemote from main...")
for _, item in ipairs(FILES) do
  write("  " .. item.remote .. " ... ")
  local body, err = fetchText(BASE .. item.remote .. "?cache=" .. tostring(os.epoch and os.epoch("utc") or os.clock()))
  if not body then printError("failed: " .. tostring(err)); return end
  local ok, writeErr = writeFile(item.localPath, body)
  if not ok then printError("failed: " .. tostring(writeErr)); return end
  print("done")
end

for _, stale in ipairs({"ui_runtime.lua", "navremote.lua", "update.bootstrap.lua"}) do
  local path = ROOT .. "/" .. stale
  if fs.exists(path) then fs.delete(path); print("  removed stale " .. stale) end
end

local launcher = fs.open("/navremote.lua", "w")
if not launcher then printError("Could not update /navremote.lua"); return end
launcher.write('shell.run("/navremote/input_runtime.lua", ...)\n')
launcher.close()
print("NavRemote update complete. Config and controller data preserved.")
print("Advanced Computer mouse controls are enabled. Q goes back; X quits.")
