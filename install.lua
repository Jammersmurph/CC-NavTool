-- CC-NavTool installer
local ROOT = "/navtool"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/main/"
local FILES = {
  { remote = "navtool.lua", localPath = ROOT .. "/navtool.lua" },
  { remote = "pocket.lua", localPath = ROOT .. "/pocket.lua" },
  { remote = "update.lua", localPath = ROOT .. "/update.lua" },
  { remote = "version.txt", localPath = ROOT .. "/version.txt" },
}
local function download(remote, localPath)
  local response, err = http.get(BASE .. remote)
  if not response then return false, err end
  local body = response.readAll(); response.close()
  local file = fs.open(localPath, "w")
  if not file then return false, "Could not write " .. localPath end
  file.write(body); file.close(); return true
end
if not http then printError("HTTP API is disabled. Enable it in the CC:Tweaked server config."); return end
if not fs.exists(ROOT) then fs.makeDir(ROOT) end
if not fs.exists(ROOT .. "/logs") then fs.makeDir(ROOT .. "/logs") end
if not fs.exists(ROOT .. "/profiles") then fs.makeDir(ROOT .. "/profiles") end
print("Installing CC-NavTool...")
for _, item in ipairs(FILES) do
  write("  " .. item.remote .. " ... ")
  local ok, err = download(item.remote, item.localPath)
  if not ok then printError("failed"); printError(tostring(err)); return end
  print("done")
end
if not fs.exists(ROOT .. "/config.lua") then
  local ok, err = download("config.example.lua", ROOT .. "/config.lua")
  if not ok then printError("Could not install default configuration: " .. tostring(err)); return end
  print("  Created default aircraft configuration")
else print("  Preserved existing aircraft configuration") end
if not fs.exists(ROOT .. "/waypoints.db") then local f=fs.open(ROOT .. "/waypoints.db","w"); f.write("{}\n"); f.close() end
local launcher=assert(fs.open("/navtool.lua","w")); launcher.write('shell.run("/navtool/navtool.lua", ...)\n'); launcher.close()
local remote=assert(fs.open("/navremote.lua","w")); remote.write('shell.run("/navtool/pocket.lua", ...)\n'); remote.close()
print(""); print("CC-NavTool installed successfully.")
print("Aircraft: navtool status")
print("Aircraft server: navtool server")
print("Pocket remote: navremote")
print("IMPORTANT: change network.sharedKey in /navtool/config.lua")
