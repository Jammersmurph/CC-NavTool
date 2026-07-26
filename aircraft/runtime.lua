-- CC-NavTool compatibility runtime
-- Keeps the existing navtool UI and command surface intact while routing
-- automation calculations through the Avionics-native controller when possible.

local ROOT = "/navtool"
local SOURCE_PATH = ROOT .. "/navtool.lua"

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
  if not integratedController then integratedController = IntegratedControl.new(config) end
  local outputs, notes, handled = integratedController:outputs(state)
  if handled then return outputs or {}, notes or {} end
  return fallback(config, state)
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

if replacements ~= 8 then
  printError("CC-NavTool runtime compatibility check failed.")
  printError("Expected 8 integration points, found " .. tostring(replacements) .. ".")
  printError("Refusing to run a partially patched flight controller.")
  return
end

local program, loadErr = load(source, "@" .. SOURCE_PATH, "t", _ENV)
if not program then printError("Could not load navtool: " .. tostring(loadErr)); return end

return program(...)
