return {
  onboardingComplete = false,
  updateInterval = 0.05,
  networkUpdateInterval = 0.25,

  -- CC: Sable is required. CC-NavTool reads pose, quaternion orientation,
  -- linear velocity, angular velocity, and available physics data from sublevel.
  sublevelEnabled = true,

  -- Optional Create: Avionics peripherals. These may enrich diagnostics and status
  -- displays, but they are not used to satisfy the flight-control telemetry contract.
  navigationTablePeripheral = nil,
  gimbalSensorPeripheral = nil,
  altitudeSensorPeripheral = nil,
  physicsAssemblerPeripheral = nil,
  monitorPeripheral = nil,

  safety = {
    maximumOutput = 15,
    maximumRemotePulse = 2.0,
    disengageOnTelemetryLoss = true,
    clearOutputsOnExit = true,
  },
  hardware = {
    airshipMode = false,
    airshipArrivedPower = 2,
    airshipReturnDrift = 5,
  },
  navigation = {
    cruiseSpeed = 12,
    approachSpeed = 4,
    precisionSpeed = 0.35,
    slowdownRadius = 50,
    precisionRadius = 3,
    coordinateTolerance = 0.05,
    verticalTolerance = 0.05,
    settleVelocity = 0.5,
    arrivalRadius = 1,
    brakeRadius = 75,
    finalOutputRadius = 10,
    headingTolerance = 4,
    cruiseHeadingTolerance = 25,
    airshipArrivalRadius = 6,
    airshipVerticalTolerance = 8,
    airshipHeadingTolerance = 15,
    airshipSettleVelocity = 2.0,
    finalOutputMaximum = 2,
    finalVerticalRadius = 15,
    finalVerticalOutputMaximum = 2,
    finalVerticalUpOutputMaximum = 3,
    stopSpeed = 0.5,

    -- Staged altitude navigation:
    -- While outside the horizontal transition radius, enter the cruise band via Y=350.
    -- Once inside the band, horizontal travel holds current altitude to avoid bobbing.
    -- Normal targets switch to their requested Y within 3 horizontal blocks.
    -- Follow targets switch to player Y+10 within 10 horizontal blocks.
    cruiseAltitude = 310,
    cruiseAltitudeTolerance = 1,
    cruiseAltitudeMinimum = 310,
    cruiseAltitudeMaximum = 500,
    verticalTransitionRadius = 3,
    followHorizontalRadius = 10,
    followHeightOffset = 10,
  },
  automation = {
    altitudeDeadband = 1.5,
    verticalScale = 12,
    thrustStartDistance = 8,
    thrustFullDistance = 50,
    steeringDeadband = 0.12,
    steeringScale = 0.8,
    steeringInvert = false,
    pulseAutomationOutputs = true,
    outputPulsePeriod = 0.4,
    outputPulseWidth = 0.3,
    outputHoldAfter = 0.6,
    outputPulseReleaseGrace = 0.25,
    outputHoldReleaseGrace = 1.0,
  },
  flightControl = {
    enabled = true,
    interval = 0.05,
    minimumThrustAlignment = 0.9,
    minimumYawOutput = 1,
    minimumForwardOutput = 2,
    hoverVelocityGain = 0.18,
    headingPID = {
      kp = 1.6, ki = 0.02, kd = 0.45,
      minimum = -1, maximum = 1,
      integralMinimum = -0.5, integralMaximum = 0.5,
      derivativeFilter = 0.65,
    },
    altitudePID = {
      kp = 0.12, ki = 0.01, kd = 0.18,
      minimum = -1, maximum = 1,
      integralMinimum = -0.5, integralMaximum = 0.5,
      derivativeFilter = 0.65,
    },
    speedPID = {
      kp = 0.16, ki = 0.015, kd = 0.08,
      minimum = -1, maximum = 1,
      integralMinimum = -0.5, integralMaximum = 0.5,
      derivativeFilter = 0.65,
    },
    positionPID = {
      kp = 0.45, ki = 0.015, kd = 0.35,
      minimum = -0.45, maximum = 0.45,
      integralMinimum = -0.3, integralMaximum = 0.3,
      derivativeFilter = 0.7,
    },
    positionVerticalPID = {
      kp = 0.22, ki = 0.012, kd = 0.3,
      minimum = -0.5, maximum = 0.5,
      integralMinimum = -0.25, integralMaximum = 0.25,
      derivativeFilter = 0.7,
    },
    recorder = {
      enabled = true,
      flushInterval = 2,
      maximumBuffer = 40,
    },
  },
  orientation = {
    -- Local computer-space direction for the screen face. The Sable quaternion
    -- rotates this into world space, so ship-forward is not fixed to world Z.
    -- Mount the computer screen toward the ship's intended forward direction.
    forward = { x = 0, y = 0, z = 1 },
    up = { x = 0, y = 1, z = 0 },
    yawOffset = 0,
  },
  network = {
    enabled = false,
    channel = "cc-navtool",
    host = "navtool-aircraft",
    sharedKey = "",
  },
  -- This option is offered only when Rednet is enabled during first-run setup.
  -- It requires a wireless or Ender modem and a working GPS network.
  locationTracking = {
    enabled = false,
    port = 9999,
    timeout = 12,
  },
  outputs = {},
}
