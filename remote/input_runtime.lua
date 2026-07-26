local ROOT = "/navremote"
local SOURCE = ROOT .. "/controller_runtime.lua"

local function readAll(path)
  local file = fs.open(path, "r")
  if not file then return nil, "Could not open " .. path end
  local text = file.readAll()
  file.close()
  return text
end

local function replacePlainOnce(text, needle, replacement)
  local first, last = text:find(needle, 1, true)
  if not first then return text, false end
  return text:sub(1, first - 1) .. replacement .. text:sub(last + 1), true
end

local runtimeSource, err = readAll(SOURCE)
if not runtimeSource then printError(err); return end

local injected = table.concat({
  '-- NavRemote input compatibility is applied to the generated controller source.',
  'source = source:gsub("Esc: back", "Q: back")',
  'source = source:gsub("Esc: cancel", "Q: cancel")',
  'source = source:gsub("Esc:back", "Q:back")',
  'source = source:gsub("keys%.escape", "keys.q")',
  'source = source:gsub("Q: quit", "X: quit")',
  'source = source:gsub("if key==keys%.q then clear%(colors%.black%); return", "if key==keys.x then clear(colors.black); return", 1)',
  '',
  'local pageDispatcher = [=[local function openSelectedPage(data)',
  '  local id=icons[selected].id',
  '  if id=="dashboard" then dashboard(data)',
  '  elseif id=="targets" then targetsPage(data)',
  '  elseif id=="routes" then pathPage(data,"Route")',
  '  elseif id=="schedules" then pathPage(data,"Schedule")',
  '  elseif id=="modes" then modesPage(data)',
  '  elseif id=="manual" then manualPage()',
  '  elseif id=="profiles" then profilesPage()',
  '  elseif id=="logs" then logsPage(data)',
  '  elseif id=="settings" then settingsPage(data) end',
  'end]=]',
  'local dispatchAnchor = "if not term.isColor() then"',
  'local dispatchPos = source:find(dispatchAnchor, 1, true)',
  'if dispatchPos then source = source:sub(1,dispatchPos-1)..pageDispatcher.."\\n\\n"..source:sub(dispatchPos) end',
  '',
  'source = select(1, replacePlainOnce(source, "local event,a=os.pullEvent()", "local event,a,b,c=os.pullEvent()"))',
  'local keyAnchor = [[  elseif event=="key" then',
  '    local key=a]]',
  'local mouseBranch = [[  elseif event=="mouse_click" then',
  '    local mouseX,mouseY=b,c',
  '    for index=1,#icons do',
  '      local iconX,iconY=iconPosition(index)',
  '      if mouseX>=iconX-1 and mouseX<=iconX+6 and mouseY>=iconY-1 and mouseY<=iconY+3 then',
  '        selected=index',
  '        data.preferences.selectedIcon=selected',
  '        saveData(data)',
  '        openSelectedPage(data)',
  '        break',
  '      end',
  '    end',
  '  elseif event=="key" then',
  '    local key=a]]',
  'source = select(1, replacePlainOnce(source, keyAnchor, mouseBranch))',
}, "\n")

local anchor = "if count ~= 5 then"
local at = runtimeSource:find(anchor, 1, true)
if not at then printError("NavRemote input runtime could not find controller patch anchor."); return end
runtimeSource = runtimeSource:sub(1, at - 1) .. injected .. "\n" .. runtimeSource:sub(at)

local oldRun = "return program(...)"
local protectedRun = table.concat({
  "local runtimeArgs={...}",
  "local ok,result=xpcall(function() return program(table.unpack(runtimeArgs)) end,function(problem)",
  "  return tostring(problem)..'\\n'..debug.traceback('',2)",
  "end)",
  "if not ok then",
  "  term.setBackgroundColor(colors.black); term.setTextColor(colors.red); term.clear(); term.setCursorPos(1,1)",
  "  print('NavRemote crashed:')", 
  "  term.setTextColor(colors.white); print(result)",
  "  print('Press any key to return to the shell.')", 
  "  os.pullEvent('key')",
  "  return false",
  "end",
  "return result",
}, "\n")
runtimeSource = select(1, replacePlainOnce(runtimeSource, oldRun, protectedRun))

local program, loadErr = load(runtimeSource, "@" .. SOURCE, "t", _ENV)
if not program then printError("Could not load NavRemote input runtime: " .. tostring(loadErr)); return end
return program(...)
