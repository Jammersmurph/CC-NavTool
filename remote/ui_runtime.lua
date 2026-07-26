local ROOT = "/navremote"
local SOURCE = ROOT .. "/controller_runtime.lua"

local file = fs.open(SOURCE, "r")
if not file then printError("Could not open " .. SOURCE); return end
local source = file.readAll()
file.close()

local injection = [[
-- Minecraft consumes Escape to close the computer screen, so NavRemote uses Q to
-- return from pages and X to exit the desktop. Apply this after all controller
-- compatibility replacements have been generated.
source = source:gsub("Esc: back", "Q: back")
source = source:gsub("Esc: cancel", "Q: cancel")
source = source:gsub("Esc:back", "Q:back")
source = source:gsub("keys%%.escape", "keys.q")
source = source:gsub("Q: quit", "X: quit")
source = source:gsub("if key==keys%%.q then clear%(colors%%.black%); return", "if key==keys.x then clear(colors.black); return", 1)

-- Mouse support for the nine desktop launcher icons on Advanced Computers.
source = source:gsub("local event,a=os%%.pullEvent%(%)", "local event,a,b,c=os.pullEvent()", 1)
source = source:gsub('  elseif event=="key" then', [[  elseif event=="mouse_click" then
    local mouseX,mouseY=b,c
    for index=1,#icons do
      local iconX,iconY=iconPosition(index)
      if mouseX>=iconX-1 and mouseX<=iconX+6 and mouseY>=iconY-1 and mouseY<=iconY+3 then
        selected=index
        local id=icons[selected].id
        if id=="dashboard" then dashboard(data)
        elseif id=="targets" then targetsPage(data)
        elseif id=="routes" then pathPage(data,"Route")
        elseif id=="schedules" then pathPage(data,"Schedule")
        elseif id=="modes" then modesPage(data)
        elseif id=="manual" then manualPage()
        elseif id=="profiles" then profilesPage()
        elseif id=="logs" then logsPage(data)
        elseif id=="settings" then settingsPage(data) end
        data.preferences.selectedIcon=selected
        saveData(data)
        break
      end
    end
  elseif event=="key" then]], 1)
]]

local anchor = "if count ~= 5 then"
local first = source:find(anchor, 1, true)
if not first then
  printError("NavRemote input compatibility patch could not find its anchor.")
  return
end
source = source:sub(1, first - 1) .. injection .. "\n" .. source:sub(first)

local program, err = load(source, "@" .. SOURCE, "t", _ENV)
if not program then printError("Could not load NavRemote input runtime: " .. tostring(err)); return end
return program(...)
