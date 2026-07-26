local ROOT = "/navremote"
local args = { ... }
local Beacon = dofile(ROOT .. "/location_beacon.lua")

parallel.waitForAny(
  function() return shell.run(ROOT .. "/ui_runtime.lua", table.unpack(args)) end,
  function() return Beacon.run() end
)
