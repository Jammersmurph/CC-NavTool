# CC-NavTool

CC-NavTool is a CC:Tweaked navigation and flight-control system for CC:Sable / Create Aeronautics craft.

It has two installable parts:

- `NavTool Server`: runs on the aircraft computer as `navtool`
- `NavRemote`: runs on an Advanced Computer/pocket control computer as `navremote`

## Install

Recommended Pastebin installer:

```text
pastebin run tZLw4tnD
```

GitHub installer:

```text
wget run https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/develop/pastebin-installer.lua
```

The installer opens a TUI with arrow-key selection:

```text
NavTool by Jammersmurph Installer:

Stable:
- NavTool Server
- NavRemote

Nightly:
- NavTool Server
- NavRemote
```

After install, it can optionally add the selected program to the top of `/startup.lua` as a background task without overwriting existing startup contents.

## Run

Aircraft computer:

```text
navtool
```

Remote/control computer:

```text
navremote
```

Update:

```text
navtool update
navremote update
```

Uninstall:

```text
navtool uninstall
navremote uninstall
```

## What Goes Where

Aircraft/server data lives under `/navtool/`.

- `/navtool/config.lua`: hardware outputs, monitor selection, networking, safety, orientation, tuning
- `/navtool/target.db`: current active target
- `/navtool/mode.db`: current mode
- `/navtool/logs/`: flight logs

NavRemote profile data lives under `/navremote/data/profiles/`.

- targets/waypoints
- routes
- schedules
- active route/schedule state
- profile preferences and logs

Hardware configuration is stored only on the NavTool aircraft/server, not on NavRemote.

## Hardware Controls

Default flight outputs are:

```text
forward
reverse
left
right
up
down
```

`left` and `right` mean turning/yaw. They are not sideways strafe controls.

Outputs can be assigned to local redstone sides or Redstone Relay peripherals from NavRemote's Hardware page.

## Monitor Setup

NavRemote can configure aircraft-side monitors visible to the NavTool server over the wired modem LAN.

In NavRemote:

```text
Hardware -> M:monitor
```

The selected monitor is stored on the aircraft in `/navtool/config.lua` as `monitorPeripheral`.

## Navigation Model

Normal waypoint/schedule navigation:

1. Climb to cruise altitude, default `Y=300`.
2. Turn the computer screen/front toward the target.
3. Move forward only while aligned.
4. Reach the waypoint X/Z.
5. Descend or ascend to the waypoint Y.
6. For schedules, wait the configured dwell time, then continue to the next stop.

Follow mode:

1. Climb to cruise altitude when outside follow range.
2. Turn toward the NavRemote beacon.
3. Move forward while aligned.
4. Within the configured X/Z radius, default `10` blocks, track the NavRemote altitude plus offset.
5. If the NavRemote leaves range, return to cruise behavior.

## Orientation

Mount the aircraft computer with its screen facing the intended front of the ship.

Default orientation:

```lua
orientation = {
  forward = { x = 0, y = 0, z = 1 },
  up = { x = 0, y = 1, z = 0 },
}
```

This is a local computer-space vector. CC:Sable rotates it into world space, so aircraft forward is not fixed to world Z.

## Safety

This is experimental autopilot software.

- Test over empty terrain.
- Keep output limits low at first.
- Verify every output direction manually.
- Keep a manual cutoff available.
- Back up important craft schematics.
