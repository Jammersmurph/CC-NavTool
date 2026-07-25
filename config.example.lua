-- CC-NavTool default configuration
-- Copy to /navtool/config.lua and edit for your craft.
return {
  updateInterval = 0.10,
  telemetryPeripheral = nil,
  monitorPeripheral = nil,
  safety = {
    maximumOutput = 5,
    disengageOnTelemetryLoss = true,
    clearOutputsOnExit = true,
  },
  navigation = {
    cruiseSpeed = 12,
    approachSpeed = 4,
    slowdownRadius = 50,
    arrivalRadius = 5,
    stopSpeed = 0.5,
  },
  orientation = {
    forward = { x = 0, y = 0, z = -1 },
    up = { x = 0, y = 1, z = 0 },
  },
  outputs = {
    forward = { side = "front", analog = true, inverted = false, maximum = 5 },
    reverse = { side = "back", analog = true, inverted = false, maximum = 5 },
    left = { side = "left", analog = true, inverted = false, maximum = 5 },
    right = { side = "right", analog = true, inverted = false, maximum = 5 },
    up = { side = "top", analog = true, inverted = false, maximum = 5 },
    down = { side = "bottom", analog = true, inverted = false, maximum = 5 },
  },
}
