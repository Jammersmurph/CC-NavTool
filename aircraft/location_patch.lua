local Patch = {}

function Patch.apply(source)
  local count = 0

  source = source:gsub("local IntegratedControl = dofile%(ROOT %.%. \"/lib/control_core%.lua\"%)", function()
    count = count + 1
    return "local IntegratedControl = dofile(ROOT .. \"/lib/control_core.lua\")\nlocal LocationNetwork = dofile(ROOT .. \"/location_network.lua\")"
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
    return [[        if request.command == "location-list" then
          response = { ok = true, remotes = LocationNetwork.list(), following = LocationNetwork.following() }
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
