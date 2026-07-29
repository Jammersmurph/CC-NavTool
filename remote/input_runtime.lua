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

local okHardwarePatch, patchedSource = pcall(function()
  return dofile(ROOT .. "/hardware_patch.lua").apply(runtimeSource)
end)
if okHardwarePatch and type(patchedSource) == "string" then
  runtimeSource = patchedSource
end

local injected = table.concat({
  '-- NavRemote input compatibility is applied to the generated controller source.',
  'source = source:gsub("Esc: back", "Q: back")',
  'source = source:gsub("Esc: cancel", "Q: cancel")',
  'source = source:gsub("Esc:back", "Q:back")',
  'source = source:gsub("keys%.escape", "keys.q")',
  'source = source:gsub("Q: quit", "X: quit")',
  'source = source:gsub("if key==keys%.q then clear%(colors%.black%); return", "if key==keys.x then clear(colors.black); return", 1)',
  '',
  '-- Open every attached modem so local wireless/wired modems cannot hide an Ender modem.',
  'local oldOpenModem = [=[local function openModem()',
  '  for _, side in ipairs(peripheral.getNames()) do',
  '    if peripheral.getType(side) == "modem" then',
  '      if not rednet.isOpen(side) then rednet.open(side) end',
  '      return true',
  '    end',
  '  end',
  '  return false',
  'end]=]',
  'local allModemsOpen = [=[local function openModem()',
  '  local opened = false',
  '  for _, side in ipairs(peripheral.getNames()) do',
  '    if peripheral.getType(side) == "modem" then',
  '      local ok = rednet.isOpen(side) or pcall(rednet.open, side)',
  '      if ok then opened = true end',
  '    end',
  '  end',
  '  return opened',
  'end]=]',
  'local modemPatchApplied',
  'source,modemPatchApplied=replacePlainOnce(source,oldOpenModem,allModemsOpen)',
  'if not modemPatchApplied then printError("NavRemote could not install multi-modem support."); return end',
  '',
  '-- Aircraft status is dashboard-only. Active route/schedule polling remains internal.',
  'local timerBranch = [=[  if event=="timer" and a==refreshTimer then',
  '    if data.preferences.autoRefresh~=false then local status=refresh(data,true); advanceAutomation(data,status) end',
  '    refreshTimer=os.startTimer(1)',
  '  elseif event=="key" then]=]',
  'local automationTimerBranch = [=[  if event=="timer" and a==refreshTimer then',
  '    if data.activeRoute or data.activeSchedule then local status=refresh(data,true); advanceAutomation(data,status) end',
  '    refreshTimer=os.startTimer(1)',
  '  elseif event=="key" then]=]',
  'source = select(1, replacePlainOnce(source, timerBranch, automationTimerBranch))',
  'local desktopRefresh = [=[    elseif key==keys.r then local status,err=refresh(data); message=err or (status and "Telemetry refreshed" or "No telemetry")',
  ']=]',
  'source = select(1, replacePlainOnce(source, desktopRefresh, ""))',
  'source = source:gsub("  R: refresh", "")',
  '',
  'local newActivateTarget = [=[local function activateTarget(data,target)',
  '  data.target=target',
  '  data.activeRoute=nil',
  '  data.activeSchedule=nil',
  '  saveData(data)',
  '  request("stop-follow")',
  '  local ok,err=request("set-target",{target=target})',
  '  if ok then ok,err=request("set-mode",{mode="navigate"}) end',
  '  if ok then message="Navigating to "..tostring(target.name or "target"); Storage.log(data,"INFO",message)',
  '  else message=err or "Target rejected"; Storage.log(data,"WARN",message) end',
  '  saveData(data)',
  'end]=]',
  'local activateStart=source:find("local function activateTarget(data,target)",1,true)',
  'local targetsStart=source:find("local function targetsPage",activateStart or 1,true)',
  'if activateStart and targetsStart then source=source:sub(1,activateStart-1)..newActivateTarget.."\\n\\n"..source:sub(targetsStart) end',
  '',
  'local newSettings = [=[local function settingsPage(data)',
  '  while true do',
  '    clear(colors.black); header("Settings")',
  '    data.preferences=data.preferences or {}',
  '    writeAt(3,4,"1. Arrival radius",colors.cyan); writeAt(25,4,tostring(data.preferences.arrivalRadius or 5))',
  '    writeAt(3,5,"2. Manual strength",colors.cyan); writeAt(25,5,tostring(data.preferences.manualStrength or 2))',
  '    writeAt(3,6,"3. Monitor telemetry",colors.cyan); writeAt(25,6,data.preferences.monitorTelemetry==true and "on" or "off")',
  '    writeAt(3,8,"Aircraft status is checked only in Dashboard.",colors.lightGray)',
  '    writeAt(3,9,"Maintenance",colors.lightGray)',
  '    fill(3,11,18,3,colors.gray); writeAt(8,12,"UPDATE",colors.white,colors.gray)',
  '    fill(24,11,18,3,colors.red); writeAt(28,12,"UNINSTALL",colors.white,colors.red)',
  '    footer("Click buttons or U:update  D:uninstall  Q:back")',
  '    local event,a,b,c=os.pullEvent()',
  '    local action=nil',
  '    if event=="key" then',
  '      if a==keys.q then saveData(data); return',
  '      elseif a==keys.one then action="radius"',
  '      elseif a==keys.two then action="strength"',
  '      elseif a==keys.three then action="monitor"',
  '      elseif a==keys.u then action="update"',
  '      elseif a==keys.d then action="uninstall" end',
  '    elseif event=="mouse_click" then',
  '      if b>=3 and b<=20 and c>=11 and c<=13 then action="update"',
  '      elseif b>=24 and b<=41 and c>=11 and c<=13 then action="uninstall" end',
  '    end',
  '    if action=="radius" then data.preferences.arrivalRadius=tonumber(prompt("Arrival radius",data.preferences.arrivalRadius or 5)) or 5',
  '    elseif action=="strength" then data.preferences.manualStrength=math.max(1,math.min(15,tonumber(prompt("Manual strength",data.preferences.manualStrength or 2)) or 2))',
  '    elseif action=="monitor" then data.preferences.monitorTelemetry=not (data.preferences.monitorTelemetry==true); if not data.preferences.monitorTelemetry and clearLocalMonitors then clearLocalMonitors() end',
  '    elseif action=="update" then',
  '      if confirm("Update NavRemote and reboot") then',
  '        saveData(data)',
  '        clear(colors.black); header("Updating NavRemote")',
  '        local ok=shell.run(ROOT.."/update.lua")',
  '        if ok then print("Update complete. Rebooting..."); sleep(1); os.reboot() else printError("Update failed"); sleep(2) end',
  '      end',
  '    elseif action=="uninstall" then',
  '      if confirm("Uninstall NavRemote and reboot") then',
  '        clear(colors.black); header("Uninstalling NavRemote")',
  '        local ok=shell.run(ROOT.."/uninstall.lua")',
  '        if ok then print("NavRemote removed. Rebooting..."); sleep(1); os.reboot() else printError("Uninstall failed"); sleep(2) end',
  '      end',
  '    end',
  '    if action=="radius" or action=="strength" or action=="monitor" then saveData(data) end',
  '  end',
  'end]=]',
  'local settingsStart=source:find("local function settingsPage(data)",1,true)',
  'local automationStart=source:find("local function advanceAutomation",settingsStart or 1,true)',
  'if settingsStart and automationStart then source=source:sub(1,settingsStart-1)..newSettings.."\\n\\n"..source:sub(automationStart) end',
  '',
  'local pageDispatcher = [=[local function openSelectedPage(data)',
  '  local id=icons[selected].id',
  '  if id=="dashboard" then dashboard(data)',
  '  elseif id=="targets" then targetsPage(data)',
  '  elseif id=="routes" then pathPage(data,"Route")',
  '  elseif id=="schedules" then schedulePage(data)',
  '  elseif id=="modes" then modesPage(data)',
  '  elseif id=="manual" then manualPage()',
  '  elseif id=="profiles" then profilesPage()',
  '  elseif id=="logs" then logsPage(data)',
  '  elseif id=="settings" then settingsPage(data)',
  '  elseif id=="hardware" and hardwarePage then hardwarePage(data) end',
  'end]=]',
  'local uiBridge = [=[_ENV.clear=clear',
  '_ENV.header=header',
  '_ENV.writeAt=writeAt',
  '_ENV.footer=footer',
  '_ENV.waitBack=waitBack]=]',
  'local dispatchAnchor = "if not term.isColor() then"',
  'local dispatchPos = source:find(dispatchAnchor, 1, true)',
  'if dispatchPos then source = source:sub(1,dispatchPos-1)..uiBridge.."\\n"..pageDispatcher.."\\n\\n"..source:sub(dispatchPos) end',
  '',
  'source = select(1, replacePlainOnce(source, "local event,a=os.pullEvent()", "local event,a,b,c=os.pullEvent()"))',
  'source = select(1, replacePlainOnce(source, "local refreshTimer=os.startTimer(1)", "local refreshTimer=os.startTimer(5)"))',
  'source = source:gsub("elseif key==keys%.left and selected>1 then selected=selected%-1", "elseif key==keys.left and (selected-1)%%4>0 then selected=selected-1", 1)',
  'source = source:gsub("elseif key==keys%.right and selected<#icons then selected=selected%+1", "elseif key==keys.right and selected<#icons and selected%%4~=0 then selected=selected+1", 1)',
  'source = source:gsub("elseif key==keys%.up and selected>3 then selected=selected%-3", "elseif key==keys.up and selected>4 then selected=selected-4", 1)',
  'source = source:gsub("elseif key==keys%.down and selected%+3<=#icons then selected=selected%+3", "elseif key==keys.down and selected+4<=#icons then selected=selected+4", 1)',
  'source = source:gsub("refreshTimer=os%.startTimer%(1%)", "refreshTimer=os.startTimer((data.activeRoute or data.activeSchedule) and 1 or 5)", 1)',
  'local enterStart=source:find("    elseif key==keys.enter then",1,true)',
  'local enterEnd=source:find("    end\\n    data.preferences.selectedIcon=selected",enterStart or 1,true)',
  'if enterStart and enterEnd then source=source:sub(1,enterStart-1).."    elseif key==keys.enter then openSelectedPage(data)\\n"..source:sub(enterEnd) end',
  'local keyAnchor = [[  elseif event=="key" then',
  '    local key=a]]',
  'local mouseBranch = [[  elseif event=="mouse_click" then',
  '    local mouseX,mouseY=b,c',
  '    local opened=false',
  '    for index=1,#icons do',
  '      local iconX,iconY=iconPosition(index)',
  '      if mouseX>=iconX-1 and mouseX<=iconX+7 and mouseY>=iconY-1 and mouseY<=iconY+3 then',
  '        selected=index',
  '        data.preferences.selectedIcon=selected',
  '        saveData(data)',
  '        openSelectedPage(data)',
  '        opened=true',
  '        break',
  '      end',
  '    end',
  '  elseif event=="key" then',
  '    local key=a]]',
  'source = select(1, replacePlainOnce(source, keyAnchor, mouseBranch))',
}, "\n")

local anchor = "if count < 4 then"
local at = runtimeSource:find(anchor, 1, true)
if not at then anchor = "if count ~= 5 then"; at = runtimeSource:find(anchor, 1, true) end
if not at then anchor = "local program,loadErr=load(source"; at = runtimeSource:find(anchor, 1, true) end
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
