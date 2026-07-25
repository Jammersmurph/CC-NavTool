# CC-NavTool

**CC-NavTool** is a configurable navigation and flight-control system for **CC:Tweaked** computers mounted on **Sable / Create Aeronautics** craft.

The in-game program is called:

```text
navtool
```

The goal of the project is to provide a more flexible, programmable alternative to the built-in Navigation Table, with support for custom aircraft layouts, waypoints, autopilot modes, monitor interfaces, redstone control, and future fleet networking.

> **Current status:** Early development
> **Planned first release:** `v0.1.0-alpha`

---

## Project Goals

CC-NavTool is intended to become a complete avionics and navigation platform for Create Aeronautics craft.

Planned capabilities include:

* Reading craft position and orientation
* Reading linear and angular velocity
* Reading craft mass and center of mass
* Heading hold
* Altitude hold
* Speed hold
* Coordinate navigation
* Saved waypoints
* Multi-waypoint routes
* Return-to-home
* Hover mode
* Approach and braking control
* Emergency shutdown
* Touchscreen monitor interface
* Aircraft profiles
* Configurable redstone outputs
* Redstone Relay support
* Wireless control through Rednet
* Fleet and control-tower networking
* Automatic GitHub installation and updates
* Plugin support for future navigation modes

---

## Supported Mods

CC-NavTool is being designed around the following mod environment:

* CC:Tweaked
* Sable
* CC:Sable
* Create
* Create Aeronautics
* Create Propulsion: Simulated
* CC: Advanced Math
* Compatible redstone-controlled thrusters and control systems

Some features may also work with other Create Aeronautics integrations, provided the craft can be controlled through redstone or a CC:Tweaked peripheral.

---

## How It Works

CC-NavTool uses CC:Sable to read live craft telemetry.

Depending on the installed CC:Sable version, this may include:

* Logical position
* Logical orientation
* Linear velocity
* Angular velocity
* Center of mass
* Craft mass
* Inertia information
* Craft UUID

The craft orientation is represented using a quaternion. CC-NavTool uses quaternion math to determine the craft's actual forward, up, and side directions.

The program then calculates:

* Direction to the selected destination
* Distance to destination
* Heading error
* Altitude error
* Current speed
* Desired speed
* Braking distance
* Required steering output

The resulting control values are sent to configurable redstone outputs.

---

## Redstone Control

CC:Tweaked computers can independently control redstone on all six sides:

```text
top
bottom
left
right
front
back
```

CC-NavTool will support both:

* Digital redstone output
* Analog redstone output from `0` to `15`

Example actuator mappings may include:

```text
front      Main forward thrust
back       Reverse thrust
left       Turn left
right      Turn right
top        Ascend
bottom     Descend
```

These mappings will be fully configurable because aircraft layouts differ significantly.

Redstone Relay peripherals may also be supported for aircraft requiring more than six independent outputs.

---

## Safety Warning

Autopilot software cannot guarantee the safety of a Create Aeronautics craft.

Before enabling automatic control:

* Test over an empty area
* Use low redstone limits
* Verify every output direction
* Install a manual emergency cutoff
* Keep a pilot near the controls
* Back up important craft schematics
* Avoid testing near player builds
* Do not trust an uncalibrated aircraft profile

The first releases should be considered experimental.

---

## Installation

Once the installer is added to the repository, CC-NavTool will be installable directly from GitHub.

Run this command on a CC:Tweaked computer:

```lua
wget run https://raw.githubusercontent.com/Jammersmurph/CC-NavTool/main/install.lua
```

The installer will download the program and create the required directories.

After installation, start the program with:

```text
navtool
```

---

## Updating

To check for and install updates:

```text
navtool update
```

The updater will retrieve the latest files from:

```text
https://github.com/Jammersmurph/CC-NavTool
```

Existing configuration files and saved waypoints should be preserved during normal updates.

---

## Planned Commands

Launch the main interface:

```text
navtool
```

Display help:

```text
navtool help
```

Show the installed version:

```text
navtool version
```

Show craft and peripheral status:

```text
navtool status
```

Run the configuration interface:

```text
navtool configure
```

Run aircraft calibration:

```text
navtool calibrate
```

Enable debug telemetry:

```text
navtool debug
```

Check for updates:

```text
navtool update
```

Select an aircraft profile:

```text
navtool profile cargo
```

---

## Waypoint Commands

Add a waypoint at the current craft position:

```text
navtool waypoint add Home
```

Add a waypoint using coordinates:

```text
navtool waypoint add Port 120 85 -430
```

List saved waypoints:

```text
navtool waypoint list
```

Delete a waypoint:

```text
navtool waypoint delete Port
```

Navigate to a saved waypoint:

```text
navtool goto Home
```

Navigate directly to coordinates:

```text
navtool goto 120 85 -430
```

---

## Planned Flight Modes

### Manual

Displays telemetry without controlling the craft.

### Heading Hold

Maintains a selected compass heading.

### Altitude Hold

Maintains a selected world altitude.

### Speed Hold

Attempts to maintain a selected forward speed.

### Hover

Attempts to reduce horizontal and vertical movement.

### Navigate

Steers toward a coordinate or saved waypoint.

### Route

Follows several saved waypoints in order.

### Return Home

Navigates to a configured home waypoint.

### Emergency Stop

Immediately disables navigation outputs and attempts to stop powered movement.

---

## Aircraft Profiles

Different craft have different:

* Thruster directions
* Computer orientations
* Control strengths
* Mass
* Turning behavior
* Braking performance
* Redstone wiring

Aircraft profiles will allow each craft to store its own configuration.

Example profiles:

```text
default
cargo
airship
fighter
transport
helicopter
```

A profile may define:

* Local forward direction
* Local up direction
* Redstone side mappings
* Output inversion
* Maximum thrust output
* Maximum steering output
* Cruise speed
* Approach speed
* Arrival radius
* Controller tuning values
* Monitor preferences

---

## Planned Directory Layout

Repository layout:

```text
CC-NavTool/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── install.lua
├── update.lua
├── version.txt
│
├── navtool/
│   ├── main.lua
│   ├── config.lua
│   ├── telemetry.lua
│   ├── physics.lua
│   ├── navigation.lua
│   ├── autopilot.lua
│   ├── outputs.lua
│   ├── gui.lua
│   ├── waypoint.lua
│   ├── profiles.lua
│   ├── networking.lua
│   ├── logger.lua
│   ├── constants.lua
│   └── util.lua
│
├── profiles/
│   └── default.lua
│
├── docs/
│   ├── INSTALLATION.md
│   ├── CONFIGURATION.md
│   ├── CALIBRATION.md
│   ├── WIRING.md
│   ├── API.md
│   └── TROUBLESHOOTING.md
│
└── examples/
```

Installed layout on a CC:Tweaked computer:

```text
/navtool
├── navtool.lua
├── config.lua
├── version.txt
├── update.lua
├── waypoints.db
│
├── modules/
├── profiles/
├── plugins/
└── logs/
```

A launcher named `navtool` will be placed somewhere accessible from the computer's shell path.

---

## Configuration

CC-NavTool will generate a default configuration during installation or first launch.

Planned settings include:

```lua
return {
    updateInterval = 0.1,

    navigation = {
        cruiseSpeed = 12,
        approachSpeed = 4,
        slowdownRadius = 50,
        arrivalRadius = 5,
        stopSpeed = 0.5
    },

    orientation = {
        forward = { x = 0, y = 0, z = -1 },
        up = { x = 0, y = 1, z = 0 }
    },

    outputs = {
        forward = {
            side = "front",
            analog = true,
            inverted = false,
            maximum = 15
        },

        reverse = {
            side = "back",
            analog = true,
            inverted = false,
            maximum = 15
        },

        left = {
            side = "left",
            analog = true,
            inverted = false,
            maximum = 15
        },

        right = {
            side = "right",
            analog = true,
            inverted = false,
            maximum = 15
        },

        up = {
            side = "top",
            analog = true,
            inverted = false,
            maximum = 15
        },

        down = {
            side = "bottom",
            analog = true,
            inverted = false,
            maximum = 15
        }
    }
}
```

The final configuration format may change during early development.

---

## Calibration

Because every aircraft behaves differently, CC-NavTool will include a calibration process.

The calibration wizard is planned to determine:

* Which direction is forward
* Which direction is up
* Which output turns left
* Which output turns right
* Which output ascends
* Which output descends
* Which output applies forward thrust
* Which output applies reverse thrust
* Whether any output is inverted
* Approximate turning strength
* Approximate acceleration
* Approximate braking strength

Planned command:

```text
navtool calibrate
```

Calibration should be performed again after major aircraft changes.

---

## Monitor Interface

An Advanced Monitor will be optional.

When detected, the graphical interface may display:

* Current coordinates
* Current altitude
* Current speed
* Vertical speed
* Heading
* Target heading
* Selected waypoint
* Distance to waypoint
* Estimated arrival status
* Heading error
* Altitude error
* Throttle output
* Steering output
* Current flight mode
* Warning messages

Planned touchscreen controls include:

* Engage
* Disengage
* Emergency stop
* Select waypoint
* Add waypoint
* Change flight mode
* Return home
* Open configuration
* Change aircraft profile

The terminal interface will remain available for computers without a monitor.

---

## Networking

Future versions may support Rednet communication between:

* Aircraft
* Ground control computers
* Docking stations
* Air traffic control systems
* Fleet management computers
* Wireless pilot terminals

Possible networking features:

* Remote telemetry
* Remote destination assignment
* Fleet position tracking
* Emergency recall
* Docking clearance
* Route distribution
* Craft identification through UUIDs
* Shared waypoint databases

Networking will not be required for normal local navigation.

---

## Development Roadmap

### Milestone 0.1 — Foundation

* Repository structure
* Installer
* Updater
* Configuration system
* Logging
* Command-line interface
* Version information
* Basic documentation

### Milestone 0.2 — Telemetry

* Detect CC:Sable
* Read logical position
* Read craft orientation
* Read linear velocity
* Read angular velocity
* Read mass
* Display live telemetry
* Monitor dashboard

### Milestone 0.3 — Flight Assistance

* Heading hold
* Altitude hold
* Speed hold
* Output limiting
* Emergency disengage
* Manual calibration

### Milestone 0.4 — Navigation

* Coordinate entry
* Saved waypoints
* Arrival detection
* Speed reduction near destination
* Reverse-thrust braking
* Return-to-home
* Route following

### Milestone 0.5 — Interface

* Advanced Monitor GUI
* Touch controls
* Configuration wizard
* Profile editor
* Waypoint manager
* Warning and status screens

### Milestone 0.6 — Networking

* Rednet telemetry
* Remote waypoint assignment
* Control-tower support
* Fleet status interface

### Milestone 1.0 — Stable Release

* Complete documentation
* Tested installer and updater
* Stable configuration format
* Multiple aircraft profiles
* Reliable navigation modes
* Public release package
* GitHub Releases support

---

## Contributing

Contributions, testing, bug reports, and aircraft profiles will be welcome as the project develops.

Useful contributions may include:

* Testing with different aircraft
* CC:Sable API compatibility testing
* Better control algorithms
* Monitor interface improvements
* Documentation
* Wiring examples
* Example aircraft profiles
* Bug reports
* Feature requests

Please include the following information when reporting a bug:

* Minecraft version
* CC:Tweaked version
* Sable version
* CC:Sable version
* Create Aeronautics version
* Computer type
* Relevant configuration
* Error message
* Log output
* Steps to reproduce

---

## Known Limitations

During early development:

* Control tuning may require manual adjustment
* Aircraft with unusual orientations may need custom profiles
* Automatic braking may vary by craft
* Hover behavior may be unreliable
* Monitor layouts may not support every monitor size
* Different CC:Sable versions may expose slightly different APIs
* Navigation should not be considered safe for unattended use

---

## License

CC-NavTool is planned to be released under the **MIT License**.

This allows users to:

* Use the software
* Modify the software
* Distribute the software
* Include it in modpacks
* Create custom aircraft profiles
* Build integrations around it

The copyright and license notice must remain included in redistributed copies.

---

## Repository

GitHub:

```text
https://github.com/Jammersmurph/CC-NavTool
```

Repository name:

```text
Jammersmurph/CC-NavTool
```

Program name:

```text
navtool
```

Project display name:

```text
CC-NavTool
```

---

## Credits

Created by **Jammersmurph**.

Built for the CC:Tweaked, Sable, and Create Aeronautics community.

CC-NavTool is an independent community project and is not officially affiliated with the developers of CC:Tweaked, Sable, Create, or Create Aeronautics.

