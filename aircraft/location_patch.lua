local Patch = {}

function Patch.apply(source)
  local count = 0

  source = source:gsub("local IntegratedControl = dofile%(ROOT %.%. \"/lib/control_core%.lua\"%)", function()
    count = count + 1
    return "local IntegratedControl = dofile(ROOT .. \"/lib/control_core.lua\")\nlocal LocationNetwork = dofile(ROOT .. \"/location_network.lua\")\nlocal Hardware = dofile(ROOT .. \"/hardware.lua\")\nHardware.installRedstoneProxy()"
  end, 1)

  source = source:gsub("  config%.onboardingComplete = true", function()
    count = count + 1
    return [[  config.locationTracking = type(config.locationTracking) == "table" and config.locationTracking or {}
  if enable then
    print("")
    print("Optional location tracking enables Follow and Auto Home.")
    print("A wireless or Ender modem and GPS coverage are required.")
    config.locationTracking.enabled = promptYesNo("Enable NavRemote location tracking", config.locationTracking.enabled == true)
    if config.locationTracking.enabled then
      config.locationTracking.port = tonumber(prompt(config.locationTracking.port or 9999, "Location port")) or 9999
      config.locationTracking.timeout = tonumber(prompt(config.locationTracking.timeout or 12, "Remote timeout seconds")) or 12
    end
  else
    config.locationTracking.enabled = false
  end
  config.onboardingComplete = true]]
  end, 1)

  source = source:gsub('        if request%.command == "ping" then', function()
    count = count + 1
    return [[        if request.command == "hardware-list" then
          local description = Hardware.describe(config)
          description.modes = description.modes or {}
          description.modes.airship = type(config.hardware) == "table" and config.hardware.airshipMode == true
          response = { ok = true, hardware = description }
        elseif request.command == "hardware-assign" then
          local okAssign, result = Hardware.assign(config, request)
          if okAssign then
            saveConfig(config)
            response = { ok = true, assignment = result, hardware = Hardware.describe(config) }
          else
            response = { ok = false, error = result }
          end
        elseif request.command == "hardware-unassign" then
          local okUnassign, result = Hardware.unassign(config, request)
          if okUnassign then
            saveConfig(config)
            response = { ok = true, assignment = result, hardware = Hardware.describe(config) }
          else
            response = { ok = false, error = result }
          end
        elseif request.command == "hardware-test" then
          local okTest, result = Hardware.test(config, request.control, request.strength)
          response = okTest and { ok = true } or { ok = false, error = result }
        elseif request.command == "hardware-mode" then
          config.hardware = type(config.hardware) == "table" and config.hardware or {}
          if tostring(request.mode or "") == "airship" then
            config.hardware.airshipMode = request.enabled == true
            saveConfig(config)
            local description = Hardware.describe(config)
            description.modes = description.modes or {}
            description.modes.airship = config.hardware.airshipMode == true
            response = { ok = true, hardware = description }
          else
            response = { ok = false, error = "invalid hardware mode" }
          end
        elseif request.command == "location-list" then
          response = { ok = true, remotes = LocationNetwork.list(), following = LocationNetwork.following(), tracking = LocationNetwork.status() }
        elseif request.command == "follow-remote" then
          local okFollow, result = LocationNetwork.follow(request.remote)
          response = okFollow and { ok = true, remote = result, following = result.id } or { ok = false, error = result }
        elseif request.command == "auto-home" then
          local okHome, result = LocationNetwork.autoHome(request.remote)
          response = okHome and { ok = true, remote = result } or { ok = false, error = result }
        elseif request.command == "stop-follow" then
          LocationNetwork.stopFollow()
          response = { ok = true }
        elseif request.command == "ping" then]]
  end, 1)

  source = source:gsub('elseif request%.command == "set%-target" and type%(request%.target%) == "table" then\n          saveTarget%(request%.target%)', function()
    count = count + 1
    return [[elseif request.command == "set-target" and type(request.target) == "table" then
          LocationNetwork.stopFollow()
          saveActiveSchedule(nil)
          saveTarget(request.target)]]
  end, 1)

  source = source:gsub("local function interface%(config%)", function()
    count = count + 1
    return [[local function runService(config, debug)
  LocationNetwork.configure(config, {
    setTarget = function(remote, continuous)
      saveTarget({
        name = (continuous and "Follow " or "Home to ") .. tostring(remote.label or remote.id),
        x = remote.x, y = remote.y, z = remote.z,
        remoteId = remote.id,
        dynamic = continuous == true,
      })
      saveMode("navigate")
    end,
  })
  if config.network and config.network.enabled and config.locationTracking and config.locationTracking.enabled then
    parallel.waitForAny(
      function() server(config, debug) end,
      function() LocationNetwork.run() end
    )
  else
    server(config, debug)
  end
end

local function interface(config)]]
  end, 1)

  source = source:gsub('elseif command == "server" then server%(config, args%[2%] == "debug"%)', function()
    count = count + 1
    return 'elseif command == "server" then runService(config, args[2] == "debug")'
  end, 1)

  source = source:gsub('elseif command == "ui" or command == "run" then server%(config, args%[2%] == "debug"%)', function()
    count = count + 1
    return 'elseif command == "ui" or command == "run" then runService(config, args[2] == "debug")'
  end, 1)

  return source, count
end

return Patch
