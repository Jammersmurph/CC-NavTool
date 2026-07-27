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

-- Ten launcher entries need a four-column grid on the 51x19 Advanced Computer.
local oldIconPosition = [[local function iconPosition(index)
  local col=(index-1)%3
  local row=math.floor((index-1)/3)
  return 16+col*12,3+row*5
end]]
local compactIconPosition = [[local function iconPosition(index)
  local col=(index-1)%4
  local row=math.floor((index-1)/4)
  return 14+col*9,3+row*5
end]]
source = select(1, replacePlainOnce(source, oldIconPosition, compactIconPosition))
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
  while true do
    local response,err=request("hardware-list")
    local hardware=response and response.hardware or {assignments={},relays={}}
    clear(colors.black); header("Hardware",err and "[ OFFLINE ]" or "[ CONFIG ]")
    writeAt(3,3,"Flight output assignments",colors.cyan)
    local rowControl={}
    local y=5
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
    local buttonY=math.min(y+1,15)
    fill(3,buttonY,18,1,colors.blue); writeAt(5,buttonY,"ADD ASSIGNMENT",colors.white,colors.blue)
    fill(24,buttonY,18,1,colors.red); writeAt(29,buttonY,"DELETE",colors.white,colors.red)
    writeAt(3,buttonY+1,"Relays visible: "..tostring(#(hardware.relays or {})),colors.lightGray)
    footer("+N/row text: expand  Number: edit  A:add  D:delete  Q:back")
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
    elseif event=="mouse_click" and b>=3 and b<=47 and rowControl[c] then
      local clicked=rowControl[c]
      local control=controls[clicked]
      local item=hardware.assignments and hardware.assignments[control]
      if b>=17 and item and item.targets and #item.targets>1 then
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
      if not add then
        local mode, cancelled=editPrompt("Assignment: replace or add","replace")
        mode=tostring(mode):lower()
        if cancelled then proceed=false
        elseif mode=="add" then add=true
        elseif mode~="replace" then message="Assignment must be replace or add"; sleep(1); proceed=false end
      end
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

  local marker = "if count ~= 5 then"
  local updated, ok = insertBefore(runtimeSource, marker, injection)
  if not ok then error("Hardware patch could not find NavRemote controller anchor") end
  return updated
end

return Patch
