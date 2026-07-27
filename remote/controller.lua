local VERSION = "0.4.0-alpha"
local ROOT = "/navremote"
local CONFIG_PATH = ROOT .. "/config.lua"
local Storage = dofile(ROOT .. "/storage.lua")

local config = dofile(CONFIG_PATH)
config.profiles = type(config.profiles) == "table" and config.profiles or {}
config.activeProfile = config.activeProfile or next(config.profiles)
local hostCache, selected, message = {}, 1, ""

local icons = {
  { id="dashboard", label="Dashboard", glyph={"#####","#.#.#","#####"} },
  { id="targets", label="Targets", glyph={"..#..","#####","..#.."} },
  { id="routes", label="Routes", glyph={"#....",".###.","....#"} },
  { id="schedules", label="Schedules", glyph={"#####","#.#.#","#####"} },
  { id="modes", label="Modes", glyph={"..#..",".###.","#####"} },
  { id="manual", label="Manual", glyph={".#.#.","#####",".#.#."} },
  { id="profiles", label="Profiles", glyph={"#...#",".###.","#...#"} },
  { id="logs", label="Logs", glyph={"####.","#....","#####"} },
  { id="settings", label="Settings", glyph={".#.#.","#####",".#.#."} },
}

local function saveConfig()
  local f = fs.open(CONFIG_PATH, "w")
  if not f then return false end
  f.write("return " .. textutils.serialize(config) .. "\n")
  f.close()
  return true
end

local function profile() return config.profiles[config.activeProfile] end

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return true
    end
  end
  return false
end

local function request(command, extra)
  local connection = profile()
  if not connection then return nil, "No aircraft selected" end
  local channel = connection.channel or "cc-navtool"
  local host = connection.host or "navtool-aircraft"
  local key = channel .. "\0" .. host
  local hostId = hostCache[key] or rednet.lookup(channel, host)
  if not hostId then return nil, "Aircraft offline" end
  hostCache[key] = hostId
  local payload = extra or {}
  payload.command, payload.key = command, connection.sharedKey or ""
  rednet.send(hostId, payload, channel)
  local sender, response = rednet.receive(channel, tonumber(connection.timeout) or 3)
  if sender ~= hostId or type(response) ~= "table" then hostCache[key] = nil; return nil, "No response" end
  if not response.ok then return nil, response.error or "Rejected" end
  return response
end

local function localData() return Storage.load(config.activeProfile or "default") end
local function saveData(data) return Storage.save(config.activeProfile or "default", data) end

local function clear(bg)
  term.setBackgroundColor(bg or colors.green)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1,1)
end

local function fill(x,y,w,h,bg)
  term.setBackgroundColor(bg)
  for row=y,y+h-1 do term.setCursorPos(x,row); term.write(string.rep(" ",w)) end
end

local function writeAt(x,y,text,fg,bg)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.setCursorPos(x,y)
  term.write(tostring(text))
end

local function header(title,status)
  local w = term.getSize()
  fill(1,1,w,1,colors.gray)
  writeAt(2,1,"NavRemote " .. VERSION,colors.white,colors.gray)
  if title and title ~= "" then writeAt(22,1,title,colors.lightGray,colors.gray) end
  local right = status or tostring(config.activeProfile or "NO AIRCRAFT")
  writeAt(math.max(1,w-#right-1),1,right,colors.lime,colors.gray)
end

local function footer(text)
  local w,h = term.getSize()
  fill(1,h,w,1,colors.gray)
  writeAt(2,h,text or "Arrows: move  Enter: open  Q: quit",colors.white,colors.gray)
end

local function prompt(label,default,hidden)
  clear(colors.black); header(label)
  writeAt(2,4,label .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local value = read(hidden and "*" or nil)
  if value == "" then return default end
  return value
end

local function confirm(label)
  local answer = prompt(label .. " (y/N)", "n")
  return answer and answer:lower():sub(1,1) == "y"
end

local function refresh(data,silent)
  local response,err = request("live-status")
  if response then
    data.lastStatus = response.data
    if not silent then Storage.log(data,"INFO","Telemetry refreshed") end
    saveData(data)
    return response.data
  end
  if not silent then Storage.log(data,"WARN",err); saveData(data) end
  return data.lastStatus,err
end

local function iconPosition(index)
  local col=(index-1)%3
  local row=math.floor((index-1)/3)
  return 16+col*12,3+row*5
end

local function drawIcon(index,icon)
  local x,y=iconPosition(index)
  local active=index==selected
  local bg=active and colors.lightGray or colors.green
  local fg=active and colors.black or colors.white
  fill(x-1,y-1,8,5,bg)
  for row,line in ipairs(icon.glyph) do
    for col=1,#line do
      if line:sub(col,col)=="#" then writeAt(x+col-1,y+row-1," ",fg,fg) end
    end
  end
  writeAt(x-1,y+3,icon.label:sub(1,10),fg,bg)
end

local function desktop()
  clear(colors.green)
  header("", "[ " .. tostring(config.activeProfile or "none") .. " ]")
  local categories={"HOME","NAVIGATION","AUTOPILOT","AIRCRAFT","SYSTEM"}
  local w,h=term.getSize()
  fill(1,2,12,h-2,colors.gray)
  for i,name in ipairs(categories) do
    local active=(i==1)
    fill(1,i+2,12,1,active and colors.lightGray or colors.gray)
    writeAt(2,i+2,name,active and colors.black or colors.white,active and colors.lightGray or colors.gray)
  end
  writeAt(2,h-3,"PROGRAM",colors.lightGray,colors.gray)
  writeAt(2,h-2,"CONTROLLER",colors.lightGray,colors.gray)
  for i,icon in ipairs(icons) do drawIcon(i,icon) end
  if message~="" then writeAt(14,h-1,message:sub(1,math.max(1,w-15)),colors.yellow,colors.green) end
  footer("Arrows: move  Enter: open  R: refresh  Q: quit")
end

local function waitBack(help)
  footer(help or "Esc: back")
  repeat local _,key=os.pullEvent("key") until key==keys.escape
end

local function listPage(title,map,help)
  clear(colors.black); header(title)
  local names=Storage.names(map)
  if #names==0 then writeAt(3,4,"No saved entries",colors.lightGray) end
  for i,name in ipairs(names) do
    if i>12 then break end
    writeAt(3,i+3,tostring(i)..". "..name,colors.white)
  end
  footer(help or "A:add  D:delete  Esc:back")
  return names
end

local function activateTarget(data,target)
  data.target=target; saveData(data)
  local ok,err=request("set-target",{target=target})
  if ok then ok,err=request("set-mode",{mode="navigate"}) end
  if ok then message="Navigating to "..tostring(target.name or "target"); Storage.log(data,"INFO",message)
  else message=err or "Target rejected"; Storage.log(data,"WARN",message) end
  saveData(data)
end

local function targetsPage(data)
  while true do
    listPage("Targets",data.targets,"A:add  G:go  D:delete  Esc:back")
    local _,key=os.pullEvent("key")
    if key==keys.escape then return
    elseif key==keys.a then
      local name=prompt("Target name")
      local x=tonumber(prompt("X")); local y=tonumber(prompt("Y")); local z=tonumber(prompt("Z"))
      if name and name~="" and x and y and z then data.targets[name]={name=name,x=x,y=y,z=z}; saveData(data) end
    elseif key==keys.g then
      local name=prompt("Target to activate")
      if data.targets[name] then activateTarget(data,data.targets[name]); return else message="Target not found" end
    elseif key==keys.d then
      local name=prompt("Target to delete")
      if data.targets[name] and confirm("Delete "..name) then data.targets[name]=nil; saveData(data) end
    end
  end
end

local function createPath(data,kind)
  local name=prompt(kind.." name")
  local count=tonumber(prompt("Number of stops","2"))
  if not name or name=="" or not count or count<1 then return end
  local stops={}
  for i=1,math.floor(count) do
    local saved=prompt("Stop "..i.." saved target (blank=coords)","")
    if saved~="" and data.targets[saved] then
      local t=data.targets[saved]; stops[#stops+1]={name=t.name,x=t.x,y=t.y,z=t.z}
    else
      local label=prompt("Stop "..i.." label","Stop "..i)
      local x=tonumber(prompt("X")); local y=tonumber(prompt("Y")); local z=tonumber(prompt("Z"))
      if not x or not y or not z then return end
      stops[#stops+1]={name=label,x=x,y=y,z=z}
    end
  end
  local item={name=name,stops=stops}
  if kind=="Schedule" then item.loop=confirm("Loop schedule"); item.dwell=tonumber(prompt("Dwell seconds","0")) or 0 end
  local map=kind=="Route" and data.routes or data.schedules
  map[name]=item; saveData(data)
end

local function runPath(data,kind,name)
  local map=kind=="Route" and data.routes or data.schedules
  local item=map[name]
  if not item or type(item.stops)~="table" or #item.stops==0 then message=kind.." not found"; return end
  local active={name=name,index=1,started=os.epoch and os.epoch("utc") or nil}
  if kind=="Route" then data.activeRoute=active; data.activeSchedule=nil else data.activeSchedule=active; data.activeRoute=nil end
  saveData(data); activateTarget(data,item.stops[1])
  message=kind.." started: "..name
end

local function pathPage(data,kind)
  local map=kind=="Route" and data.routes or data.schedules
  while true do
    listPage(kind.."s",map,"A:add  R:run  D:delete  S:stop  Esc:back")
    local active=kind=="Route" and data.activeRoute or data.activeSchedule
    if active then writeAt(28,3,"ACTIVE: "..active.name.." #"..tostring(active.index),colors.lime) end
    local _,key=os.pullEvent("key")
    if key==keys.escape then return
    elseif key==keys.a then createPath(data,kind)
    elseif key==keys.r then local name=prompt(kind.." to run"); runPath(data,kind,name); return
    elseif key==keys.d then local name=prompt(kind.." to delete"); if map[name] and confirm("Delete "..name) then map[name]=nil; saveData(data) end
    elseif key==keys.s then data.activeRoute=nil; data.activeSchedule=nil; request("set-mode",{mode="standby"}); request("outputs-off"); saveData(data); message="Automation stopped"; return end
  end
end

local function modesPage()
  local modes={"standby","navigate","hover","return-home"}
  clear(colors.black); header("Flight modes")
  for i,mode in ipairs(modes) do writeAt(4,i+3,tostring(i)..". "..mode,colors.white) end
  footer("1-4: activate  Esc: back")
  while true do
    local _,key=os.pullEvent("key")
    if key==keys.escape then return end
    local index=key-keys.one+1
    if modes[index] then local ok,err=request("set-mode",{mode=modes[index]}); message=ok and ("Mode: "..modes[index]) or err; return end
  end
end

local function manualPage()
  clear(colors.black); header("Manual control")
  writeAt(3,4,"W / S",colors.cyan); writeAt(13,4,"Forward / reverse")
  writeAt(3,5,"A / D",colors.cyan); writeAt(13,5,"Turn left / right")
  writeAt(3,6,"Space / Shift",colors.cyan); writeAt(18,6,"Up / down")
  writeAt(3,8,"Each press sends a bounded pulse.",colors.yellow)
  footer("Movement keys  X: outputs off  Esc: back")
  while true do
    local _,key=os.pullEvent("key")
    if key==keys.escape then return end
    local control=key==keys.w and "forward" or key==keys.s and "reverse" or key==keys.a and "left" or key==keys.d and "right" or key==keys.space and "up" or key==keys.leftShift and "down"
    if control then request("manual-control",{control=control,strength=2,duration=0.3}) end
    if key==keys.x then request("outputs-off"); message="Outputs cleared"; return end
  end
end

local function dashboard(data)
  local status,err=refresh(data)
  clear(colors.black); header("Dashboard",err and "[ OFFLINE ]" or "[ SABLE ONLINE ]")
  status=status or {}; local p=status.position or {}; local v=status.velocity or {}
  writeAt(3,3,"Aircraft",colors.cyan); writeAt(15,3,config.activeProfile or "none")
  writeAt(3,4,"Host",colors.cyan); writeAt(15,4,(profile() and profile().host) or "none")
  writeAt(3,6,"Mode"); writeAt(15,6,status.mode or "unknown",colors.lime)
  writeAt(3,7,"Target"); writeAt(15,7,status.target and (status.target.name or "coordinates") or "none",colors.yellow)
  writeAt(3,9,"Position",colors.cyan)
  writeAt(3,10,string.format("X %8.1f",tonumber(p.x) or 0)); writeAt(18,10,string.format("Y %8.1f",tonumber(p.y) or 0)); writeAt(33,10,string.format("Z %8.1f",tonumber(p.z) or 0))
  writeAt(3,12,"Velocity",colors.cyan)
  writeAt(3,13,string.format("X %8.2f",tonumber(v.x) or 0)); writeAt(18,13,string.format("Y %8.2f",tonumber(v.y) or 0)); writeAt(33,13,string.format("Z %8.2f",tonumber(v.z) or 0))
  writeAt(3,15,"Local library",colors.cyan)
  writeAt(3,16,"Targets "..#Storage.names(data.targets)); writeAt(18,16,"Routes "..#Storage.names(data.routes)); writeAt(32,16,"Schedules "..#Storage.names(data.schedules))
  waitBack("R: refresh  Esc: back")
end

local function profilesPage()
  while true do
    clear(colors.black); header("Profiles")
    local names=Storage.names(config.profiles)
    for i,name in ipairs(names) do
      local marker=name==config.activeProfile and ">" or " "
      writeAt(3,i+3,marker.." "..tostring(i)..". "..name.."  "..tostring(config.profiles[name].host or ""),name==config.activeProfile and colors.lime or colors.white)
    end
    footer("Number: select  A:add  E:edit  D:delete  Esc:back")
    local _,key=os.pullEvent("key")
    if key==keys.escape then return
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
end

local function logsPage(data)
  clear(colors.black); header("Local event log")
  local start=math.max(1,#data.eventLog-12); local y=3
  for i=start,#data.eventLog do
    local item=data.eventLog[i]
    local c=item.level=="WARN" and colors.yellow or item.level=="ERROR" and colors.red or colors.lime
    writeAt(2,y,"["..tostring(item.level).."] "..tostring(item.message):sub(1,42),c); y=y+1
  end
  waitBack()
end

local function settingsPage(data)
  while true do
    clear(colors.black); header("Settings")
    data.preferences=data.preferences or {}
    writeAt(3,4,"1. Arrival radius",colors.cyan); writeAt(25,4,tostring(data.preferences.arrivalRadius or 5))
    writeAt(3,5,"2. Auto refresh",colors.cyan); writeAt(25,5,data.preferences.autoRefresh==false and "off" or "on")
    writeAt(3,6,"3. Manual strength",colors.cyan); writeAt(25,6,tostring(data.preferences.manualStrength or 2))
    writeAt(3,8,"Connection values are edited in Profiles.",colors.lightGray)
    footer("1-3: edit  Esc: back")
    local _,key=os.pullEvent("key")
    if key==keys.escape then saveData(data); return
    elseif key==keys.one then data.preferences.arrivalRadius=tonumber(prompt("Arrival radius",data.preferences.arrivalRadius or 5)) or 5
    elseif key==keys.two then data.preferences.autoRefresh=not (data.preferences.autoRefresh~=false)
    elseif key==keys.three then data.preferences.manualStrength=math.max(1,math.min(15,tonumber(prompt("Manual strength",data.preferences.manualStrength or 2)) or 2)) end
    saveData(data)
  end
end

local function advanceAutomation(data,status)
  local active,kind,map
  if data.activeRoute then active=data.activeRoute; kind="Route"; map=data.routes elseif data.activeSchedule then active=data.activeSchedule; kind="Schedule"; map=data.schedules end
  if not active or not status or not status.position or not status.target then return end
  local item=map[active.name]; if not item or not item.stops or #item.stops==0 then data.activeRoute=nil; data.activeSchedule=nil; saveData(data); return end
  local dx=(tonumber(status.position.x) or 0)-(tonumber(status.target.x) or 0)
  local dy=(tonumber(status.position.y) or 0)-(tonumber(status.target.y) or 0)
  local dz=(tonumber(status.position.z) or 0)-(tonumber(status.target.z) or 0)
  local radius=tonumber((data.preferences or {}).arrivalRadius) or 5
  if math.sqrt(dx*dx+dy*dy+dz*dz)>radius then
    if active.dwellIndex or active.dwellUntil then active.dwellIndex=nil; active.dwellUntil=nil; saveData(data) end
    return
  end
  if kind=="Schedule" then
    local dwell=math.max(0,tonumber(item.dwell) or 0)
    if dwell>0 then
      local now=os.epoch and (os.epoch("utc")/1000) or os.clock()
      if active.dwellIndex~=(tonumber(active.index) or 1) or not active.dwellUntil then
        active.dwellIndex=tonumber(active.index) or 1; active.dwellUntil=now+dwell; saveData(data); return
      end
      if now<active.dwellUntil then saveData(data); return end
      active.dwellIndex=nil; active.dwellUntil=nil
    end
  end
  local nextIndex=(tonumber(active.index) or 1)+1
  if nextIndex>#item.stops then
    if kind=="Schedule" and item.loop then nextIndex=1 else data.activeRoute=nil; data.activeSchedule=nil; request("set-mode",{mode="standby"}); request("outputs-off"); message=kind.." complete"; Storage.log(data,"INFO",message); saveData(data); return end
  end
  active.index=nextIndex; saveData(data); activateTarget(data,item.stops[nextIndex])
end

if not term.isColor() then printError("NavRemote requires an Advanced Computer or color monitor."); return end
if not openModem() then printError("NavRemote requires a wired or wireless modem."); return end
if not config.activeProfile then printError("No aircraft configured. Add one in /navremote/config.lua first."); return end

local refreshTimer=os.startTimer(1)
while true do
  local data=localData()
  data.preferences=data.preferences or {}
  selected=math.max(1,math.min(#icons,tonumber(data.preferences.selectedIcon) or selected))
  desktop()
  local event,a=os.pullEvent()
  if event=="timer" and a==refreshTimer then
    if data.preferences.autoRefresh~=false then local status=refresh(data,true); advanceAutomation(data,status) end
    refreshTimer=os.startTimer(1)
  elseif event=="key" then
    local key=a
    if key==keys.q then clear(colors.black); return
    elseif key==keys.left and selected>1 then selected=selected-1
    elseif key==keys.right and selected<#icons then selected=selected+1
    elseif key==keys.up and selected>3 then selected=selected-3
    elseif key==keys.down and selected+3<=#icons then selected=selected+3
    elseif key==keys.r then local status,err=refresh(data); message=err or (status and "Telemetry refreshed" or "No telemetry")
    elseif key==keys.enter then
      local id=icons[selected].id
      if id=="dashboard" then dashboard(data)
      elseif id=="targets" then targetsPage(data)
      elseif id=="routes" then pathPage(data,"Route")
      elseif id=="schedules" then pathPage(data,"Schedule")
      elseif id=="modes" then modesPage()
      elseif id=="manual" then manualPage()
      elseif id=="profiles" then profilesPage()
      elseif id=="logs" then logsPage(data)
      elseif id=="settings" then settingsPage(data) end
    end
    data.preferences.selectedIcon=selected; saveData(data)
  end
end
