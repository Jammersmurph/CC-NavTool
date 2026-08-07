local VERSION = "0.5.9-nightly"
local ROOT = "/navremote"
local CONFIG_PATH = ROOT .. "/config.lua"
local Storage = dofile(ROOT .. "/storage.lua")

local DEGREES_TO_CARDINAL = {
  [0] = "N", [45] = "NE", [90] = "E", [135] = "SE",
  [180] = "S", [225] = "SW", [270] = "W", [315] = "NW",
}

local function degreesToCardinal(degrees)
  degrees = math.floor((tonumber(degrees) or 0) + 0.5) % 360
  local best, bestDist = "N", 360
  for deg, label in pairs(DEGREES_TO_CARDINAL) do
    local dist = math.abs(degrees - deg)
    if dist > 180 then dist = 360 - dist end
    if dist < bestDist then best, bestDist = label, dist end
  end
  return best
end

local function nowSeconds()
  return os.epoch and (os.epoch("utc") / 1000) or os.time()
end

local config = dofile(CONFIG_PATH)
config.profiles = type(config.profiles) == "table" and config.profiles or {}
config.activeProfile = config.activeProfile or next(config.profiles)
local hostCache, selected, message = {}, 1, ""

local icons = {
  { id="dashboard", label="Dashboard", glyph={"#####","#.#.#","#####"} },
  { id="targets", label="Waypoints", glyph={"..#..","#####","..#.."} },
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
  local selfId = os.getComputerID and os.getComputerID() or nil
  if selfId and tonumber(hostId) == selfId then
    hostCache[key] = nil
    return nil, "NavRemote cannot control local NavTool; use another computer or NavTool UI"
  end
  hostCache[key] = hostId
  local payload = extra or {}
  local requestId = tostring(os.getComputerID and os.getComputerID() or "remote") .. ":" .. tostring(os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)) .. ":" .. tostring(math.random(1000000))
  payload.command, payload.key, payload.requestId = command, connection.sharedKey or "", requestId
  rednet.send(hostId, payload, channel)
  local sender, response = rednet.receive(channel, tonumber(connection.timeout) or 3)
  if sender ~= hostId or type(response) ~= "table" then hostCache[key] = nil; return nil, "No response" end
  if response.requestId ~= nil and response.requestId ~= requestId then hostCache[key] = nil; return nil, "Mismatched response" end
  if not response.ok then return nil, response.error or "Rejected" end
  return response
end

local function localData() return Storage.load(config.activeProfile or "default") end
local function saveData(data) return Storage.save(data and data.profile or config.activeProfile or "default", data) end

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
    renderMonitorTelemetry(data)
    if not silent then Storage.log(data,"INFO","Telemetry refreshed") end
    saveData(data)
    return response.data
  end
  if data.preferences and data.preferences.monitorTelemetry == true then renderMonitorTelemetry(data, err) end
  if not silent then Storage.log(data,"WARN",err); saveData(data) end
  return data.lastStatus,err
end

local function monitorNames()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    local isMonitor = peripheral.getType(name) == "monitor"
    if not isMonitor and type(peripheral.hasType) == "function" then
      local ok, value = pcall(peripheral.hasType, name, "monitor")
      isMonitor = ok and value == true
    end
    if isMonitor then names[#names + 1] = name end
  end
  return names
end

local function formatVector(value)
  if type(value) ~= "table" then return "n/a" end
  return string.format("%.1f %.1f %.1f", tonumber(value.x) or 0, tonumber(value.y) or 0, tonumber(value.z) or 0)
end

local function clearLocalMonitors()
  for _, name in ipairs(monitorNames()) do
    local monitor = peripheral.wrap(name)
    if monitor then
      monitor.setBackgroundColor(colors.black)
      monitor.setTextColor(colors.white)
      monitor.clear()
      monitor.setCursorPos(1, 1)
    end
  end
end

local function headingText(status)
  local degrees = tonumber(status and status.headingDegrees)
  local heading = status and status.heading
  if not degrees and type(heading) == "table" and heading.x and heading.z then degrees = math.deg(math.atan2(heading.x, heading.z or 0)) end
  return degrees and (string.format("%.0f", degrees) .. " " .. degreesToCardinal(degrees)) or "n/a"
end

local function scheduleSummary(status)
  status = status or {}
  local active = status.activeSchedule
  if not active then return nil end
  local schedules = type(status.schedules) == "table" and status.schedules or {}
  local schedule = schedules[active.name] or {}
  local stops = type(schedule.stops) == "table" and schedule.stops or {}
  local index = math.max(1, math.min(#stops > 0 and #stops or 1, tonumber(active.index) or 1))
  local stop = stops[index] or status.target
  local nextIndex = index + 1
  if nextIndex > #stops and schedule.loop then nextIndex = 1 end
  local nextStop = stops[nextIndex]
  local arrival = status.scheduleArrival or {}
  local departIn = active.dwellUntil and math.max(0, math.ceil((tonumber(active.dwellUntil) or 0) - nowSeconds())) or nil
  local phase = active.paused and "Paused" or departIn and "Dwelling" or arrival.arrived and "Arrived" or arrival.axesReached and "Settling" or "En route"
  return {
    active = active,
    schedule = schedule,
    stop = stop,
    nextStop = nextStop,
    index = index,
    total = #stops > 0 and #stops or "?",
    phase = phase,
    departIn = departIn,
    distance = status.distanceToTarget,
    arrival = arrival,
  }
end

local function stopName(stop, fallback)
  return tostring((type(stop) == "table" and stop.name) or fallback or "?")
end

function renderMonitorTelemetry(data, errorText)
  data = data or {}
  local prefs = type(data.preferences) == "table" and data.preferences or {}
  if prefs.monitorTelemetry ~= true then return end
  local status = data.lastStatus or {}
  for _, name in ipairs(monitorNames()) do
    local monitor = peripheral.wrap(name)
    if monitor then
      pcall(monitor.setTextScale, 0.5)
      monitor.setBackgroundColor(colors.black)
      monitor.setTextColor(colors.white)
      monitor.clear()
      monitor.setCursorPos(1, 1)
      local width = monitor.getSize()
      local function line(y, label, value, color)
        monitor.setCursorPos(1, y)
        monitor.setTextColor(colors.lightGray)
        monitor.write(string.sub(label, 1, 12))
        monitor.setCursorPos(14, y)
        monitor.setTextColor(color or colors.white)
        monitor.write(string.sub(tostring(value or "n/a"), 1, math.max(1, width - 13)))
      end
      local target = status.target or {}
      local schedule = scheduleSummary(status)
      monitor.setTextColor(colors.lime)
      monitor.write("NavRemote Flight")
      if errorText and not status.telemetry then line(2, "Status", tostring(errorText), colors.red) end
      line(3, "Mode", status.mode or "n/a", colors.cyan)
      line(4, "Position", formatVector(status.position))
      line(5, "Target", formatVector(target))
      line(6, "Distance", status.distanceToTarget and string.format("%.1f", status.distanceToTarget) or "n/a", colors.yellow)
      line(7, "Altitude", status.altitude or (status.position and status.position.y) or "n/a")
      line(8, "Heading", headingText(status))
      if schedule then
        line(9, "Schedule", tostring(schedule.active.name or "?") .. " " .. tostring(schedule.index) .. "/" .. tostring(schedule.total), colors.lime)
        line(10, "Phase", schedule.phase, schedule.departIn and colors.yellow or colors.cyan)
        line(11, "Stop", stopName(schedule.stop, "Stop " .. tostring(schedule.index)))
        line(12, "Next", schedule.nextStop and stopName(schedule.nextStop) or "complete")
        line(13, "Depart", schedule.departIn and (tostring(schedule.departIn) .. "s") or "n/a", colors.yellow)
        line(14, "Arrive", schedule.arrival.arrived and "yes" or "no", schedule.arrival.arrived and colors.lime or colors.lightGray)
      else
        line(9, "Schedule", "none")
        line(10, "Source", status.source or status.peripheral or "n/a")
      end
    end
  end
end

local function iconPosition(index)
  local w=term.getSize()
  local columns=w>=45 and 4 or 3
  local col=(index-1)%columns
  local row=math.floor((index-1)/columns)
  local spacing=12
  local start=math.max(2,math.floor((w-(columns*9+(columns-1)*(spacing-9)))/2)+1)
  return start+col*spacing,3+row*5
end

local function drawIcon(index,icon)
  local x,y=iconPosition(index)
  local active=index==selected
  local bg=active and colors.lightGray or colors.green
  local fg=active and colors.black or colors.white
  fill(x-1,y-1,9,5,bg)
  for row,line in ipairs(icon.glyph) do
    for col=1,#line do
      if line:sub(col,col)=="#" then writeAt(x+col-1,y+row-1," ",fg,fg) end
    end
  end
  writeAt(x-1,y+3,icon.label:sub(1,9),fg,bg)
end

local function desktop()
  clear(colors.green)
  header("", "[ " .. tostring(config.activeProfile or "none") .. " ]")
  local w,h=term.getSize()
  for i,icon in ipairs(icons) do drawIcon(i,icon) end
  if message~="" then writeAt(2,h-1,message:sub(1,math.max(1,w-3)),colors.yellow,colors.green) end
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
  if type(target)=="table" and target.heading~=nil then
    local copy={}
    for k,v in pairs(target) do if k~="heading" then copy[k]=v end end
    target=copy
  end
  data.target=target; saveData(data)
  local ok,err=request("set-target",{target=target})
  if ok then ok,err=request("set-mode",{mode="navigate"}) end
  if ok then message="Navigating to "..tostring(target.name or "waypoint"); Storage.log(data,"INFO",message)
  else message=err or "Target rejected"; Storage.log(data,"WARN",message) end
  saveData(data)
end

local function targetsPage(data)
  while true do
    listPage("Local Waypoints",data.targets,"A:add  E:edit  G:go  D:delete  Esc:back")
    local _,key=os.pullEvent("key")
    if key==keys.escape then return
    elseif key==keys.a then
      local name=prompt("Waypoint name")
      local x=tonumber(prompt("X")); local y=tonumber(prompt("Y")); local z=tonumber(prompt("Z"))
      if name and name~="" and x and y and z then
        local target={name=name,x=x,y=y,z=z}
        data.targets[name]=target; saveData(data); message="Saved local waypoint: "..name
      end
    elseif key==keys.e then
      local name=prompt("Waypoint to edit")
      local target=data.targets[name]
      if target then
        local newName=prompt("Waypoint name",target.name or name)
        local x=tonumber(prompt("X",target.x)); local y=tonumber(prompt("Y",target.y)); local z=tonumber(prompt("Z",target.z))
        if newName and newName~="" and x and y and z then
          local updated={name=newName,x=x,y=y,z=z}
          data.targets[name]=nil
          data.targets[newName]=updated
          local changedRoutes,changedSchedules=0,0
          for _,route in pairs(data.routes or {}) do
            if type(route.stops)=="table" then
              for _,stop in ipairs(route.stops) do
                if stop.name==name then stop.name=updated.name; stop.x=updated.x; stop.y=updated.y; stop.z=updated.z; changedRoutes=changedRoutes+1 end
              end
            end
          end
          for _,schedule in pairs(data.schedules or {}) do
            local changed=false
            if type(schedule.stops)=="table" then
              for _,stop in ipairs(schedule.stops) do
                if stop.name==name then stop.name=updated.name; stop.x=updated.x; stop.y=updated.y; stop.z=updated.z; changedSchedules=changedSchedules+1; changed=true end
              end
            end
            if changed then request("save-schedule",{schedule=schedule}) end
          end
          saveData(data)
          message="Edited local waypoint: "..newName.." (updated "..tostring(changedRoutes+changedSchedules).." stops)"
        else
          message="Invalid waypoint"
        end
      else message="Waypoint not found" end
    elseif key==keys.g then
      local name=prompt("Waypoint to activate")
      if data.targets[name] then activateTarget(data,data.targets[name]); return else message="Waypoint not found" end
    elseif key==keys.d then
      local name=prompt("Waypoint to delete")
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
      local t=data.targets[saved]; local stop={name=t.name,x=t.x,y=t.y,z=t.z}
      stops[#stops+1]=stop
    else
      local label=prompt("Stop "..i.." label","Stop "..i)
      local x=tonumber(prompt("X")); local y=tonumber(prompt("Y")); local z=tonumber(prompt("Z"))
      if not x or not y or not z then return end
      local stop={name=label,x=x,y=y,z=z}
      stops[#stops+1]=stop
    end
  end
  local item={name=name,stops=stops}
  if kind=="Schedule" then item.loop=confirm("Loop schedule"); item.dwell=tonumber(prompt("Dwell seconds","0")) or 0 end
  local map=kind=="Route" and data.routes or data.schedules
  if kind=="Schedule" then
    local ok,err=request("save-schedule",{schedule=item})
    if not ok then message="Schedule save failed: "..tostring(err); return end
  end
  map[name]=item; saveData(data)
end

local function promptStop(data,index)
  local saved=prompt("Stop "..tostring(index).." saved target (blank=coords)","")
  if saved~="" and data.targets[saved] then
    local t=data.targets[saved]
    return {name=t.name,x=t.x,y=t.y,z=t.z}
  end
  local label=prompt("Stop "..tostring(index).." label","Stop "..tostring(index))
  local x=tonumber(prompt("X")); local y=tonumber(prompt("Y")); local z=tonumber(prompt("Z"))
  if not x or not y or not z then return nil end
  return {name=label,x=x,y=y,z=z}
end

local function saveScheduleEdit(data,schedule)
  if not schedule or not schedule.name then return false,"Schedule not found" end
  local ok,err=request("save-schedule",{schedule=schedule})
  if not ok then return false,"Schedule save failed: "..tostring(err) end
  data.schedules[schedule.name]=schedule
  saveData(data)
  return true
end

local function addStopToSchedule(data,schedules)
  local name=prompt("Schedule to edit")
  local schedule=name and schedules[name]
  if not schedule then message="Schedule not found"; return end
  schedule.stops=type(schedule.stops)=="table" and schedule.stops or {}
  local stop=promptStop(data,#schedule.stops+1)
  if not stop then message="Invalid stop"; return end
  schedule.stops[#schedule.stops+1]=stop
  local ok,err=saveScheduleEdit(data,schedule)
  message=ok and ("Added stop to "..name) or err
end

local function removeStopFromSchedule(data,schedules)
  local name=prompt("Schedule to edit")
  local schedule=name and schedules[name]
  if not schedule or type(schedule.stops)~="table" then message="Schedule not found"; return end
  local index=tonumber(prompt("Stop number to remove"))
  if not index or index<1 or index>#schedule.stops then message="Invalid stop number"; return end
  if #schedule.stops<=1 then message="Schedule needs at least one stop"; return end
  local stop=schedule.stops[index]
  if not confirm("Remove "..tostring(stop.name or ("stop "..index))) then return end
  table.remove(schedule.stops,index)
  local ok,err=saveScheduleEdit(data,schedule)
  message=ok and ("Removed stop from "..name) or err
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

local function schedulePage(data)
  while true do
    local response,err=request("status")
    local status=response and response.data or {}
    local active=status.activeSchedule
    local schedules=status.schedules or data.schedules or {}
    data.schedules=schedules
    local names=Storage.names(schedules)
    local w,h=term.getSize()
    clear(colors.black); header("Schedules")
    local y=3
    if active then
      local summary=scheduleSummary(status) or {}
      local arrival=summary.arrival or status.scheduleArrival or {}
      fill(1,y,w,5,colors.gray)
      writeAt(2,y,"ACTIVE SCHEDULE",colors.yellow); y=y+1
      writeAt(2,y,tostring(active.name or "?"),colors.lime)
      writeAt(25,y,"Stop "..tostring(summary.index or active.index or 1).."/"..tostring(summary.total or "?"),colors.white)
      if active.paused then writeAt(35,y,"PAUSED",colors.yellow) end
      if summary.departIn then
        writeAt(35,y,"Depart in "..tostring(summary.departIn).."s",colors.yellow)
      elseif arrival.arrived then
        writeAt(35,y,"ARRIVED",colors.lime)
      elseif arrival.axesReached then
        writeAt(35,y,"SETTLING",colors.yellow)
      end
      y=y+1
      writeAt(2,y,"Status: "..tostring(summary.phase or "Traveling"),arrival.arrived and colors.lime or colors.lightGray)
      if status.distanceToTarget then writeAt(18,y,"Dist "..string.format("%.1f",status.distanceToTarget),colors.yellow) end
      if summary.departIn then
        writeAt(30,y,"Depart "..tostring(summary.departIn).."s",colors.yellow)
      elseif summary.nextStop then
        writeAt(30,y,"Next: "..string.sub(stopName(summary.nextStop),1,12),colors.lightGray)
      end
      y=y+1
      if summary.stop then writeAt(2,y,"Current: "..string.sub(stopName(summary.stop),1,16),colors.cyan) end
      if summary.nextStop then writeAt(25,y,"Next: "..string.sub(stopName(summary.nextStop),1,16),colors.lightGray) end
      y=y+1
      local schedule=schedules[active.name]
      if schedule and schedule.stops then
        for i,stop in ipairs(schedule.stops) do
          if y>12 then break end
          local marker=i==(active.index or 1) and ">" or " "
          local color=i==(active.index or 1) and colors.lime or colors.lightGray
          local label=tostring(stop.name or ("Stop "..i))
          local coord=string.format("%.0f,%.0f,%.0f",tonumber(stop.x) or 0,tonumber(stop.y) or 0,tonumber(stop.z) or 0)
          writeAt(2,y,marker.." "..string.sub(label,1,14),color)
          writeAt(20,y,coord,colors.lightGray)
          y=y+1
        end
      end
      y=y+1
    else
      writeAt(2,y,"No active schedule",colors.lightGray); y=y+2
    end
    if y<14 then
      writeAt(2,y,"SAVED SCHEDULES",colors.cyan); y=y+1
      if #names==0 then
        writeAt(2,y,"(none)",colors.lightGray); y=y+1
      else
        for i,name in ipairs(names) do
          if y>14 then break end
          local schedule=schedules[name]
          local stops=schedule and schedule.stops and #schedule.stops or 0
          local loopStr=schedule and schedule.loop and " [loop]" or ""
          writeAt(2,y,tostring(i)..". "..string.sub(name,1,20).." ("..stops.." stops"..loopStr..")",colors.white)
          y=y+1
        end
      end
    end
    local help=""
    if active then
      help=active.paused and "S:skip P:resume X:stop " or "S:skip P:pause X:stop "
    end
    help=help.."R:run A:new E:add stop O:remove stop D:delete Esc:back"
    footer(help)
    local timer=os.startTimer(5)
    local event,key=os.pullEvent()
    if event=="timer" and key==timer then
    elseif event=="key" and key==keys.escape then return
    elseif event=="key" and key==keys.r then
      local name=prompt("Schedule to run")
      if name and schedules[name] then
        request("save-schedule",{schedule=schedules[name]})
        local r,e=request("run-schedule",{name=name})
        message=r and "Schedule started: "..name or e
      elseif name then message="Not found: "..name end
    elseif event=="key" and key==keys.s and active then
      local r,e=request("skip-stop"); message=r and "Stop skipped" or e
    elseif event=="key" and key==keys.p and active then
      local r,e=request(active.paused and "resume-schedule" or "pause-schedule")
      message=r and (active.paused and "Schedule resumed" or "Schedule paused") or e
    elseif event=="key" and key==keys.x and active then
      local r,e=request("stop-schedule"); message=r and "Schedule stopped" or e
    elseif event=="key" and key==keys.a then
      createPath(data,"Schedule")
    elseif event=="key" and key==keys.e then
      addStopToSchedule(data,schedules)
    elseif event=="key" and key==keys.o then
      removeStopFromSchedule(data,schedules)
    elseif event=="key" and key==keys.d then
      local name=prompt("Schedule to delete")
      if name and schedules[name] and confirm("Delete "..name) then
        request("delete-schedule",{name=name})
        data.schedules[name]=nil; saveData(data); message="Deleted: "..name
      end
    end
  end
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

local function manualPage(data)
  local manualStrength = math.max(1, math.min(15, tonumber(data and data.preferences and data.preferences.manualStrength) or 2))
  local hardwareResponse = request("hardware-list")
  local airship = hardwareResponse and hardwareResponse.hardware and hardwareResponse.hardware.modes and hardwareResponse.hardware.modes.airship == true
  if not airship then
    clear(colors.black); header("Manual control")
    writeAt(3,4,"W / S",colors.cyan); writeAt(13,4,"Forward / reverse")
    writeAt(3,5,"A / D",colors.cyan); writeAt(13,5,"Turn left / right")
    writeAt(3,6,"Space / Shift",colors.cyan); writeAt(18,6,"Up / down")
    writeAt(3,8,"Each press sends strength "..tostring(manualStrength)..".",colors.yellow)
    footer("Movement keys  X: outputs off  Esc: back")
    while true do
      local _,key=os.pullEvent("key")
      if key==keys.escape then return end
      local control=key==keys.w and "forward" or key==keys.s and "reverse" or key==keys.a and "left" or key==keys.d and "right" or key==keys.space and "up" or key==keys.leftShift and "down"
      if control then request("manual-control",{control=control,strength=manualStrength,duration=0.3}) end
      if key==keys.x then request("outputs-off"); message="Outputs cleared"; return end
    end
  end

  local statusResponse = request("airship-vertical-status")
  local currentVertical = tonumber(statusResponse and statusResponse.value)
    or tonumber(hardwareResponse and hardwareResponse.hardware and hardwareResponse.hardware.modes and hardwareResponse.hardware.modes.airshipVertical)
  local vertical=math.max(0,math.min(15,currentVertical or 2))
  local function sendVertical()
    local ok,err=request("airship-vertical-control",{strength=vertical})
    if ok then message="Vertical analog "..tostring(vertical)
    elseif tostring(err)=="unsupported command" then message="Update/reboot aircraft NavTool for slider"
    else message=tostring(err) end
  end
  local function draw()
    clear(colors.black); header("Manual control","[ AIRSHIP ]")
    writeAt(3,4,"W / S",colors.cyan); writeAt(13,4,"Forward / reverse")
    writeAt(3,5,"A / D",colors.cyan); writeAt(13,5,"Turn left / right")
    writeAt(3,7,"Vertical analog",colors.cyan)
    writeAt(22,7,string.format("%02d / 15",vertical),colors.lime)
    fill(6,9,5,15,colors.gray)
    for i=0,14 do
      local y=23-i
      local active=i<vertical
      fill(7,y,3,1,active and colors.lime or colors.black)
    end
    writeAt(14,9,"15",colors.lightGray); writeAt(14,16,"08",colors.lightGray); writeAt(14,23,"00",colors.lightGray)
    writeAt(22,10,"Up/Down arrows adjust",colors.lightGray)
    writeAt(22,11,"Click slider to set",colors.lightGray)
    writeAt(22,13,"Manual thrust strength "..tostring(manualStrength),colors.yellow)
    if message~="" then writeAt(22,15,message:sub(1,32),colors.yellow) end
    footer("WASD move  Up/Down/click vertical  Space:set  X:off  Esc:back")
  end
  draw()
  while true do
    local event,a,b,c=os.pullEvent()
    if event=="key" then
      if a==keys.escape then return
      elseif a==keys.up then vertical=math.min(15,vertical+1); sendVertical(); draw()
      elseif a==keys.down then vertical=math.max(0,vertical-1); sendVertical(); draw()
      elseif a==keys.space then sendVertical(); draw()
      elseif a==keys.x then request("outputs-off"); message="Outputs cleared"; return end
      local control=a==keys.w and "forward" or a==keys.s and "reverse" or a==keys.a and "left" or a==keys.d and "right"
      if control then request("manual-control",{control=control,strength=manualStrength,duration=0.3}) end
    elseif event=="mouse_click" and b>=6 and b<=10 and c>=9 and c<=23 then
      vertical=math.max(0,math.min(15,24-c)); sendVertical(); draw()
    end
  end
end

local function dashboard(data)
  local response,err=request("status")
  local status=response and response.data or data.lastStatus
  clear(colors.black); header("Dashboard",err and "[ OFFLINE ]" or "[ SABLE ONLINE ]")
  status=status or {}; local p=status.position or {}; local v=status.velocity or {}
  writeAt(3,3,"Aircraft",colors.cyan); writeAt(15,3,config.activeProfile or "none")
  writeAt(3,4,"Host",colors.cyan); writeAt(15,4,(profile() and profile().host) or "none")
  writeAt(3,5,"Telemetry",colors.cyan); writeAt(15,5,status.telemetry and "ONLINE" or "OFFLINE",status.telemetry and colors.lime or colors.red)
  writeAt(3,6,"Source",colors.cyan); writeAt(15,6,tostring(status.source or "none"))
  writeAt(3,8,"Mode"); writeAt(15,8,status.mode or "unknown",colors.lime)
  local heading = status.heading
  local headingDeg = heading and heading.x and math.deg(math.atan2(heading.x, heading.z or 0))
  local headingText = headingDeg and (string.format("%.0f", headingDeg) .. " " .. degreesToCardinal(headingDeg)) or "n/a"
  writeAt(3,9,"Heading",colors.cyan); writeAt(15,9,headingText)
  writeAt(3,10,"Target"); writeAt(15,10,status.target and (status.target.name or "coords") or "none",colors.yellow)
  if status.target then
    local tx,ty,tz=tonumber(status.target.x) or 0,tonumber(status.target.y) or 0,tonumber(status.target.z) or 0
    writeAt(15,11,string.format("%.1f %.1f %.1f",tx,ty,tz),colors.lightGray)
  end
  if status.distanceToTarget then writeAt(3,12,"Distance",colors.cyan); writeAt(15,12,string.format("%.1f blocks",status.distanceToTarget)) end
  writeAt(3,14,"Position",colors.cyan)
  writeAt(3,15,string.format("X %8.1f",tonumber(p.x) or 0)); writeAt(18,15,string.format("Y %8.1f",tonumber(p.y) or 0)); writeAt(33,15,string.format("Z %8.1f",tonumber(p.z) or 0))
  writeAt(3,16,"Velocity",colors.cyan)
  writeAt(3,17,string.format("X %8.2f",tonumber(v.x) or 0)); writeAt(18,17,string.format("Y %8.2f",tonumber(v.y) or 0)); writeAt(33,17,string.format("Z %8.2f",tonumber(v.z) or 0))
  local active=status.activeSchedule
  if active then
    local summary=scheduleSummary(status) or {}
    writeAt(3,18,"Schedule",colors.cyan)
    writeAt(15,18,tostring(active.name or "?").." "..tostring(summary.index or active.index or 1).."/"..tostring(summary.total or "?"),colors.lime)
    writeAt(3,19,"Sched Status",colors.cyan)
    writeAt(15,19,tostring(summary.phase or "En route"),summary.departIn and colors.yellow or colors.white)
    if summary.departIn then writeAt(29,19,"Depart "..tostring(summary.departIn).."s",colors.yellow) end
    writeAt(3,20,"Current",colors.cyan)
    writeAt(15,20,stopName(summary.stop,"Stop "..tostring(summary.index or active.index or 1)),colors.white)
    writeAt(3,21,"Next",colors.cyan)
    writeAt(15,21,summary.nextStop and stopName(summary.nextStop) or "complete",colors.lightGray)
  else
    writeAt(3,21,"Monitor",colors.cyan)
    writeAt(15,21,status.peripheral or status.sublevel or "none")
  end
  if status.automation and type(status.automation.notes)=="table" then
    writeAt(3,22,"Control",colors.cyan)
    writeAt(15,22,tostring(status.automation.summary or status.automation.notes[1] or ""):sub(1,32),colors.yellow)
    if type(status.automation.debug)=="table" then
      writeAt(3,23,"Head Err",colors.cyan)
      writeAt(15,23,string.format("%.1f align %.2f",tonumber(status.automation.debug.headingError) or 0,tonumber(status.automation.debug.alignment) or 0),colors.yellow)
    end
  end
  if type(status.liveNavigation)=="table" then
    writeAt(3,24,"Live Align",colors.cyan)
    writeAt(15,24,string.format("%.1f align %.2f",tonumber(status.liveNavigation.headingError) or 0,tonumber(status.liveNavigation.alignment) or 0),colors.lime)
  end
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

local function frontCalibrationPage(data)
  while true do
    local response,err=request("orientation-status")
    local yaw=tonumber(response and response.yawOffset) or 0
    local status=response or {}
    clear(colors.black); header("Front calibration")
    writeAt(3,4,"Current yaw offset",colors.cyan); writeAt(25,4,tostring(yaw).." deg")
    writeAt(3,5,"Reported heading",colors.cyan); writeAt(25,5,headingText(status))
    writeAt(3,7,"Use this if NavTool thinks the",colors.lightGray)
    writeAt(3,8,"aircraft front points the wrong way.",colors.lightGray)
    writeAt(3,10,"1. Rotate front left 90",colors.white)
    writeAt(3,11,"2. Rotate front right 90",colors.white)
    writeAt(3,12,"3. Flip front 180",colors.white)
    writeAt(3,13,"4. Reset offset to 0",colors.white)
    if err then writeAt(3,15,tostring(err),colors.red) end
    footer("1-4: set  R: refresh  Esc: back")
    local _,key=os.pullEvent("key")
    if key==keys.escape then return
    elseif key==keys.r then
    else
      local nextYaw=nil
      if key==keys.one then nextYaw=yaw+90
      elseif key==keys.two then nextYaw=yaw-90
      elseif key==keys.three then nextYaw=yaw+180
      elseif key==keys.four then nextYaw=0 end
      if nextYaw then
        local ok,setErr=request("orientation-set",{yawOffset=nextYaw})
        message=ok and "Front calibration updated" or tostring(setErr)
        Storage.log(data,ok and "INFO" or "WARN",message); saveData(data)
      end
    end
  end
end

local function settingsPage(data)
  while true do
    clear(colors.black); header("Settings")
    data.preferences=data.preferences or {}
    writeAt(3,4,"1. Arrival radius",colors.cyan); writeAt(25,4,tostring(data.preferences.arrivalRadius or 5))
    writeAt(3,5,"2. Auto refresh",colors.cyan); writeAt(25,5,data.preferences.autoRefresh==false and "off" or "on")
    writeAt(3,6,"3. Manual strength",colors.cyan); writeAt(25,6,tostring(data.preferences.manualStrength or 2))
    writeAt(3,7,"4. Monitor telemetry",colors.cyan); writeAt(25,7,data.preferences.monitorTelemetry==true and "on" or "off")
    writeAt(3,8,"5. Front calibration",colors.cyan); writeAt(25,8,"open")
    writeAt(3,9,"Connection values are edited in Profiles.",colors.lightGray)
    footer("1-5: edit  Esc: back")
    local _,key=os.pullEvent("key")
    if key==keys.escape then saveData(data); return
    elseif key==keys.one then data.preferences.arrivalRadius=tonumber(prompt("Arrival radius",data.preferences.arrivalRadius or 5)) or 5
    elseif key==keys.two then data.preferences.autoRefresh=not (data.preferences.autoRefresh~=false)
    elseif key==keys.three then data.preferences.manualStrength=math.max(1,math.min(15,tonumber(prompt("Manual strength",data.preferences.manualStrength or 2)) or 2))
    elseif key==keys.four then data.preferences.monitorTelemetry=not (data.preferences.monitorTelemetry==true); config.monitorTelemetry=data.preferences.monitorTelemetry==true; saveConfig(); if data.preferences.monitorTelemetry then renderMonitorTelemetry(data); refresh(data,true) else clearLocalMonitors() end end
    if key==keys.five then frontCalibrationPage(data) end
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
  if config.monitorTelemetry == nil then
    config.monitorTelemetry = data.preferences.monitorTelemetry == true
    saveConfig()
  else
    data.preferences.monitorTelemetry = config.monitorTelemetry == true
  end
  selected=math.max(1,math.min(#icons,tonumber(data.preferences.selectedIcon) or selected))
  desktop()
  local event,a=os.pullEvent()
  if event=="timer" and a==refreshTimer then
    if data.preferences.autoRefresh~=false or data.preferences.monitorTelemetry==true then local status=refresh(data,true); advanceAutomation(data,status) end
    refreshTimer=os.startTimer(1)
  elseif event=="key" then
    local key=a
    local columns=term.getSize()>=45 and 4 or 3
    if key==keys.q then clear(colors.black); return
    elseif key==keys.left and selected>1 then selected=selected-1
    elseif key==keys.right and selected<#icons then selected=selected+1
    elseif key==keys.up and selected>columns then selected=selected-columns
    elseif key==keys.down and selected+columns<=#icons then selected=selected+columns
    elseif key==keys.r then local status,err=refresh(data); message=err or (status and "Telemetry refreshed" or "No telemetry")
    elseif key==keys.enter then
      local id=icons[selected].id
      if id=="dashboard" then dashboard(data)
      elseif id=="targets" then targetsPage(data)
      elseif id=="routes" then pathPage(data,"Route")
      elseif id=="schedules" then schedulePage(data)
      elseif id=="modes" then modesPage()
      elseif id=="manual" then manualPage(data)
      elseif id=="profiles" then profilesPage()
      elseif id=="logs" then logsPage(data)
      elseif id=="settings" then settingsPage(data) end
    end
    data.preferences.selectedIcon=selected; saveData(data)
  end
end
