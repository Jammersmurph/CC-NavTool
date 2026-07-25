-- CC-NavTool v0.1.0-alpha
local VERSION = "0.1.0-alpha"
local ROOT = "/navtool"
local CONFIG_PATH = ROOT .. "/config.lua"
local REPO_RAW = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/main/"

local args = { ... }

local function ensureDirectory(path)
  if not fs.exists(path) then fs.makeDir(path) end
end

local function loadConfig()
  if not fs.exists(CONFIG_PATH) then
    return nil, "Configuration missing. Run: navtool configure"
  end
  local ok, config = pcall(dofile, CONFIG_PATH)
  if not ok then return nil, "Could not load config: " .. tostring(config) end
  if type(config) ~= "table" then return nil, "Config must return a table." end
  return config
end

local function clearOutputs(config)
  if not config or type(config.outputs) ~= "table" then return end
  local cleared = {}
  for _, output in pairs(config.outputs) do
    if type(output) == "table" and output.side and not cleared[output.side] then
      pcall(redstone.setAnalogOutput, output.side, 0)
      pcall(redstone.setOutput, output.side, false)
      cleared[output.side] = true
    end
  end
end

local function getMethods(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if ok and type(methods) == "table" then return methods end
  return {}
end

local function contains(list, value)
  for _, item in ipairs(list) do if item == value then return true end end
  return false
end

local function discoverTelemetry(config)
  if config and config.telemetryPeripheral and peripheral.isPresent(config.telemetryPeripheral) then
    return config.telemetryPeripheral
  end
  for _, name in ipairs(peripheral.getNames()) do
    local methods = getMethods(name)
    if contains(methods, "getLogicalPose") or
       (contains(methods, "getLinearVelocity") and contains(methods, "getAngularVelocity")) then
      return name
    end
  end
  return nil
end

local function callFirst(name, methodNames)
  for _, method in ipairs(methodNames) do
    local ok, value = pcall(peripheral.call, name, method)
    if ok and value ~= nil then return value, method end
  end
  return nil
end

local function formatValue(value, depth)
  depth = depth or 0
  if depth > 2 then return "..." end
  if type(value) ~= "table" then return tostring(value) end
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = tostring(key) .. "=" .. formatValue(item, depth + 1)
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function printHelp()
  print("CC-NavTool " .. VERSION)
  print("Usage: navtool [command]")
  print("")
  print("Commands:")
  print("  help        Show this help")
  print("  version     Show installed version")
  print("  status      Inspect CC:Sable telemetry")
  print("  configure   Create or reset the default config")
  print("  update      Download the latest release from GitHub")
  print("  outputs-off Clear all configured redstone outputs")
  print("")
  print("Running without a command opens the telemetry dashboard.")
end

local function configure()
  ensureDirectory(ROOT)
  if fs.exists(CONFIG_PATH) then
    write("Replace existing config? [y/N] ")
    local answer = read()
    if answer:lower() ~= "y" and answer:lower() ~= "yes" then
      print("Configuration unchanged.")
      return
    end
  end
  local response, err = http.get(REPO_RAW .. "config.example.lua")
  if not response then error("Download failed: " .. tostring(err), 0) end
  local body = response.readAll()
  response.close()
  local file = fs.open(CONFIG_PATH, "w")
  file.write(body)
  file.close()
  print("Created " .. CONFIG_PATH)
  print("Edit it with: edit " .. CONFIG_PATH)
end

local function status(config)
  local telemetry = discoverTelemetry(config)
  print("CC-NavTool " .. VERSION)
  print("Computer ID: " .. os.getComputerID())
  print("Telemetry: " .. (telemetry or "not found"))
  if not telemetry then
    print("Attach/mount the computer to a CC:Sable-enabled craft, then retry.")
    return false
  end
  print("Peripheral type: " .. table.concat({ peripheral.getType(telemetry) }, ", "))
  print("Methods: " .. table.concat(getMethods(telemetry), ", "))
  local pose, poseMethod = callFirst(telemetry, { "getLogicalPose", "getPose" })
  local linear, linearMethod = callFirst(telemetry, { "getLinearVelocity", "getVelocity" })
  local angular, angularMethod = callFirst(telemetry, { "getAngularVelocity" })
  local mass, massMethod = callFirst(telemetry, { "getMass" })
  if pose then print((poseMethod or "pose") .. ": " .. formatValue(pose)) end
  if linear then print((linearMethod or "velocity") .. ": " .. formatValue(linear)) end
  if angular then print((angularMethod or "angular") .. ": " .. formatValue(angular)) end
  if mass then print((massMethod or "mass") .. ": " .. formatValue(mass)) end
  return true
end

local function dashboard(config)
  local telemetry = discoverTelemetry(config)
  if not telemetry then
    status(config)
    return
  end
  local old = term.current()
  local monitor = config.monitorPeripheral and peripheral.wrap(config.monitorPeripheral) or peripheral.find("monitor")
  if monitor then
    monitor.setTextScale(0.5)
    term.redirect(monitor)
  end
  local running = true
  local function draw()
    while running do
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.white)
      term.clear()
      term.setCursorPos(1, 1)
      print("CC-NavTool " .. VERSION)
      print("Telemetry: " .. telemetry)
      print("")
      local pose = callFirst(telemetry, { "getLogicalPose", "getPose" })
      local linear = callFirst(telemetry, { "getLinearVelocity", "getVelocity" })
      local angular = callFirst(telemetry, { "getAngularVelocity" })
      print("Pose: " .. formatValue(pose))
      print("Velocity: " .. formatValue(linear))
      print("Angular: " .. formatValue(angular))
      print("")
      print("Telemetry-only alpha build")
      print("Press Q to exit")
      sleep(config.updateInterval or 0.1)
    end
  end
  local function input()
    while running do
      local _, key = os.pullEvent("key")
      if key == keys.q then running = false end
    end
  end
  local ok, err = pcall(parallel.waitForAny, draw, input)
  term.redirect(old)
  clearOutputs(config)
  if not ok then error(err, 0) end
end

local command = (args[1] or "run"):lower()
ensureDirectory(ROOT)

if command == "help" or command == "--help" or command == "-h" then
  printHelp()
elseif command == "version" or command == "--version" or command == "-v" then
  print(VERSION)
elseif command == "configure" or command == "config" then
  configure()
elseif command == "update" then
  shell.run(ROOT .. "/update.lua")
else
  local config, err = loadConfig()
  if not config then
    printError(err)
    print("Run: navtool configure")
    return
  end
  if command == "status" then
    status(config)
  elseif command == "outputs-off" or command == "stop" then
    clearOutputs(config)
    print("Configured redstone outputs cleared.")
  elseif command == "run" then
    dashboard(config)
  else
    printError("Unknown command: " .. command)
    printHelp()
  end
end
