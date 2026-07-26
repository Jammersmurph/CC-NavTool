local ROOT = "/navremote"
local args = { ... }
local command = type(args[1]) == "string" and args[1]:lower() or nil

if command == "update" then
  return shell.run(ROOT .. "/update.lua")
elseif command == "uninstall" then
  return shell.run(ROOT .. "/uninstall.lua")
elseif command == "version" then
  local file = fs.open(ROOT .. "/version.txt", "r")
  if not file then printError("NavRemote version file is missing."); return false end
  print(file.readAll())
  file.close()
  return true
end

local Beacon = dofile(ROOT .. "/location_beacon.lua")

local function runController()
  local ok = shell.run(ROOT .. "/input_runtime.lua", table.unpack(args))
  if not ok then
    printError("NavRemote controller stopped because of an error.")
    print("Run this directly for the full error:")
    print(ROOT .. "/input_runtime.lua")
  end
end

local function runBeacon()
  local ok, err = pcall(Beacon.run)
  if not ok then
    printError("NavRemote location beacon failed: " .. tostring(err))
    while true do os.pullEvent() end
  end
end

parallel.waitForAny(runController, runBeacon)
