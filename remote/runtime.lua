local ROOT = "/navremote"
local args = { ... }
local Beacon = dofile(ROOT .. "/location_beacon.lua")

local file = fs.open(ROOT .. "/controller.lua", "r")
if not file then printError("Could not open NavRemote controller"); return end
local source = file.readAll()
file.close()

local replacement = [[local function modesPage()
  local modes={"standby","navigate","hover","return-home"}
  clear(colors.black); header("Flight modes")
  for i,mode in ipairs(modes) do writeAt(4,i+3,tostring(i)..". "..mode,colors.white) end
  writeAt(4,9,"F. Follow a NavRemote",colors.cyan)
  writeAt(4,10,"H. Auto Home to NavRemote",colors.cyan)
  writeAt(4,11,"S. Stop following",colors.cyan)
  footer("1-4: mode  F:follow  H:home  S:stop  Esc:back")

  local function chooseRemote()
    local response,err=request("location-list")
    if not response then message=err or "Location tracking unavailable"; return end
    local remotes=response.remotes or {}
    if #remotes==0 then message="No NavRemote locations received"; return end
    clear(colors.black); header("Located NavRemotes")
    for i,item in ipairs(remotes) do
      if i>10 then break end
      writeAt(3,i+3,tostring(i)..". "..tostring(item.label).."  ID "..tostring(item.id),colors.white)
      writeAt(28,i+3,string.format("%.0f %.0f %.0f",item.x,item.y,item.z),colors.lightGray)
    end
    footer("Number: select  Esc: cancel")
    while true do
      local _,key=os.pullEvent("key")
      if key==keys.escape then return end
      local index=key-keys.one+1
      if remotes[index] then return remotes[index] end
    end
  end

  while true do
    local _,key=os.pullEvent("key")
    if key==keys.escape then return end
    local index=key-keys.one+1
    if modes[index] then
      local ok,err=request("set-mode",{mode=modes[index]})
      message=ok and ("Mode: "..modes[index]) or err
      return
    elseif key==keys.f or key==keys.h then
      local remote=chooseRemote()
      if remote then
        local command=key==keys.f and "follow-remote" or "auto-home"
        local ok,err=request(command,{remote=remote.id})
        message=ok and ((key==keys.f and "Following " or "Homing to ")..remote.label) or err
      end
      return
    elseif key==keys.s then
      local ok,err=request("stop-follow")
      if ok then request("set-mode",{mode="standby"}); request("outputs-off") end
      message=ok and "Follow stopped" or err
      return
    end
  end
end

local function manualPage]]

local changed
source, changed = source:gsub("local function modesPage%(%)%s.-end\n\nlocal function manualPage", replacement, 1)
if changed ~= 1 then
  printError("NavRemote runtime compatibility check failed.")
  printError("Could not install Follow and Auto Home controls.")
  return
end

local program, err = load(source, "@" .. ROOT .. "/controller.lua", "t", _ENV)
if not program then printError("Could not load NavRemote: " .. tostring(err)); return end

parallel.waitForAny(
  function() return program(table.unpack(args)) end,
  function() return Beacon.run() end
)
