local ROOT = "/navremote"
local SOURCE = ROOT .. "/input_runtime.lua"

local file = fs.open(SOURCE, "r")
if not file then printError("Could not open " .. SOURCE); return false end
local source = file.readAll()
file.close()

local readAnchor = 'if not runtimeSource then printError(err); return end'
local injected = readAnchor .. [[
local okHardwarePatch, patchedSource = pcall(function()
  return dofile(ROOT .. "/hardware_patch.lua").apply(runtimeSource)
end)
if okHardwarePatch and type(patchedSource) == "string" then
  runtimeSource = patchedSource
else
  _NAVREMOTE_HARDWARE_PATCH_ERROR = tostring(patchedSource)
end]]
local first,last = source:find(readAnchor,1,true)
if not first then printError("Hardware runtime could not find controller source anchor."); return false end
source = source:sub(1,first-1)..injected..source:sub(last+1)

local dispatcher = [[  '  elseif id=="settings" then settingsPage(data) end',]]
local extended = [[  '  elseif id=="settings" then settingsPage(data)',
  '  elseif id=="hardware" then hardwarePage(data) end',]]
first,last = source:find(dispatcher,1,true)
if not first then printError("Hardware runtime could not extend page dispatcher."); return false end
source = source:sub(1,first-1)..extended..source:sub(last+1)

local program, err = load(source, "@" .. SOURCE, "t", _ENV)
if not program then printError("Could not load NavRemote hardware runtime: " .. tostring(err)); return false end
return program(...)
