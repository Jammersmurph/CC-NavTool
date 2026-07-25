local ROOT = "/navremote"
local LAUNCHER = "/navremote.lua"

print("This will completely remove CC-NavTool Remote.")
print("It deletes config and launcher files.")
write("Continue? [y/N] ")
local answer = read():lower()
if answer ~= "y" and answer ~= "yes" then print("Uninstall cancelled."); return end

if fs.exists(ROOT) then fs.delete(ROOT) end
if fs.exists(LAUNCHER) then fs.delete(LAUNCHER) end
print("CC-NavTool Remote uninstalled.")
