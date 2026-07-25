local ROOT = "/navtool"
local LAUNCHER = "/navtool.lua"

local function clearOutputs()
  local configPath = ROOT .. "/config.lua"
  if not fs.exists(configPath) then return end
  local ok, config = pcall(dofile, configPath)
  if not ok or type(config) ~= "table" or type(config.outputs) ~= "table" then return end
  local cleared = {}
  for _, output in pairs(config.outputs) do
    if type(output) == "table" and output.side and not cleared[output.side] then
      pcall(redstone.setAnalogOutput, output.side, 0)
      pcall(redstone.setOutput, output.side, false)
      cleared[output.side] = true
    end
  end
end

print("This will completely remove onboard CC-NavTool.")
print("It deletes config, targets, waypoints, logs, and launchers.")
write("Continue? [y/N] ")
local answer = read():lower()
if answer ~= "y" and answer ~= "yes" then print("Uninstall cancelled."); return end

clearOutputs()
if fs.exists(ROOT) then fs.delete(ROOT) end
if fs.exists(LAUNCHER) then fs.delete(LAUNCHER) end
print("Onboard CC-NavTool uninstalled.")
