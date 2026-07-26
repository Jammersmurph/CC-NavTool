# CC: Sable Quaternion Orientation

CC-NavTool prefers CC: Sable pose telemetry when the onboard computer is running on a Sable sub-level. This allows the autopilot to determine the craft's orientation while stationary and makes Create: Avionics optional for basic position and heading detection.

## Telemetry priority

The current development controller uses the following effective priority:

1. CC: Sable pose quaternion and position
2. Create: Avionics navigation-table heading
3. Existing legacy/GPS heading fallbacks

Create: Avionics remains useful for altitude, gimbal, physics-assembler, and velocity-sensor data. It is no longer required solely to determine which direction the craft is facing when Sable pose orientation is available.

## Sable quaternion format

The Sable pose orientation used by current builds is represented as a scalar-vector quaternion:

```lua
local pose = sublevel.getLastPose()
local q = pose.orientation

local w = q.a
local x = q.v.x
local y = q.v.y
local z = q.v.z
```

CC-NavTool normalizes the quaternion before using it. It also accepts common `w/x/y/z` and indexed representations as defensive fallbacks.

## How orientation is used

The configured aircraft-local axes are rotated through the quaternion:

```lua
orientation = {
  forward = { x = 0, y = 0, z = -1 },
  up = { x = 0, y = 1, z = 0 },
}
```

From these two vectors, CC-NavTool derives the local right axis and produces world-space:

- forward
- right
- up
- horizontal forward

The horizontal forward vector is used for yaw steering and horizontal precision positioning. Full 3D axes are retained for body-relative velocity calculations and future pitch/roll control.

This avoids treating a velocity-derived course as the craft's true nose direction. It also prevents stationary aircraft from being considered orientation-unknown when Sable telemetry is available.

## Axis calibration

The default assumes:

- the aircraft nose points toward local `-Z`
- the aircraft roof points toward local `+Y`

Some builds may use a differently oriented computer, sub-level, or control frame. Change `orientation.forward` and `orientation.up` in `/navtool/config.lua` rather than applying a yaw offset to quaternion telemetry.

Common forward-axis alternatives:

```lua
-- Nose is local +Z
forward = { x = 0, y = 0, z = 1 }

-- Nose is local +X
forward = { x = 1, y = 0, z = 0 }

-- Nose is local -X
forward = { x = -1, y = 0, z = 0 }
```

Keep `forward` and `up` perpendicular. Invalid or parallel axes are rejected and the controller falls back to another heading source.

## Numeric yaw fallback

`orientation.yawFormat` and `orientation.yawOffset` apply only to numeric-yaw sensors such as a Create: Avionics navigation table:

```lua
orientation = {
  yawFormat = "avionics",
  yawOffset = 0,
}
```

They do not modify Sable quaternion orientation. Quaternion calibration should be performed with the local `forward` and `up` vectors.

## Safe calibration procedure

1. Set `safety.maximumOutput = 1`.
2. Test over an empty area away from player builds.
3. Face the aircraft toward a known world direction.
4. Confirm the displayed heading changes correctly as the craft rotates.
5. Command a distant target directly in front of the craft.
6. Confirm forward thrust is used rather than reverse thrust.
7. Command targets to the left and right and confirm steering direction.
8. Test while pitched and rolled slightly.
9. Increase output limits only after every axis behaves correctly.

If forward and reverse are swapped, first verify the redstone output mappings. If the heading itself is reversed or sideways, adjust `orientation.forward`.

## Controller behavior

Outside the precision radius, the controller uses quaternion-derived horizontal heading for steering alignment and speed control.

Inside the precision radius, world coordinate error is projected onto the quaternion-derived horizontal forward/right basis. Independent position PIDs then command forward/reverse, left/right, and up/down corrections.

Arrival still requires all of the following:

- X error within `coordinateTolerance`
- Z error within `coordinateTolerance`
- Y error within `verticalTolerance`
- total velocity at or below `settleVelocity`

After arrival, the controller retains coordinate lock and resumes correction if the craft drifts outside the configured envelope.

## Fallback and failure behavior

If Sable pose is missing or its quaternion cannot be parsed, CC-NavTool does not invent an attitude. It tries the Create: Avionics navigation table and then the existing legacy path.

The integrated controller will delegate back to the legacy controller when it lacks both a position and a usable heading. This preserves compatibility with existing installations while allowing Sable-equipped craft to use the improved orientation path automatically.
