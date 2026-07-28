local ROOT = "/navremote"
local SOURCE = ROOT .. "/controller.lua"

local function readAll(path)
  local file = fs.open(path, "r")
  if not file then return nil, "Could not open " .. path end
  local value = file.readAll()
  file.close()
  return value
end

local function replacePlainOnce(text, needle, replacement)
  local first, last = text:find(needle, 1, true)
  if not first then return text, false end
  return text:sub(1, first - 1) .. replacement .. text:sub(last + 1), true
end

local source, err = readAll(SOURCE)
if not source then printError(err); return end

local additions = [[
local connectionState = { online=false, changed=nil, error=nil, latency=nil }

local function nowMs()
  return os.epoch and os.epoch("utc") or math.floor(os.clock()*1000)
end

local function ageText(ms)
  if not ms then return "unknown" end
  if ms < 1000 then return tostring(math.floor(ms)) .. "ms" end
  return string.format("%.1fs", ms / 1000)
end

local function loadBeaconStatus()
  local ok, value = pcall(dofile, ROOT .. "/data/beacon_status.lua")
  if ok and type(value) == "table" then return value end
end

local function connectionQuality(ms)
  if not ms then return "UNKNOWN", colors.lightGray end
  if ms <= 1500 then return "EXCELLENT", colors.lime end
  if ms <= 4000 then return "GOOD", colors.green end
  if ms <= 8000 then return "WEAK", colors.yellow end
  return "LOST", colors.red
end

local function discoverAircraft(channel)
  local found = {}
  local selfId = os.getComputerID and os.getComputerID() or nil
  local ok, result = pcall(rednet.lookup, channel or "cc-navtool")
  if not ok then return found end
  if type(result) == "number" then
    if not selfId or result ~= selfId then found[#found+1] = { id=result, host="navtool-aircraft" } end
  elseif type(result) == "table" then
    for key, value in pairs(result) do
      if type(key)=="string" and type(value)=="number" and (not selfId or value ~= selfId) then found[#found+1]={host=key,id=value}
      elseif type(key)=="number" and type(value)=="string" and (not selfId or key ~= selfId) then found[#found+1]={host=value,id=key} end
    end
  end
  table.sort(found,function(a,b) return tostring(a.host)<tostring(b.host) end)
  return found
end

local function chooseAircraft(channel)
  clear(colors.black); header("Discover aircraft")
  writeAt(3,3,"Scanning "..tostring(channel).."...",colors.cyan)
  local found=discoverAircraft(channel)
  if #found==0 then writeAt(3,5,"No aircraft found.",colors.yellow); waitBack(); return nil end
  for i,item in ipairs(found) do
    if i>12 then break end
    writeAt(3,i+4,tostring(i)..". "..tostring(item.host).."  ID "..tostring(item.id),colors.white)
  end
  footer("Number: import  Esc: back")
  while true do
    local _,key=os.pullEvent("key")
    if key==keys.escape then return nil end
    local index=key-keys.one+1
    if found[index] then return found[index] end
  end
end

local function chooseLocationRemote(title)
  local remotes, lastErr, tracking = {}, nil, nil
  local deadline = os.clock() + 8
  repeat
    local beaconStatus=loadBeaconStatus()
    local response,err=request("location-list")
    if response then remotes=response.remotes or {}; tracking=response.tracking else lastErr=err end
    clear(colors.black); header(title or "NavRemotes")
    writeAt(3,4,"Scanning for broadcasting NavRemotes...",colors.cyan)
    if tracking then
      writeAt(3,6,"Aircraft tracking: "..(tracking.enabled and "enabled" or "disabled"),tracking.enabled and colors.lime or colors.red)
      writeAt(3,7,"Aircraft modem: "..tostring(tracking.modem or "none"),tracking.hasWireless and colors.lime or colors.red)
      writeAt(3,8,"Port "..tostring(tracking.port).."  Heard "..tostring(tracking.received).."  Accepted "..tostring(tracking.accepted),colors.lightGray)
      writeAt(3,9,"Rejected key/host/channel: "..tostring(tracking.rejectedKey).."/"..tostring(tracking.rejectedHost).."/"..tostring(tracking.rejectedChannel),colors.lightGray)
      if beaconStatus then
        local age=nowMs()-(tonumber(beaconStatus.updated) or nowMs())
        writeAt(3,10,"Remote beacon: "..tostring(beaconStatus.reason or "unknown").." via "..tostring(beaconStatus.modem or "none").." ("..ageText(age).." ago)",beaconStatus.ok and colors.lime or colors.yellow)
      end
    else
      writeAt(3,6,"Remote beacon requires wireless/Ender modem and GPS.",colors.lightGray)
      writeAt(3,7,"Aircraft location tracking must be enabled.",colors.lightGray)
    end
    if #remotes>0 then break end
    sleep(0.5)
  until os.clock() >= deadline
  if lastErr and #remotes==0 then message=lastErr or "Location tracking unavailable"; return nil end
  clear(colors.black); header(title or "NavRemotes")
  if #remotes==0 then
    writeAt(3,4,"No broadcasting NavRemotes found.",colors.yellow)
    local beaconStatus=loadBeaconStatus()
    if tracking then
      writeAt(3,6,"Tracking: "..(tracking.enabled and "enabled" or "disabled").."  Modem: "..tostring(tracking.modem or "none"),colors.lightGray)
      writeAt(3,7,"Port "..tostring(tracking.port).."  Heard "..tostring(tracking.received).."  Accepted "..tostring(tracking.accepted),colors.lightGray)
      writeAt(3,8,"Rejected key/host/channel: "..tostring(tracking.rejectedKey).."/"..tostring(tracking.rejectedHost).."/"..tostring(tracking.rejectedChannel),colors.lightGray)
      if beaconStatus then
        local age=nowMs()-(tonumber(beaconStatus.updated) or nowMs())
        writeAt(3,9,"Remote beacon: "..tostring(beaconStatus.reason or "unknown").." via "..tostring(beaconStatus.modem or "none").." ("..ageText(age).." ago)",beaconStatus.ok and colors.lime or colors.yellow)
      end
    else
      writeAt(3,6,"Check beacon modem/GPS and navtool setup.",colors.lightGray)
    end
    waitBack(); return nil
  end
  local current=nowMs()
  for i,item in ipairs(remotes) do
    if i>12 then break end
    local age=current-(tonumber(item.seen) or current)
    local quality,color=connectionQuality(age)
    writeAt(3,i+3,tostring(i)..". "..tostring(item.label or item.id),colors.white)
    writeAt(28,i+3,quality,color)
    writeAt(39,i+3,ageText(age),colors.lightGray)
  end
  footer("Number: select  Esc: back")
  while true do
    local _,key=os.pullEvent("key")
    if key==keys.escape then return nil end
    local index=key-keys.one+1
    if remotes[index] then return remotes[index] end
  end
end
]]

local oldRequest = [[local function request(command, extra)
  local connection = profile()
  if not connection then return nil, "No aircraft selected" end
  local channel = connection.channel or "cc-navtool"
  local host = connection.host or "navtool-aircraft"
  local key = channel .. "\0" .. host
  local hostId = hostCache[key] or rednet.lookup(channel, host)
  if not hostId then return nil, "Aircraft offline" end
  local selfId = os.getComputerID and os.getComputerID() or nil
  if selfId and tonumber(hostId) == selfId then
    hostCache[key] = nil
    return nil, "NavRemote cannot control local NavTool; use another computer or NavTool UI"
  end
  hostCache[key] = hostId
  local payload = extra or {}
  payload.command, payload.key = command, connection.sharedKey or ""
  rednet.send(hostId, payload, channel)
  local sender, response = rednet.receive(channel, tonumber(connection.timeout) or 3)
  if sender ~= hostId or type(response) ~= "table" then hostCache[key] = nil; return nil, "No response" end
  if not response.ok then return nil, response.error or "Rejected" end
  return response
end]]

local fastRequest = [[local function request(command, extra)
  local connection = profile()
  if not connection then return nil, "No aircraft selected" end
  local channel = connection.channel or "cc-navtool"
  local host = connection.host or "navtool-aircraft"
  local key = channel .. "\0" .. host

  local function resolveHostId()
    local found = rednet.lookup(channel, host)
    if found then return found end
    local ok, result = pcall(rednet.lookup, channel)
    if ok and type(result) == "table" then
      for foundHost, foundId in pairs(result) do
        if tostring(foundHost) == tostring(host) and type(foundId) == "number" then return foundId end
      end
      local onlyId
      for _, foundId in pairs(result) do
        if type(foundId) == "number" then if onlyId then return nil end; onlyId = foundId end
      end
      return onlyId
    elseif ok and type(result) == "number" then
      return result
    end
  end

  -- Imported/discovered profiles already know the computer ID. Using it avoids a
  -- blocking rednet.lookup every time NavRemote starts.
  local hostId = hostCache[key] or tonumber(connection.computerId)
  if not hostId then
    hostId = resolveHostId()
    if hostId then
      connection.computerId = hostId
      saveConfig()
    end
  end
  if not hostId then return nil, "Aircraft offline" end
  local selfId = os.getComputerID and os.getComputerID() or nil
  if selfId and tonumber(hostId) == selfId then
    hostCache[key] = nil
    return nil, "NavRemote cannot control local NavTool; use another computer or NavTool UI"
  end
  hostCache[key] = hostId

  local payload = extra or {}
  payload.command, payload.key = command, connection.sharedKey or ""
  local timeout = tonumber(connection.timeout) or 3
  for attempt=1,2 do
    rednet.send(hostId, payload, channel)
    local sender, response = rednet.receive(channel, timeout)
    if sender == hostId and type(response) == "table" then
      if not response.ok then return nil, response.error or "Rejected" end
      return response
    end
    hostCache[key] = nil
    hostId = resolveHostId()
    if hostId then
      connection.computerId = hostId
      hostCache[key] = hostId
      saveConfig()
      if selfId and tonumber(hostId) == selfId then
        hostCache[key] = nil
        return nil, "NavRemote cannot control local NavTool; use another computer or NavTool UI"
      end
    elseif attempt == 1 then
      return nil, "Aircraft offline"
    end
  end
  return nil, "No response"
end]]

local requestReplaced
source,requestReplaced=replacePlainOnce(source,oldRequest,fastRequest)
if not requestReplaced then printError("NavRemote could not install fast request path."); return end

local anchor = "local function localData() return Storage.load(config.activeProfile or \"default\") end"
local count=0
local replaced
source,replaced=replacePlainOnce(source,anchor,additions.."\n"..anchor)
if replaced then count=count+1 end

local newRefresh = [[local function refresh(data,silent)
  local started=nowMs()
  local response,err = request("live-status")
  local wasOnline=connectionState.online
  if response then
    connectionState.online=true
    connectionState.error=nil
    connectionState.latency=nowMs()-started
    connectionState.changed=nowMs()
    data.lastStatus=response.data
    data.lastContact=nowMs()
    data.lastLatency=connectionState.latency
    if not wasOnline then Storage.log(data,"INFO","Aircraft connected") end
    if not silent then Storage.log(data,"INFO","Telemetry refreshed in "..ageText(connectionState.latency)) end
    saveData(data)
    return response.data
  end
  connectionState.online=false
  connectionState.error=err
  connectionState.changed=nowMs()
  if wasOnline then Storage.log(data,"WARN","Aircraft connection lost: "..tostring(err)) end
  if not silent then Storage.log(data,"WARN",err); saveData(data) end
  return data.lastStatus,err
end]]
source=source:gsub("local function refresh%(data,silent%).-\nend\n\nlocal function iconPosition",function(block)
  count=count+1
  return newRefresh.."\n\nlocal function iconPosition"
end,1)

local newModes = [[local function modesPage(data)
  local modes={"standby","navigate","hover","return-home"}
  clear(colors.black); header("Flight modes")
  for i,mode in ipairs(modes) do writeAt(4,i+3,tostring(i)..". "..mode,colors.white) end
  writeAt(4,9,"F. Follow a NavRemote",colors.cyan)
  writeAt(4,10,"H. Auto Home to NavRemote",colors.cyan)
  writeAt(4,11,"S. Stop following",colors.yellow)
  footer("1-4/F/H/S: activate  Esc: back")
  while true do
    local _,key=os.pullEvent("key")
    if key==keys.escape then return end
    local index=key-keys.one+1
    if modes[index] then
      local ok,e=request("set-mode",{mode=modes[index]})
      message=ok and ("Mode: "..modes[index]) or e
      Storage.log(data,ok and "INFO" or "WARN",message); saveData(data); return
    elseif key==keys.f then
      local remote=chooseLocationRemote("Follow NavRemote")
      if remote then
        local ok,e=request("follow-remote",{remote=remote.id})
        message=ok and ("Following "..tostring(remote.label or remote.id)) or e
        Storage.log(data,ok and "INFO" or "WARN",message); saveData(data)
      end
      return
    elseif key==keys.h then
      local remote=chooseLocationRemote("Auto Home")
      if remote then
        local ok,e=request("auto-home",{remote=remote.id})
        message=ok and ("Auto Home: "..tostring(remote.label or remote.id)) or e
        Storage.log(data,ok and "INFO" or "WARN",message); saveData(data)
      end
      return
    elseif key==keys.s then
      local ok,e=request("stop-follow")
      message=ok and "Follow stopped" or e
      Storage.log(data,ok and "INFO" or "WARN",message); saveData(data); return
    end
  end
end]]
source=source:gsub("local function modesPage%(%).-\nend\n\nlocal function manualPage",function()
  count=count+1
  return newModes.."\n\nlocal function manualPage"
end,1)

local newDashboard = [[local function dashboard(data)
  local response,err=request("status")
  local status=response and response.data or data.lastStatus
  clear(colors.black); header("Dashboard",err and "[ OFFLINE ]" or "[ SABLE ONLINE ]")
  status=status or {}; local p=status.position or {}; local v=status.velocity or {}
  local quality,qColor=connectionQuality(data.lastLatency)
  writeAt(3,3,"Aircraft",colors.cyan); writeAt(15,3,config.activeProfile or "none")
  writeAt(3,4,"Host",colors.cyan); writeAt(15,4,(profile() and profile().host) or "none")
  writeAt(3,5,"Link",colors.cyan); writeAt(15,5,err and "OFFLINE" or quality,err and colors.red or qColor)
  writeAt(29,5,"Ping "..ageText(data.lastLatency),colors.lightGray)
  writeAt(3,6,"Telemetry",colors.cyan); writeAt(15,6,status.telemetry and "ONLINE" or "OFFLINE",status.telemetry and colors.lime or colors.red)
  writeAt(3,7,"Source",colors.cyan); writeAt(15,7,tostring(status.source or "none"))
  writeAt(3,9,"Mode"); writeAt(15,9,status.mode or "unknown",colors.lime)
  local heading = status.heading
  local headingDeg = heading and heading.x and math.deg(math.atan2(heading.x, heading.z or 0))
  local headingText = headingDeg and (string.format("%.0f", headingDeg) .. " " .. degreesToCardinal(headingDeg)) or "n/a"
  writeAt(3,10,"Heading",colors.cyan); writeAt(15,10,headingText)
  writeAt(3,11,"Target"); writeAt(15,11,status.target and (status.target.name or "coords") or "none",colors.yellow)
  if status.target and status.target.dynamic and status.target.remoteId then
    writeAt(3,12,"Following"); writeAt(15,12,tostring(status.target.remoteId),colors.cyan)
  elseif status.target then
    local tx,ty,tz=tonumber(status.target.x) or 0,tonumber(status.target.y) or 0,tonumber(status.target.z) or 0
    writeAt(15,12,string.format("%.1f %.1f %.1f",tx,ty,tz),colors.lightGray)
  end
  if status.distanceToTarget then writeAt(3,13,"Distance",colors.cyan); writeAt(15,13,string.format("%.1f blocks",status.distanceToTarget)) end
  writeAt(3,15,"Position",colors.cyan)
  writeAt(3,16,string.format("X %8.1f",tonumber(p.x) or 0)); writeAt(18,16,string.format("Y %8.1f",tonumber(p.y) or 0)); writeAt(33,16,string.format("Z %8.1f",tonumber(p.z) or 0))
  writeAt(3,17,"Velocity",colors.cyan)
  writeAt(3,18,string.format("X %8.2f",tonumber(v.x) or 0)); writeAt(18,18,string.format("Y %8.2f",tonumber(v.y) or 0)); writeAt(33,18,string.format("Z %8.2f",tonumber(v.z) or 0))
  local active=status.activeSchedule
  if active then
    writeAt(3,20,"Active Schedule",colors.cyan)
    writeAt(18,20,tostring(active.name or "?").." stop "..tostring(active.index or 1),colors.lime)
  end
  writeAt(3,22,"Monitor",colors.cyan)
  writeAt(15,22,status.peripheral or status.sublevel or "none")
  local help="R: refresh  Esc: back"
  if active then help="S: skip  P: pause  R: refresh  X: stop  Esc: back" end
  footer(help)
  while true do
    local _,key=os.pullEvent("key")
    if key==keys.escape then return
    elseif key==keys.r then
      local s,e=refresh(data); if not s and e then message=e end; return dashboard(data)
    elseif key==keys.s and active then
      local r,e=request("skip-stop"); message=r and "Stop skipped" or e; return dashboard(data)
    elseif key==keys.p and active then
      local r,e=request("pause-schedule"); message=r and "Schedule paused" or e; return dashboard(data)
    elseif key==keys.x and active then
      local r,e=request("stop-schedule"); message=r and "Schedule stopped" or e; return dashboard(data)
    end
  end
end]]
source=source:gsub("local function dashboard%(data%).-\nend\n\nlocal function profilesPage",function()
  count=count+1
  return newDashboard.."\n\nlocal function profilesPage"
end,1)

local newProfiles = [[local function profilesPage()
  while true do
    clear(colors.black); header("Profiles")
    local names=Storage.names(config.profiles)
    for i,name in ipairs(names) do
      local marker=name==config.activeProfile and ">" or " "
      writeAt(3,i+3,marker.." "..tostring(i)..". "..name.."  "..tostring(config.profiles[name].host or ""),name==config.activeProfile and colors.lime or colors.white)
    end
    footer("Number: select  A:add  F:find  B:bind  E:edit  D:delete  Esc:back")
    local _,key=os.pullEvent("key")
    if key==keys.escape then return
    elseif key==keys.f then
      local channel=prompt("Discovery channel",(profile() and profile().channel) or "cc-navtool")
      local found=chooseAircraft(channel)
      if found then
        local name=prompt("Aircraft profile",found.host)
        local host=prompt("Aircraft host",found.host)
        local shared=prompt("Shared key","",true)
        config.profiles[name]={channel=channel,host=host,sharedKey=shared,timeout=3,computerId=found.id}
        config.activeProfile=name; saveConfig(); Storage.load(name); message="Imported "..host; return
      end
    elseif key==keys.b then
      local current=config.activeProfile
      if not current or not config.profiles[current] then message="No profile selected"
      else
        local channel=prompt("Discovery channel",config.profiles[current].channel or "cc-navtool")
        local found=chooseAircraft(channel)
        if found and confirm("Bind "..tostring(current).." to "..tostring(found.host)) then
          local host=prompt("Aircraft host",found.host)
          local shared=prompt("Shared key (blank keeps)","",true)
          local p=config.profiles[current]
          p.channel=channel; p.host=host; p.computerId=found.id
          if shared~="" then p.sharedKey=shared end
          saveConfig(); message="Rebound "..tostring(current).." to "..tostring(host); return
        end
      end
    elseif key==keys.a then
      local name=prompt("Aircraft name")
      if name and name~="" then
        config.profiles[name]={channel=prompt("Channel","cc-navtool"),host=prompt("Host","navtool-aircraft"),sharedKey=prompt("Shared key","",true),timeout=tonumber(prompt("Timeout","3")) or 3}
        config.activeProfile=name; saveConfig(); Storage.load(name); message="Added "..name; return
      end
    elseif key==keys.e then
      local name=prompt("Aircraft to edit",config.activeProfile)
      local p=config.profiles[name]
      if p then p.channel=prompt("Channel",p.channel or "cc-navtool"); p.host=prompt("Host",p.host or "navtool-aircraft"); local k=prompt("Shared key (blank keeps)","",true); if k~="" then p.sharedKey=k end; p.timeout=tonumber(prompt("Timeout",p.timeout or 3)) or 3; saveConfig() end
    elseif key==keys.d then
      local name=prompt("Aircraft to delete")
      if config.profiles[name] and confirm("Delete "..name) then config.profiles[name]=nil; if config.activeProfile==name then config.activeProfile=next(config.profiles) end; saveConfig(); return end
    else
      local index=key-keys.one+1
      if names[index] then config.activeProfile=names[index]; saveConfig(); selected=1; message="Selected "..names[index]; return end
    end
  end
end]]
source=source:gsub("local function profilesPage%(%).-\nend\n\nlocal function logsPage",function()
  count=count+1
  return newProfiles.."\n\nlocal function logsPage"
end,1)

source=source:gsub("modesPage%(%)", "modesPage(data)")

if count < 4 then
  printError("NavRemote pre-test patch failed: expected at least 4 sections, found "..tostring(count))
  return
end

local program,loadErr=load(source,"@"..SOURCE,"t",_ENV)
if not program then printError("Could not load NavRemote: "..tostring(loadErr)); return end
return program(...)
