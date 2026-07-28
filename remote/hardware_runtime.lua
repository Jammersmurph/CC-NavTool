local ROOT = "/navremote"
local args = { ... }

-- Compatibility shim: the old Hardware page was injected through a fragile
-- runtime patch chain. Keep this entry point safe while NavRemote uses the
-- normal input/controller runtime directly.
return shell.run(ROOT .. "/input_runtime.lua", table.unpack(args))
