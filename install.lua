-- CC-NavTool installer
local ROOT = "/navtool"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/main/"
local FILES = {
  { remote = "navtool.lua", localPath = ROOT .. "/navtool.lua" },
  { remote = "update.lua", localPath = ROOT .. "/update.lua" },
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

if not fs.exists(ROOT) then fs.makeDir(ROOT) end
if not fs.exists(ROOT .. "/logs") then fs.makeDir(ROOT .. "/logs") end
if not fs.exists(ROOT .. "/profiles") then fs.makeDir(ROOT .. "/profiles") end

print("Installing CC-NavTool...")
for _, item in ipairs(FILES) do
  write("  " .. item.remote .. " ... ")
  local ok, err = download(item.remote, item.localPath)
  if not ok then
    printError("failed")
    printError(tostring(err))
    return
  end
  print("done")
end

if not fs.exists(ROOT .. "/config.lua") then
  local ok, err = download("config.example.lua", ROOT .. "/config.lua")
  if not ok then
    printError("Could not install default configuration: " .. tostring(err))
    return
  end
  print("  Created default configuration")
else
  print("  Preserved existing configuration")
end

if not fs.exists(ROOT .. "/waypoints.db") then
  local file = fs.open(ROOT .. "/waypoints.db", "w")
  file.write("{}\n")
  file.close()
end

local launcher = fs.open("/navtool.lua", "w")
if not launcher then
  printError("Could not create /navtool.lua launcher")
  return
end
launcher.write('shell.run("/navtool/navtool.lua", ...)\n')
launcher.close()

print("")
print("CC-NavTool installed successfully.")
print("Run: navtool status")
print("Edit configuration: edit /navtool/config.lua")
print("Safety default: outputs are limited to strength 5.")
