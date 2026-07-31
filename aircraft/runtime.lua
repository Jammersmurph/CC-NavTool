-- CC-NavTool compatibility runtime
-- Keeps the existing command surface intact while routing automation calculations
-- through the Sable-native controller and launching the headless service by default.

local ROOT = "/navtool"
local SOURCE_PATH = ROOT .. "/navtool.lua"
local runtimeArgs = { ... }

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

-- Open every modem visible through the local peripheral bus and wired modem LAN
-- before NavTool starts. The legacy openModem helper may return after inspecting one
-- modem, but all wired, wireless, and Ender interfaces are already active by then.
local openedModems = {}
for _, name in ipairs(peripheral.getNames()) do
  local isModem = false
  if type(peripheral.hasType) == "function" then
    local ok, result = pcall(peripheral.hasType, name, "modem")
    isModem = ok and result == true
  end
  if not isModem then
    local ok, result = pcall(peripheral.getType, name)
    if ok then
      if type(result) == "table" then
        for _, kind in ipairs(result) do
          if kind == "modem" then isModem = true; break end
        end
      else
        isModem = result == "modem"
      end
    end
  end
  if isModem then
    local alreadyOpen = false
    local checkOk, checkValue = pcall(rednet.isOpen, name)
    if checkOk then alreadyOpen = checkValue == true end
    local opened = alreadyOpen
    if not opened then opened = pcall(rednet.open, name) end
    if opened then openedModems[#openedModems + 1] = name end
  end
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
source = source:gsub("local args = %{%s*%.%.%.%s*%}", "local args = __navtoolRuntimeArgs or {}", 1)

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
  "local requested, notes = automationOutputs%(config, state%)",
  function()
    replacements = replacements + 1
    return "local requested, notes = integratedAutomationOutputs(config, state, automationOutputs)"
  end,
  2
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

local LocationPatch = dofile(ROOT .. "/location_patch.lua")
local locationReplacements
source, locationReplacements = LocationPatch.apply(source)
replacements = replacements + locationReplacements

if replacements < 15 then
  printError("CC-NavTool runtime compatibility check failed.")
  printError("Expected at least 15 integration points, found " .. tostring(replacements) .. ".")
  printError("Refusing to run a partially patched flight controller.")
  return
end

_G.__navtoolRuntimeArgs = runtimeArgs
local program, loadErr = load(source, "@" .. SOURCE_PATH, "t", _ENV)
if not program then printError("Could not load navtool: " .. tostring(loadErr)); return end

return program()
