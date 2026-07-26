# NavRemote Controller Architecture

The `develop` branch separates aircraft execution from the operator interface.

## NavTool aircraft service

NavTool is a headless onboard service. It owns live aircraft responsibilities:

- loading the required CC: Sable `sublevel` API
- reading pose, quaternion orientation, position, and velocity
- running flight-control calculations
- applying bounded redstone outputs
- executing the active mode and target
- serving authenticated Rednet commands when networking is enabled
- inhibiting outputs when required Sable telemetry is missing

The canonical launch command is:

```text
navtool
```

`navtool server` remains a compatibility alias. First launch runs text-based setup for:

- whether remote networking is enabled
- Rednet channel
- aircraft host name
- shared key

This setup works on a standard Computer. NavTool does not require an Advanced Computer because it has no graphical interface.

When networking is disabled, NavTool still runs the local flight-control service. It simply does not host a Rednet endpoint. Run `navtool setup` later to change the networking configuration.

A wired modem network and a wireless modem network both use the same Rednet host, channel, and shared-key configuration.

## NavRemote controller

NavRemote is the operator interface and requires an Advanced Computer or color monitor. The default launcher opens a lightweight ComputerCraft-native desktop:

```text
navremote
```

The interface is branded only as **NavRemote**. It is not presented as an operating system or window manager.

Its visual structure follows the approved mockup:

- flat green workspace
- dark gray title bar
- gray left category rail
- three-column grid of large pixel-art application icons
- highlighted keyboard selection
- bottom keyboard-help bar
- no image assets, animation framework, or external UI dependency

Desktop applications:

- Dashboard
- Targets
- Routes
- Schedules
- Modes
- Manual
- Aircraft
- Logs
- Settings

## Local controller data

NavRemote owns persistent operator data for each linked aircraft:

```text
/navremote/data/profiles/<aircraft>.db
```

Each aircraft data file contains:

- current locally selected target
- saved targets
- routes and their ordered stops
- schedules, ordered stops, dwell settings, and loop preference
- active route or schedule progress
- interface preferences
- cached aircraft status
- local event log

Aircraft connection details remain in:

```text
/navremote/config.lua
```

These include the aircraft display name, Rednet channel, hosted name, shared key, and response timeout.

## Data ownership rule

The aircraft is authoritative for:

- live Sable telemetry
- current output state
- current mode
- the target currently being executed

NavRemote is authoritative for:

- the saved target library
- route definitions
- schedule definitions
- linked-aircraft profiles
- controller preferences
- cached status and local logs

NavRemote sends the active target, requested mode, or manual-control command to NavTool. Route and schedule progression is coordinated by NavRemote while it is running; NavTool remains focused on safely flying the current target.

## Same-computer installation

NavTool and NavRemote may be installed on the same Advanced Computer. NavTool can run in the background while NavRemote connects through the same modem network:

```lua
shell.run("bg", "navtool")
shell.run("navremote")
```

They may also run on separate computers. The architecture and saved-data behavior are identical in either arrangement.
