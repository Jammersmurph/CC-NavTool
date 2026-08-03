local Patch = {}

local function insertBefore(text, marker, addition)
  local at = text:find(marker, 1, true)
  if not at then return text, false end
  return text:sub(1, at - 1) .. addition .. "\n" .. text:sub(at), true
end

function Patch.apply(runtimeSource)
  local injection = [=[
-- Add Hardware to the desktop launcher.
local oldSettingsIcon = '{ id="settings", label="Settings", glyph={".#.#.","#####",".#.#."} },'
local hardwareIcons = oldSettingsIcon .. '\n  { id="hardware", label="Hardware", glyph={"#.#.#",".###.","#.#.#"} },'
source = select(1, replacePlainOnce(source, oldSettingsIcon, hardwareIcons))

source = source:gsub('icon.label:sub%(1,10%)','icon.label:sub(1,8)',1)

local hardwarePageSource = [==[local function hardwarePage(data)
  local controls={"forward","reverse","left","right","up","down"}
  local expanded={}
  local function targetText(item)
    if not item or item.kind=="unassigned" then return "UNASSIGNED" end
    if item.kind=="relay" then return tostring(item.peripheral)..":"..tostring(item.side) end
    return "LOCAL:"..tostring(item.side)
  end
  local function assignmentText(item)
    if not item or item.kind=="unassigned" then return "UNASSIGNED" end
    if item.targets and #item.targets>1 then return targetText(item.targets[1]).." +"..tostring(#item.targets-1) end
    return targetText(item)
  end
  local function chooseControl(label)
    local chosen=tonumber(prompt(label or "Control number","1"))
    if chosen and chosen%1==0 and controls[chosen] then return chosen end
    message="Invalid control number"
    return nil
  end
  local function editPrompt(label,default)
    local value=prompt(label,default)
    local lowered=tostring(value or ""):lower()
    if lowered=="q" or lowered=="cancel" then message="Cancelled"; return nil,true end
    return value,false
  end
  local function chooseAssignmentMode(defaultAdd)
    clear(colors.black); header("Edit assignment")
    writeAt(3,4,"Choose how to change this flight output.",colors.cyan)
    fill(3,7,12,3,colors.gray); writeAt(5,8,"REPLACE",colors.white,colors.gray)
    fill(18,7,12,3,colors.blue); writeAt(23,8,"ADD",colors.white,colors.blue)
    fill(33,7,12,3,colors.red); writeAt(36,8,"CANCEL",colors.white,colors.red)
    writeAt(3,12,"R: replace  A: add  C/Q: cancel",colors.lightGray)
    if defaultAdd then writeAt(3,14,"Add mode selected from the Add button.",colors.yellow) end
    while true do
      local event,a,b,c=os.pullEvent()
      if event=="key" then
        if a==keys.r then return false,true
        elseif a==keys.a then return true,true
        elseif a==keys.c or a==keys.q then message="Cancelled"; return false,false end
      elseif event=="mouse_click" then
        if b>=3 and b<=14 and c>=7 and c<=9 then return false,true
        elseif b>=18 and b<=29 and c>=7 and c<=9 then return true,true
        elseif b>=33 and b<=44 and c>=7 and c<=9 then message="Cancelled"; return false,false end
      end
    end
  end
  local function deleteAssignment(hardware)
    local chosen=chooseControl("Control number to delete")
    if not chosen then return end
    local control=controls[chosen]
    local item=hardware.assignments and hardware.assignments[control]
    if not item or item.kind=="unassigned" or (item.count or 0)==0 then message="Control is unassigned"; return end
    local count=tonumber(item.count) or #(item.targets or {})
    local index=nil
    local all=true
    if count>1 then
      clear(colors.black); header("Delete binding")
      for i,target in ipairs(item.targets or {}) do writeAt(3,i+3,tostring(i)..". "..targetText(target),colors.white) end
      writeAt(3,count+5,"Type a binding number or all.",colors.lightGray)
      local answer=tostring(prompt("Delete binding","all")):lower()
      if answer~="all" then
        index=tonumber(answer)
        all=false
        if not index or index%1~=0 then message="Invalid binding number"; return end
      end
    end
    local okDelete,e=request("hardware-unassign",{control=control,index=index,all=all})
    message=okDelete and (control.." binding deleted") or tostring(e)
  end
  local function configureMonitor()
    local response,e=request("monitor-list")
    if not response then message=tostring(e); return end
    local monitors=response.monitors or {}
    clear(colors.black); header("Monitor")
    writeAt(3,3,"Aircraft LAN monitors",colors.cyan)
    if #monitors==0 then
      writeAt(3,5,"No monitors visible to aircraft.",colors.yellow)
      writeAt(3,7,"Attach through wired modem LAN or directly.",colors.lightGray)
      waitBack("Q: back")
      return
    end
    for i,item in ipairs(monitors) do
      local marker=item.selected and "*" or " "
      local size=item.width and (" "..tostring(item.width).."x"..tostring(item.height)) or ""
      writeAt(3,i+4,marker..tostring(i)..". "..tostring(item.name)..size,item.selected and colors.lime or colors.white)
    end
    writeAt(3,#monitors+6,"Type number to select, clear to disable.",colors.lightGray)
    local answer=tostring(prompt("Monitor","1")):lower()
    local monitor=nil
    if answer=="clear" or answer=="none" then
      monitor="clear"
    else
      local index=tonumber(answer)
      if index and monitors[index] then monitor=monitors[index].name else monitor=answer end
    end
    local okSet,setErr=request("monitor-set",{monitor=monitor})
    message=okSet and (monitor=="clear" and "Monitor disabled" or "Monitor set: "..tostring(monitor)) or tostring(setErr)
  end
  local function toggleAirship(airship)
    local okMode,e=request("hardware-mode",{mode="airship",enabled=not airship})
    if not okMode and tostring(e) == "unsupported command" then
      okMode,e=request("hardware-airship",{mode="airship",enabled=not airship})
    end
    if okMode and okMode.hardware then hardware=okMode.hardware end
    if okMode then
      message="Airship mode "..(airship and "off" or "on")
    elseif tostring(e) == "unsupported command" then
      message="Update/reboot aircraft NavTool for airship mode"
    else
      message=tostring(e)
    end
  end
  while true do
    local statusResponse,statusErr=request("status")
    local status=statusResponse and statusResponse.data or nil
    local response,err=request("hardware-list")
    local hardware=response and response.hardware or {assignments={},relays={}}
    clear(colors.black); header("Hardware",err and "[ OFFLINE ]" or "[ CONFIG ]")
    writeAt(3,3,"Flight output assignments",colors.cyan)
    if err then writeAt(24,3,tostring(err):sub(1,24),colors.red) end
    if status then
      local caps=type(status.capabilities)=="table" and status.capabilities or {}
      writeAt(3,4,("Aircraft v%s  HW:%s"):format(tostring(status.version or "?"),caps.hardware==true and "yes" or "no"),caps.hardware==true and colors.lightGray or colors.red)
    elseif statusErr then
      writeAt(3,4,("Status: "..tostring(statusErr)):sub(1,45),colors.red)
    end
    if message and message ~= "" then writeAt(3,5,tostring(message):sub(1,45),colors.yellow) end
    local rowControl={}
    local y=6
    for i,control in ipairs(controls) do
      local item=hardware.assignments and hardware.assignments[control]
      local multi=item and item.targets and #item.targets>1
      rowControl[y]=i
      fill(3,y,45,1,colors.gray)
      writeAt(4,y,tostring(i)..". "..control:upper(),colors.white,colors.gray)
      local prefix=multi and (expanded[control] and "v " or "> ") or ""
      writeAt(17,y,(prefix..assignmentText(item)):sub(1,25),item and item.available~=false and colors.lime or colors.yellow,colors.gray)
      y=y+1
      if multi and expanded[control] then
        for targetIndex,target in ipairs(item.targets) do
          if y<=14 then
            fill(5,y,43,1,colors.black)
            writeAt(6,y,tostring(targetIndex)..". "..targetText(target):sub(1,36),colors.lightGray,colors.black)
            y=y+1
          end
        end
      end
    end
    local airship=hardware.modes and hardware.modes.airship == true
    local buttonY=math.min(y+1,15)
    fill(3,buttonY,18,1,colors.blue); writeAt(5,buttonY,"ADD ASSIGNMENT",colors.white,colors.blue)
    fill(24,buttonY,18,1,colors.red); writeAt(29,buttonY,"DELETE",colors.white,colors.red)
    fill(3,buttonY+2,24,1,airship and colors.lime or colors.gray)
    writeAt(5,buttonY+2,"AIRSHIP MODE: "..(airship and "ON" or "OFF"),airship and colors.black or colors.white,airship and colors.lime or colors.gray)
    writeAt(3,buttonY+1,"Relays visible: "..tostring(#(hardware.relays or {})),colors.lightGray)
    footer("Number: edit  A:add  D:delete  V:airship  M:monitor  Q:back")
    local event,a,b,c=os.pullEvent()
    local index
    local forceAdd=false
    if event=="key" then
      if a==keys.q then return end
      if a>=keys.one and a<=keys.six then index=a-keys.one+1 end
      if a==keys.a then
        local chosen=chooseControl("Control number to add")
        if chosen then index=chosen; forceAdd=true end
      end
      if a==keys.d then
        deleteAssignment(hardware)
      end
      if a==keys.v then
        toggleAirship(airship)
      end
      if a==keys.m then
        configureMonitor()
      end
      if a==keys.t then
        local chosen=tonumber(prompt("Control number to test","1"))
        if chosen and chosen%1==0 and controls[chosen] then
          local okTest,e=request("hardware-test",{control=controls[chosen],strength=5})
          message=okTest and ("Tested "..controls[chosen]) or tostring(e)
        else
          message="Invalid control number"
        end
      end
    elseif event=="mouse_click" and b>=3 and b<=20 and c==buttonY then
      local chosen=chooseControl("Control number to add")
      if chosen then index=chosen; forceAdd=true end
    elseif event=="mouse_click" and b>=24 and b<=41 and c==buttonY then
      deleteAssignment(hardware)
    elseif event=="mouse_click" and b>=3 and b<=26 and c==buttonY+2 then
      toggleAirship(airship)
    elseif event=="mouse_click" and b>=3 and b<=47 and rowControl[c] then
      local clicked=rowControl[c]
      local control=controls[clicked]
      local item=hardware.assignments and hardware.assignments[control]
      if item and item.targets and #item.targets>1 then
        for _,name in ipairs(controls) do if name~=control then expanded[name]=nil end end
        expanded[control]=not expanded[control]
      else
        index=clicked
      end
    end
    if index and controls[index] then
      local control=controls[index]
      local current=hardware.assignments and hardware.assignments[control] or {}
      local add=forceAdd==true
      local proceed=true
      add,proceed=chooseAssignmentMode(add)
      if proceed then
        local defaultKind=current.kind=="relay" and "relay" or current.targets and current.targets[1] and current.targets[1].kind=="relay" and "relay" or "local"
        local kind, cancelled=editPrompt("Device: local or relay",defaultKind)
        kind=tostring(kind):lower()
        local peripheralName=nil
        if cancelled then
          proceed=false
        elseif kind=="relay" then
          if #(hardware.relays or {})==0 then message="No redstone relays are visible"; sleep(1)
          else
            clear(colors.black); header("Choose relay")
            for i,name in ipairs(hardware.relays) do writeAt(3,i+3,tostring(i)..". "..tostring(name),colors.white) end
            local entered,cancelledRelay=editPrompt("Relay ID or list #","1")
            local chosen=tonumber(entered)
            if cancelledRelay then
              proceed=false
            elseif chosen and chosen%1==0 then
              local suffix="redstone_relay_"..tostring(chosen)
              for _,name in ipairs(hardware.relays) do
                if tostring(name)==suffix then peripheralName=name; break end
              end
              if not peripheralName and chosen>=1 and chosen<=#hardware.relays then peripheralName=hardware.relays[chosen] end
              if peripheralName then
                message="Selected "..tostring(entered).." -> "..tostring(peripheralName)
              else
                message="Invalid relay selection"
              end
            elseif entered and entered~="" then
              for _,name in ipairs(hardware.relays) do
                if tostring(name)==tostring(entered) then peripheralName=name; break end
              end
              message=peripheralName and ("Selected "..tostring(peripheralName)) or "Invalid relay selection"
            else
              message="Invalid relay selection"
            end
          end
        elseif kind~="local" then
          message="Device must be local or relay"
        end
        if proceed and (kind=="local" or peripheralName) then
          local side,cancelledSide=editPrompt("Side top/bottom/left/right/front/back",current.side or "front")
          if cancelledSide then proceed=false end
          local analogAnswer,cancelledAnalog=editPrompt("Analog output? y/n",current.analog==false and "n" or "y")
          if cancelledAnalog then proceed=false end
          local invertedAnswer,cancelledInverted=editPrompt("Inverted? y/n",current.inverted and "y" or "n")
          if cancelledInverted then proceed=false end
          local maximumAnswer,cancelledMaximum=editPrompt("Maximum strength",current.maximum or 15)
          if cancelledMaximum then proceed=false end
          local maximum=tonumber(maximumAnswer) or 15
          if proceed then
            local okAssign,e=request("hardware-assign",{
              control=control,kind=kind,peripheral=peripheralName,side=side,
              analog=tostring(analogAnswer):lower():sub(1,1)~="n",
              inverted=tostring(invertedAnswer):lower():sub(1,1)=="y",
              maximum=maximum,
              add=add,
            })
            message=okAssign and (control..(add and " assignment added" or " assigned")) or tostring(e)
          end
        end
      end
    end
  end
end]==]
local profileMarker = "local function profilesPage()"
local profileAt = source:find(profileMarker,1,true)
if profileAt then source=source:sub(1,profileAt-1)..hardwarePageSource.."\n\n"..source:sub(profileAt) end
]=]

  local marker = "if count < 4 then"
  local updated, ok = insertBefore(runtimeSource, marker, injection)
  if not ok then updated, ok = insertBefore(runtimeSource, "if count ~= 5 then", injection) end
  if not ok then updated, ok = insertBefore(runtimeSource, "local program,loadErr=load(source", injection) end
  if not ok then error("Hardware patch could not find NavRemote controller anchor") end
  return updated
end

return Patch
