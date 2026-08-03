-- CC-NavTool updater
local ROOT = "/navtool"
local BASE = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/develop/"
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
  local temporary = localPath .. ".new"
  local file = fs.open(temporary, "w")
  if not file then return false, "Could not open " .. temporary end
  file.write(body); file.close()
  if fs.exists(localPath) then fs.delete(localPath) end
  fs.move(temporary, localPath); return true
end
if not http then printError("HTTP API is disabled in CC:Tweaked."); return end
if not fs.exists(ROOT) then fs.makeDir(ROOT) end
print("Updating CC-NavTool...")
for _, item in ipairs(FILES) do
  write("  " .. item.remote .. " ... ")
  local ok, err = download(item.remote, item.localPath)
  if not ok then printError("failed"); printError(tostring(err)); return end
  print("done")
end
local remote=fs.open("/navremote.lua","w"); if remote then remote.write('shell.run("/navtool/pocket.lua", ...)\n'); remote.close() end
print("Update complete. Config, state, and waypoints were preserved.")
