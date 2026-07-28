-- CC-NavTool v0.5.1-nightly
local VERSION = "0.5.1-nightly"
local ROOT = "/navtool"
local CONFIG_PATH = ROOT .. "/config.lua"
local STATE_PATH = ROOT .. "/state.lua"
local REPO_RAW = "https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/main/"
local args = { ... }

local function ensureDirectory(path) if not fs.exists(path) then fs.makeDir(path) end end
local function loadConfig()
  if not fs.exists(CONFIG_PATH) then return nil, "Configuration missing. Run: navtool configure" end
  local ok, config = pcall(dofile, CONFIG_PATH)
  if not ok or type(config) ~= "table" then return nil, "Could not load config: " .. tostring(config) end
  return config
end
local function loadState()
  if not fs.exists(STATE_PATH) then return { engaged=false, target=nil } end
  local ok, state = pcall(dofile, STATE_PATH)
  if ok and type(state) == "table" then return state end
  return { engaged=false, target=nil }
end
local function saveState(state)
  local file = assert(fs.open(STATE_PATH, "w"))
  file.write("return " .. textutils.serialize(state) .. "\n")
  file.close()
end
local function clearOutputs(config)
  if not config or type(config.outputs) ~= "table" then return end
  local cleared = {}
  for _, output in pairs(config.outputs) do
    if type(output)=="table" and output.side and not cleared[output.side] then
      pcall(redstone.setAnalogOutput, output.side, 0)
      pcall(redstone.setOutput, output.side, false)
      cleared[output.side]=true
    end
  end
end
local function getMethods(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  return ok and type(methods)=="table" and methods or {}
end
local function contains(list, value) for _, item in ipairs(list) do if item==value then return true end end return false end
local function discoverTelemetry(config)
  if config.telemetryPeripheral and peripheral.isPresent(config.telemetryPeripheral) then return config.telemetryPeripheral end
  for _, name in ipairs(peripheral.getNames()) do
    local methods=getMethods(name)
    if contains(methods,"getLogicalPose") or (contains(methods,"getLinearVelocity") and contains(methods,"getAngularVelocity")) then return name end
  end
end
local function callFirst(name, methods)
  if not name then return nil end
  for _, method in ipairs(methods) do local ok,value=pcall(peripheral.call,name,method); if ok and value~=nil then return value,method end end
end
local function formatValue(value, depth)
  depth=depth or 0; if depth>2 then return "..." end
  if type(value)~="table" then return tostring(value) end
  local parts={}; for k,v in pairs(value) do parts[#parts+1]=tostring(k).."="..formatValue(v,depth+1) end
  table.sort(parts); return "{"..table.concat(parts,", ").."}"
end
local function extractPosition(pose)
  if type(pose)~="table" then return nil end
  local p=pose.position or pose.pos or pose.translation or pose
  if type(p)=="table" and tonumber(p.x or p[1]) and tonumber(p.y or p[2]) and tonumber(p.z or p[3]) then
    return {x=tonumber(p.x or p[1]),y=tonumber(p.y or p[2]),z=tonumber(p.z or p[3])}
  end
end
local function openWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name,"modem") then
      local modem=peripheral.wrap(name); local ok,wireless=pcall(modem.isWireless)
      if ok and wireless then if not rednet.isOpen(name) then rednet.open(name) end return name end
    end
  end
end
local function applyOutput(config, control, strength)
  local output=config.outputs and config.outputs[control]
  if type(output)~="table" or not output.side then return false,"Unknown/unconfigured control" end
  local max=math.min(config.safety.maximumOutput or 5, output.maximum or 15)
  strength=math.max(0,math.min(max,math.floor(tonumber(strength) or 0)))
  if output.inverted then strength=max-strength end
  if output.analog==false then redstone.setOutput(output.side,strength>0) else redstone.setAnalogOutput(output.side,strength) end
  return true
end
local function telemetryStatus(config, state)
  local telemetry=discoverTelemetry(config); local pose=callFirst(telemetry,{"getLogicalPose","getPose"})
  return {host=config.network and config.network.host, engaged=state.engaged, target=state.target, telemetry=telemetry, position=extractPosition(pose), pose=pose}
end
local function remoteServer(config)
  local net=config.network or {}
  if net.enabled==false then error("Networking is disabled in config",0) end
  if not openWirelessModem() then error("No wireless modem found",0) end
  local channel=net.channel or net.protocol or "cc-navtool"; local host=net.host or "navtool-aircraft"
  rednet.host(channel,host)
  local state=loadState(); print("CC-NavTool remote server online"); print("Host: "..host); print("Channel: "..channel); print("Press Ctrl+T to stop.")
  while true do
    local sender,msg=rednet.receive(channel)
    if type(msg)=="table" and msg.type=="navtool_request" then
      local response={type="navtool_response",ok=false}
      if msg.key~=(net.sharedKey or "change-me") then response.error="Authentication failed"
      else
        local cmd=msg.command; local data=type(msg.data)=="table" and msg.data or {}
        if cmd=="status" or cmd=="ping" then response.ok=true; response.data=telemetryStatus(config,state)
        elseif cmd=="set_target" then
          local x,y,z=tonumber(data.x),tonumber(data.y),tonumber(data.z)
          if x and y and z then state.target={x=x,y=y,z=z,name=data.name}; saveState(state); response.ok=true; response.data=state.target else response.error="Invalid coordinates" end
        elseif cmd=="clear_target" then state.target=nil; state.engaged=false; saveState(state); clearOutputs(config); response.ok=true
        elseif cmd=="engage" then if state.target then state.engaged=true; saveState(state); response.ok=true else response.error="Set a target first" end
        elseif cmd=="disengage" or cmd=="stop" then state.engaged=false; saveState(state); clearOutputs(config); response.ok=true
        elseif cmd=="manual" then
          state.engaged=false; saveState(state)
          local duration=math.max(0.05,math.min(config.safety.maximumRemotePulse or 2,tonumber(data.duration) or 0.25))
          local ok,err=applyOutput(config,tostring(data.control or ""),data.strength)
          if ok then sleep(duration); clearOutputs(config); response.ok=true else response.error=err end
        else response.error="Unknown command" end
      end
      rednet.send(sender,response,channel)
    end
  end
end
local function printHelp()
  print("CC-NavTool "..VERSION); print("Usage: navtool [command]"); print("  status       Inspect telemetry"); print("  server       Run wireless aircraft server"); print("  configure    Install/reset config"); print("  update       Update from GitHub"); print("  outputs-off  Emergency output clear"); print("  version      Show version")
end
local function configure()
  ensureDirectory(ROOT)
  if fs.exists(CONFIG_PATH) then write("Replace existing config? [y/N] "); local a=read():lower(); if a~="y" and a~="yes" then return end end
  local response,err=http.get(REPO_RAW.."config.example.lua"); if not response then error("Download failed: "..tostring(err),0) end
  local file=assert(fs.open(CONFIG_PATH,"w")); file.write(response.readAll()); file.close(); response.close(); print("Created "..CONFIG_PATH)
end
local function status(config)
  local state=loadState(); local s=telemetryStatus(config,state)
  print("CC-NavTool "..VERSION); print("Computer ID: "..os.getComputerID()); print("Telemetry: "..tostring(s.telemetry or "not found")); print("Engaged: "..tostring(s.engaged)); print("Target: "..formatValue(s.target)); print("Position: "..formatValue(s.position)); if s.telemetry then print("Methods: "..table.concat(getMethods(s.telemetry),", ")) end
end
local function dashboard(config)
  while true do term.clear(); term.setCursorPos(1,1); status(config); print(""); print("Telemetry/remote nightly build"); print("Press Q to exit"); local timer=os.startTimer(config.updateInterval or 0.5); local event,p=os.pullEvent(); if event=="key" and p==keys.q then clearOutputs(config); return elseif event~="timer" then os.cancelTimer(timer) end end
end

local command=(args[1] or "run"):lower(); ensureDirectory(ROOT)
if command=="help" or command=="--help" or command=="-h" then printHelp()
elseif command=="version" or command=="--version" or command=="-v" then print(VERSION)
elseif command=="configure" or command=="config" then configure()
elseif command=="update" then shell.run(ROOT.."/update.lua")
else
  local config,err=loadConfig(); if not config then printError(err); return end
  if command=="status" then status(config)
  elseif command=="server" then remoteServer(config)
  elseif command=="outputs-off" or command=="stop" then local state=loadState(); state.engaged=false; saveState(state); clearOutputs(config); print("Outputs cleared and navigation disengaged.")
  elseif command=="run" then dashboard(config)
  else printError("Unknown command: "..command); printHelp() end
end
