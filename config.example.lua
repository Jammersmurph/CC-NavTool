-- CC-NavTool default configuration
-- Copy to /navtool/config.lua and edit for your craft.
return {
  updateInterval = 0.10,
  telemetryPeripheral = nil,
  monitorPeripheral = nil,
  safety = {
    maximumOutput = 5,
    maximumRemotePulse = 2.0,
    disengageOnTelemetryLoss = true,
    clearOutputsOnExit = true,
  },
  network = {
    enabled = true,
    channel = "cc-navtool",
    host = "navtool-aircraft",
    sharedKey = "change-me", -- CHANGE THIS on both aircraft and pocket computer.
  },
  navigation = {
    cruiseSpeed = 12,
    approachSpeed = 4,
    slowdownRadius = 50,
    arrivalRadius = 5,
    stopSpeed = 0.5,
  },
  orientation = {
    -- Local computer-space direction for the screen face. The Sable quaternion
    -- rotates this into world space, so ship-forward is not fixed to world Z.
    -- Mount the computer screen toward the ship's intended forward direction.
    forward = { x = 0, y = 0, z = -1 },
    up = { x = 0, y = 1, z = 0 },
  },
  outputs = {},
}
