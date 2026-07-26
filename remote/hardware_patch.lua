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

local hardwarePageSource = [==[local function hardwarePage(data)
  local controls={"forward","reverse","left","right","up","down"}
  local function assignmentText(item)
    if not item or item.kind=="unassigned" then return "UNASSIGNED" end
    if item.kind=="relay" then return tostring(item.peripheral)..":"..tostring(item.side) end
    return "LOCAL:"..tostring(item.side)
  end
  while true do
    local response,err=request("hardware-list")
    local hardware=response and response.hardware or {assignments={},relays={}}
    clear(colors.black); header("Hardware",err and "[ OFFLINE ]" or "[ CONFIG ]")
    writeAt(3,3,"Flight output assignments",colors.cyan)
    for i,control in ipairs(controls) do
      local y=i+4
      local item=hardware.assignments and hardware.assignments[control]
      fill(3,y,45,1,colors.gray)
      writeAt(4,y,tostring(i)..". "..control:upper(),colors.white,colors.gray)
      writeAt(17,y,assignmentText(item):sub(1,25),item and item.available~=false and colors.lime or colors.yellow,colors.gray)
    end
    writeAt(3,13,"Relays visible: "..tostring(#(hardware.relays or {})),colors.lightGray)
    footer("Click row or 1-6: assign  T:test  Q:back")
    local event,a,b,c=os.pullEvent()
    local index
    if event=="key" then
      if a==keys.q then return end
      if a>=keys.one and a<=keys.six then index=a-keys.one+1 end
      if a==keys.t then
        local chosen=tonumber(prompt("Control number to test","1"))
        if chosen and controls[chosen] then
          local okTest,e=request("hardware-test",{control=controls[chosen],strength=5})
          message=okTest and ("Tested "..controls[chosen]) or tostring(e)
        end
      end
    elseif event=="mouse_click" and b>=3 and b<=47 and c>=5 and c<=10 then
      index=c-4
    end
    if index and controls[index] then
      local control=controls[index]
      local current=hardware.assignments and hardware.assignments[control] or {}
      local kind=prompt("Device: local or relay",current.kind=="relay" and "relay" or "local")
      local peripheralName=nil
      if kind=="relay" then
        if #(hardware.relays or {})==0 then message="No redstone relays are visible"; sleep(1)
        else
          clear(colors.black); header("Choose relay")
          for i,name in ipairs(hardware.relays) do writeAt(3,i+3,tostring(i)..". "..tostring(name),colors.white) end
          local chosen=tonumber(prompt("Relay number","1"))
          peripheralName=hardware.relays[chosen or 0]
        end
      end
      if kind=="local" or peripheralName then
        local side=prompt("Side top/bottom/left/right/front/back",current.side or "front")
        local analogAnswer=prompt("Analog output? y/n",current.analog==false and "n" or "y")
        local invertedAnswer=prompt("Inverted? y/n",current.inverted and "y" or "n")
        local maximum=tonumber(prompt("Maximum strength",current.maximum or 15)) or 15
        local okAssign,e=request("hardware-assign",{
          control=control,kind=kind,peripheral=peripheralName,side=side,
          analog=tostring(analogAnswer):lower():sub(1,1)~="n",
          inverted=tostring(invertedAnswer):lower():sub(1,1)=="y",
          maximum=maximum,
        })
        message=okAssign and (control.." assigned") or tostring(e)
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
