# CC-NavTool v0.4 Pre-Test Checklist

Use this order so a failure in one layer does not get confused with a flight-control problem in another.

## 1. Install and startup

### Aircraft

- Install from the `develop` aircraft installer.
- Confirm `navtool` starts the headless service.
- Confirm a normal, non-Advanced Computer can run it.
- Confirm `navtool setup` reopens configuration.
- Confirm disabling Rednet skips location-tracking setup.
- Confirm enabling Rednet offers Follow/Auto Home location tracking.

### NavRemote

- Install from the `develop` remote installer.
- Confirm `navremote` opens the green desktop.
- Confirm `navremote legacy` still opens the compatibility interface.
- Confirm no `OS` branding appears.

## 2. Networking

- Use matching channel, aircraft hostname, and shared key.
- Confirm Dashboard changes from OFFLINE to SABLE ONLINE.
- Confirm Dashboard displays link quality and response time.
- Confirm connection-loss and reconnection events appear in Logs.
- In Aircraft, press `F` and test discovery on the configured channel.

## 3. Sable telemetry and safety

- Confirm position and velocity update while the craft moves.
- Confirm the source is CC:Sable/sublevel rather than GPS fallback.
- Remove or interrupt Sable telemetry and confirm redstone outputs are inhibited.
- Restore telemetry and confirm normal status returns.

## 4. Flight controls

Test with low output limits and clear space.

- Manual forward/reverse.
- Manual left/right.
- Manual up/down.
- Emergency output clear with `X`.
- Standby.
- Hover.
- Navigate to a nearby target.
- Return Home, if configured by the aircraft runtime.

## 5. Local NavRemote data

- Create a target and restart NavRemote.
- Confirm the target remains.
- Create a route and restart NavRemote.
- Confirm the route remains.
- Create a schedule and restart NavRemote.
- Confirm the schedule remains.
- Switch between two aircraft profiles and confirm their libraries remain separate.

## 6. Follow and Auto Home

Requirements:

- Rednet enabled on NavTool.
- Location tracking enabled on NavTool.
- Wireless or Ender modem available to both sides.
- Working GPS coverage at the NavRemote.
- Matching host, channel, shared key, and location port.

Tests:

- Open Modes and press `F`.
- Select a broadcasting NavRemote.
- Move the NavRemote and confirm the aircraft target updates.
- Temporarily leave GPS or modem range.
- Confirm the aircraft keeps Follow armed rather than choosing another remote.
- Return to range and confirm target updates resume.
- Press `S` and confirm Follow stops.
- Press `H`, select a NavRemote, and confirm Auto Home copies one position without continuously following it.

## 7. Routes and schedules

- Start a two-stop route.
- Confirm it advances only after reaching the configured radius.
- Confirm completion returns the aircraft to standby and clears outputs.
- Start a looping schedule and confirm it returns to its first stop.
- Stop automation manually and confirm no active route or schedule remains.

## 8. Record failures

For each failure, capture:

- aircraft computer type and ID
- NavRemote computer type and ID
- modem type on both computers
- exact command used
- screen error
- `/navtool/config.lua`
- `/navremote/config.lua` with shared keys removed
- relevant NavRemote Logs entries
- Minecraft, NeoForge, CC:Tweaked, CC:Sable, Create, and Create Aeronautics versions from the CreateVC Packwiz repository
