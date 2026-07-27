local REPO = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool"

local choices = {
  { label = "NavTool Server", branch = "main", path = "aircraft", kind = "server", group = "Stable" },
  { label = "NavRemote", branch = "main", path = "remote", kind = "remote", group = "Stable" },
  { label = "NavTool Server", branch = "develop", path = "aircraft", kind = "server", group = "Nightly" },
  { label = "NavRemote", branch = "develop", path = "remote", kind = "remote", group = "Nightly" },
}

local serverFiles = {
  { remote = "navtool.lua", localPath = "/navtool/navtool.lua" },
  { remote = "runtime.lua", localPath = "/navtool/runtime.lua" },
  { remote = "hardware.lua", localPath = "/navtool/hardware.lua" },
  { remote = "location_patch.lua", localPath = "/navtool/location_patch.lua" },
  { remote = "location_network.lua", localPath = "/navtool/location_network.lua" },
  { remote = "flightcore.lua", localPath = "/navtool/flightcore.lua" },
  { remote = "lib/pid.lua", localPath = "/navtool/lib/pid.lua" },
  { remote = "lib/avionics.lua", localPath = "/navtool/lib/avionics.lua" },
  { remote = "lib/flight_director.lua", localPath = "/navtool/lib/flight_director.lua" },
  { remote = "lib/control_core.lua", localPath = "/navtool/lib/control_core.lua" },
  { remote = "lib/recorder.lua", localPath = "/navtool/lib/recorder.lua" },
  { remote = "update.lua", localPath = "/navtool/update.lua" },
  { remote = "uninstall.lua", localPath = "/navtool/uninstall.lua" },
  { remote = "version.txt", localPath = "/navtool/version.txt" },
}

local remoteFiles = {
  { remote = "controller.lua", localPath = "/navremote/controller.lua" },
  { remote = "controller_runtime.lua", localPath = "/navremote/controller_runtime.lua" },
  { remote = "input_runtime.lua", localPath = "/navremote/input_runtime.lua" },
  { remote = "hardware_patch.lua", localPath = "/navremote/hardware_patch.lua" },
  { remote = "hardware_runtime.lua", localPath = "/navremote/hardware_runtime.lua" },
  { remote = "runtime.lua", localPath = "/navremote/runtime.lua" },
  { remote = "location_beacon.lua", localPath = "/navremote/location_beacon.lua" },
  { remote = "storage.lua", localPath = "/navremote/storage.lua" },
  { remote = "update.lua", localPath = "/navremote/update.lua" },
  { remote = "uninstall.lua", localPath = "/navremote/uninstall.lua" },
  { remote = "version.txt", localPath = "/navremote/version.txt" },
}

local function cacheToken()
  return tostring(os.epoch and os.epoch("utc") or os.clock())
end

local function clear()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function writeAt(x, y, text, fg, bg)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.setCursorPos(x, y)
  term.write(tostring(text))
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
end

local function draw(selected)
  clear()
  writeAt(2, 2, "NavTool by Jammersmurph Installer:", colors.cyan)
  writeAt(2, 4, "Use arrow keys and Enter. Q exits.", colors.lightGray)
  local y = 6
  local lastGroup
  for index, choice in ipairs(choices) do
    if choice.group ~= lastGroup then
      if lastGroup then y = y + 1 end
      writeAt(2, y, choice.group .. ":", colors.yellow)
      y = y + 1
      lastGroup = choice.group
    end
    local active = index == selected
    local bg = active and colors.gray or colors.black
    local fg = active and colors.white or colors.lightGray
    writeAt(4, y, (active and "> " or "  ") .. choice.label, fg, bg)
    y = y + 1
  end
end

local function choose()
  local selected = 1
  while true do
    draw(selected)
    local _, key = os.pullEvent("key")
    if key == keys.q then return nil end
    if key == keys.up then selected = selected > 1 and selected - 1 or #choices
    elseif key == keys.down then selected = selected < #choices and selected + 1 or 1
    elseif key == keys.enter then return choices[selected] end
  end
end

local function ensureDir(path)
  local directory = fs.getDir(path)
  if directory ~= "" and not fs.exists(directory) then fs.makeDir(directory) end
end

local function fetch(url)
  local response, err = http.get(url)
  if not response then return nil, err end
  local body = response.readAll()
  response.close()
  return body
end

local function writeFile(path, body)
  ensureDir(path)
  local temporary = path .. ".new"
  local file = fs.open(temporary, "w")
  if not file then return false, "Could not write " .. temporary end
  file.write(body)
  file.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(temporary, path)
  return true
end

local function readFile(path)
  if not fs.exists(path) then return "" end
  local file = fs.open(path, "r")
  if not file then return "" end
  local body = file.readAll()
  file.close()
  return body or ""
end

local function prependFile(path, body)
  local existing = readFile(path)
  local file = fs.open(path, "w")
  if not file then return false, "Could not write " .. path end
  local separator = existing ~= "" and not body:match("\n$") and "\n" or ""
  file.write(body .. separator .. existing)
  file.close()
  return true
end

local function confirm(label)
  write(label .. " (y/N): ")
  local answer = read()
  return tostring(answer or ""):lower():sub(1, 1) == "y"
end

local function maybeAddStartup(program)
  local line = 'shell.run("bg", "shell.lua", "' .. program .. '")'
  local startup = readFile("/startup.lua")
  if startup:find(line, 1, true) then return end
  if not confirm("Run " .. program .. " in the background at startup") then return end
  local ok, err = prependFile("/startup.lua", line .. "\n")
  if ok then print("Added startup background launch for " .. program)
  else printError(err) end
end

local function download(base, item, branch)
  local body, err = fetch(base .. item.remote .. "?cache=" .. cacheToken())
  if not body then return false, err end
  if item.remote == "update.lua" and branch then
    body = body:gsub("CC%-NavTool/[^/]+/", "CC-NavTool/" .. branch .. "/")
  end
  return writeFile(item.localPath, body)
end

local function installServer(choice)
  local base = REPO .. "/" .. choice.branch .. "/aircraft/"
  fs.makeDir("/navtool")
  fs.makeDir("/navtool/lib")
  fs.makeDir("/navtool/logs")
  for _, item in ipairs(serverFiles) do
    write("  " .. item.remote .. " ... ")
    local ok, err = download(base, item, choice.branch)
    if not ok then printError("failed: " .. tostring(err)); return false end
    print("done")
  end
  if not fs.exists("/navtool/config.lua") then
    local ok, err = download(base, { remote = "config.example.lua", localPath = "/navtool/config.lua" }, choice.branch)
    if not ok then printError("Config install failed: " .. tostring(err)); return false end
    print("  Created onboard configuration")
  else
    print("  Preserved onboard configuration")
  end
  writeFile("/navtool.lua", 'local a={...}; if #a==0 then a[1]="server" end; shell.run("/navtool/runtime.lua", table.unpack(a))\n')
  writeFile("/flightcore.lua", 'shell.run("/navtool/flightcore.lua", ...)\n')
  print("NavTool Server installed. Run: navtool")
  maybeAddStartup("navtool.lua")
  return true
end

local function installRemote(choice)
  if not term.isColor() then printError("NavRemote requires an Advanced Computer."); return false end
  local base = REPO .. "/" .. choice.branch .. "/remote/"
  fs.makeDir("/navremote")
  fs.makeDir("/navremote/data")
  fs.makeDir("/navremote/data/profiles")
  for _, item in ipairs(remoteFiles) do
    write("  " .. item.remote .. " ... ")
    local ok, err = download(base, item, choice.branch)
    if not ok then printError("failed: " .. tostring(err)); return false end
    print("done")
  end
  if not fs.exists("/navremote/config.lua") then
    local ok, err = download(base, { remote = "config.example.lua", localPath = "/navremote/config.lua" }, choice.branch)
    if not ok then printError("Config install failed: " .. tostring(err)); return false end
    print("  Created remote configuration")
  else
    print("  Preserved remote configuration")
  end
  for _, stale in ipairs({ "ui_runtime.lua", "navremote.lua", "update.bootstrap.lua" }) do
    local path = "/navremote/" .. stale
    if fs.exists(path) then fs.delete(path) end
  end
  writeFile("/navremote.lua", 'shell.run("/navremote/runtime.lua", ...)\n')
  print("NavRemote installed. Run: navremote")
  maybeAddStartup("navremote.lua")
  return true
end

if not http then printError("HTTP API is disabled."); return end

local choice = choose()
if not choice then clear(); print("Install cancelled."); return end

clear()
print("Installing " .. choice.group .. " " .. choice.label .. " from " .. choice.branch .. "...")
local ok
if choice.kind == "server" then ok = installServer(choice) else ok = installRemote(choice) end
if ok then print("Install complete.") end
