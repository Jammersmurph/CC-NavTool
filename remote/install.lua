-- CC-NavTool remote installer
local ROOT = "/navremote"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/develop/remote/"
local FILES = {
  { remote = "navremote.lua", localPath = ROOT .. "/navremote.lua" },
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

if not http then printError("HTTP API is disabled."); return end
fs.makeDir(ROOT)
print("Installing CC-NavTool Remote...")
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
launcher.write('shell.run("/navremote/navremote.lua", ...)\n')
launcher.close()
print("CC-NavTool Remote installed.")
print("Run: navremote")
