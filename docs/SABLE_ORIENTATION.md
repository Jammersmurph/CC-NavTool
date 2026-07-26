# CC: Sable Flight Telemetry

CC-NavTool requires CC: Sable on the aircraft computer. The active flight controller reads its navigation state from Sable's `sublevel` API and does not use GPS, Create: Avionics, or generic telemetry peripherals as flight-control fallbacks.

## Required telemetry source

The runtime loads:

```lua
local sublevel = require("rom/apis/sublevel")
```

The flight controller requires a valid Sable pose containing:

- world position
- quaternion orientation
- linear velocity when available
- angular velocity when available

If the API cannot be loaded, CC-NavTool refuses to start the integrated flight controller. If the computer is not on a valid Sable sub-level or a pose cannot be read, all automatic outputs are inhibited.

This is intentional. A missing Sable state is treated as a fault, not as permission to guess position or orientation from another source.

## Create: Avionics

Create: Avionics is optional.

When installed, its peripherals may still enrich status pages and diagnostics with information such as:

- navigation-table values
- gimbal readings
- altitude-sensor readings
- physics-assembler metadata
- velocity-sensor diagnostics

Those readings do not satisfy the flight-control telemetry requirement and are not used as an automatic-navigation fallback.

## No GPS fallback

GPS is not part of the integrated autopilot telemetry path.

CC-NavTool does not:

- call GPS to replace a missing Sable position
- infer heading from GPS movement
- apply a forward bootstrap to discover heading
- continue navigation from a stale GPS fix

Rednet still requires a modem when remote control is enabled, but that modem is unrelated to GPS positioning.

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

CC-NavTool normalizes the quaternion before using it. It also accepts common `w/x/y/z` and indexed representations defensively.

## How orientation is used

The configured aircraft-local axes are rotated through the quaternion:

```lua
orientation = {
  forward = { x = 0, y = 0, z = -1 },
  up = { x = 0, y = 1, z = 0 },
}
```

From these vectors, CC-NavTool derives world-space:

- forward
- right
- up
- horizontal forward

The horizontal forward vector is used for yaw steering and horizontal precision positioning. Full 3D axes are retained for body-relative velocity calculations and future pitch/roll control.

## Axis calibration

The default assumes:

- the aircraft nose points toward local `-Z`
- the aircraft roof points toward local `+Y`

Some builds may use a differently oriented computer, sub-level, or control frame. Change `orientation.forward` and `orientation.up` in `/navtool/config.lua`.

Common forward-axis alternatives:

```lua
-- Nose is local +Z
forward = { x = 0, y = 0, z = 1 }

-- Nose is local +X
forward = { x = 1, y = 0, z = 0 }

-- Nose is local -X
forward = { x = -1, y = 0, z = 0 }
```

Keep `forward` and `up` perpendicular. Invalid or parallel axes cause the Sable attitude state to be rejected and automatic outputs to remain inhibited.

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

Arrival requires all of the following:

- X error within `coordinateTolerance`
- Z error within `coordinateTolerance`
- Y error within `verticalTolerance`
- total velocity at or below `settleVelocity`

After arrival, the controller retains coordinate lock and resumes correction if the craft drifts outside the configured envelope.

## Failure behavior

The controller follows a fail-closed policy:

- no Sable API: runtime stops before launching flight control
- no valid Sable sub-level pose: automatic outputs are set to zero
- invalid quaternion or incomplete Sable state: automatic outputs are set to zero
- Create: Avionics available but Sable unavailable: automatic outputs remain zero
- GPS available but Sable unavailable: automatic outputs remain zero

Manual and diagnostic functionality may still expose available information, but automatic navigation never substitutes another telemetry source for Sable.
