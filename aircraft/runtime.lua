-- CC-NavTool compatibility runtime
-- Keeps the existing command surface intact while routing automation calculations
-- through the Sable-native controller and launching the headless service by default.

local ROOT = "/navtool"
local SOURCE_PATH = ROOT .. "/navtool.lua"

-- CC: Sable is a hard runtime requirement. Load its API into the global namespace
-- before navtool and the integrated controller start.
if type(rawget(_G, "sublevel")) ~= "table" then
  local ok, api = pcall(require, "rom/apis/sublevel")
  if ok and type(api) == "table" then _G.sublevel = api end
end

if type(rawget(_G, "sublevel")) ~= "table" then
  printError("CC-NavTool requires CC: Sable's sublevel API.")
  printError("Could not load rom/apis/sublevel; flight control will not start.")
  return
end

local function readAll(path)
  local file = fs.open(path, "r")
  if not file then return nil, "Could not open " .. path end
  local value = file.readAll()
  file.close()
  return value
end

local source, err = readAll(SOURCE_PATH)
if not source then printError(err); return end

local anchor = "local lastGpsFix\n"
local injection = [[local lastGpsFix
local IntegratedControl = dofile(ROOT .. "/lib/control_core.lua")
local PrecisionDirector = dofile(ROOT .. "/lib/flight_director.lua")
local integratedController

local function integratedAutomationOutputs(config, state, fallback)
  if type(config.flightControl) == "table" and config.flightControl.enabled == false then
    return fallback(config, state)
  end

  -- Integrated navigation is intentionally Sable-only. Create: Avionics may still
  -- contribute diagnostics, but it cannot satisfy the flight-control telemetry contract.
  if state.sublevel ~= true or type(state.pose) ~= "table" or type(state.position) ~= "table" then
    return {
      forward = 0, reverse = 0, left = 0,
      right = 0, up = 0, down = 0,
    }, { "CC: Sable pose unavailable; outputs inhibited" }
  end

  if not integratedController then integratedController = IntegratedControl.new(config) end
  local outputs, notes, handled = integratedController:outputs(state)
  if handled then return outputs or {}, notes or {} end

  -- Do not fall back to GPS, generic peripherals, or Avionics-driven automation.
  return {
    forward = 0, reverse = 0, left = 0,
    right = 0, up = 0, down = 0,
  }, notes or { "Sable flight state incomplete; outputs inhibited" }
end

local function exactPositionReached(config, state, target)
  local reached = PrecisionDirector.arrivalStatus(state, target or state.target, config)
  return reached == true
end
]]

local replacements = 0
source = source:gsub(anchor, function()
  replacements = replacements + 1
  return injection
end, 1)

source = source:gsub(
  "local requested = automationOutputs%(config, state%)",
  function()
    replacements = replacements + 1
    return "local requested = integratedAutomationOutputs(config, state, automationOutputs)"
  end,
  1
)

source = source:gsub(
  "local requested, notes = automationOutputs%(config, state%)",
  function()
    replacements = replacements + 1
    return "local requested, notes = integratedAutomationOutputs(config, state, automationOutputs)"
  end,
  1
)

source = source:gsub(
  "state%.distanceToTarget and state%.distanceToTarget <= arrivalRadius",
  function()
    replacements = replacements + 1
    return "exactPositionReached(config, state, state.target)"
  end
)

-- The original automation smoother intentionally extends short output pulses. That
-- behavior is useful for the legacy controller, but it defeats rapid PID corrections
-- near a precision target. Only disable it while the integrated controller is enabled.
source = source:gsub(
  "local holdAfter = tonumber%(automation%.outputHoldAfter%) or 0%.6",
  function()
    replacements = replacements + 1
    return "local holdAfter = (type(config.flightControl) == 'table' and config.flightControl.enabled ~= false) and 0 or (tonumber(automation.outputHoldAfter) or 0.6)"
  end,
  1
)
source = source:gsub(
  "local pulseReleaseGrace = tonumber%(automation%.outputPulseReleaseGrace%) or 0%.25",
  function()
    replacements = replacements + 1
    return "local pulseReleaseGrace = (type(config.flightControl) == 'table' and config.flightControl.enabled ~= false) and 0 or (tonumber(automation.outputPulseReleaseGrace) or 0.25)"
  end,
  1
)
source = source:gsub(
  "local holdReleaseGrace = tonumber%(automation%.outputHoldReleaseGrace%) or 1%.0",
  function()
    replacements = replacements + 1
    return "local holdReleaseGrace = (type(config.flightControl) == 'table' and config.flightControl.enabled ~= false) and 0 or (tonumber(automation.outputHoldReleaseGrace) or 1.0)"
  end,
  1
)

-- Plain `navtool` is the canonical headless-service launcher. Keep `navtool server`
-- as a compatibility alias and route the old UI aliases to the same service.
source = source:gsub(
  'local command = %(args%[1%] or "ui"%):lower%(%)',
  function()
    replacements = replacements + 1
    return 'local command = (args[1] or "server"):lower()'
  end,
  1
)
source = source:gsub(
  'elseif command == "ui" or command == "run" then interface%(config%)',
  function()
    replacements = replacements + 1
    return 'elseif command == "ui" or command == "run" then server(config, args[2] == "debug")'
  end,
  1
)

-- Networking may be disabled during first-run setup. In that case NavTool still runs
-- the local flight service and automation loop; it simply does not expose Rednet.
source = source:gsub(
  'if not config%.network or not config%.network%.enabled then\n    printError%("Networking is disabled in /navtool/config%.lua"%)\n    return\n  end',
  function()
    replacements = replacements + 1
    return [[if not config.network or not config.network.enabled then
    print("navtool local flight service online")
    print("Remote networking: disabled")
    local interval = math.max(0.05, tonumber(config.updateInterval) or 0.05)
    while true do
      serverAutomationTick(config)
      sleep(interval)
    end
  end]]
  end,
  1
)

if replacements ~= 11 then
  printError("CC-NavTool runtime compatibility check failed.")
  printError("Expected 11 integration points, found " .. tostring(replacements) .. ".")
  printError("Refusing to run a partially patched flight controller.")
  return
end

local program, loadErr = load(source, "@" .. SOURCE_PATH, "t", _ENV)
if not program then printError("Could not load navtool: " .. tostring(loadErr)); return end

return program(...)
