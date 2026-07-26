# NavRemote Controller Architecture

The `develop` branch separates aircraft execution from the user interface.

## NavTool aircraft agent

NavTool is a headless onboard service. It owns only live aircraft responsibilities:

- loading the CC: Sable `sublevel` API
- reading pose, quaternion orientation, and velocity
- running flight-control calculations
- applying bounded redstone outputs
- optionally serving authenticated Rednet commands
- inhibiting outputs when required telemetry is missing

The canonical launch command is:

```text
navtool
```

`navtool server` remains accepted as a compatibility alias. NavTool no longer presents an interactive dashboard.

### First-run setup

The first time `navtool` starts, the aircraft still runs its networking setup. The operator chooses whether remote networking is enabled and configures:

- Rednet channel
- aircraft host name
- shared key

The same setup can be rerun later with:

```text
navtool setup
```

Remote networking is optional. When it is disabled, `navtool` still runs the local Sable flight service and automation loop, but it does not host a Rednet endpoint. When networking is enabled, wired, wireless, and Ender modem arrangements supported by CC:Tweaked remain usable.

## NavRemote controller

NavRemote is the operator interface. The default `navremote` launcher opens the lightweight OPUS-inspired desktop. The older interface remains temporarily available with:

```text
navremote legacy
```

NavRemote owns persistent controller data per linked aircraft profile:

```text
/navremote/data/profiles/<profile>.db
```

Each profile data file contains:

- current locally selected target
- saved targets
- routes
- schedules
- active route and schedule state
- UI preferences
- last received aircraft status
- local event log

Aircraft connection details remain in `/navremote/config.lua`.

## Data ownership rule

The aircraft is the authority for live telemetry and the currently executing control mode. NavRemote is the authority for saved navigation data and operator state.

NavRemote sends only the active target, requested mode, or manual-control command to the aircraft. Saved target libraries, route definitions, and schedule definitions are not intended to depend on aircraft-local storage.

## Current desktop pages

Implemented in the first controller pass:

- Dashboard
- Targets
- Flight modes
- Manual control
- Linked aircraft profiles
- Local event log

Reserved and locally backed, but still awaiting complete editors:

- Routes
- Schedules
- Settings

## Visual direction

The interface is inspired by the lightweight OPUS application launcher style rather than attempting to recreate an operating system. It uses only CC:Tweaked-native drawing operations:

- green workspace
- gray category rail
- compact pixel-style icons
- keyboard navigation
- no image assets
- no animation framework
- no external UI dependency

The program is branded simply as **NavRemote**.
