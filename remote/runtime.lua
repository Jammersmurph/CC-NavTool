local ROOT = "/navremote"
local args = { ... }
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
