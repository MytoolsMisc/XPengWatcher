# XPengWatcher

![XPengWatcher icon](XPengWatcher/Assets.xcassets/AppIcon.appiconset/appicon-256.png)

XPengWatcher is an independent macOS menu-bar application that periodically reads vehicle information from the XPENG iPhone app, stores the readings locally, and produces trip and charging reports.

It is designed for owners who want to keep their own telemetry history without leaving the resource-intensive XPENG app running continuously.

> [!WARNING]
> XPengWatcher controls the XPENG user interface through macOS Accessibility APIs. It may activate windows, click controls, scroll, and temporarily move the mouse pointer.
>
> **Do not run it on a Mac while somebody is actively working on that Mac.** The recommended setup is a dedicated Apple Silicon Mac used as a small home server.

## Requirements

- An Apple Silicon Mac with an M-series processor (M1, M2, M3, M4, or later).
- macOS 26.5 or later.
- The official **XPENG iPhone app**, downloaded from the App Store on the Mac.
- An XPENG account already configured and signed in and a new account for the Mac running instance.
- Permission for XPengWatcher in **System Settings → Privacy & Security → Accessibility**.

An Intel Mac is not supported because XPengWatcher relies on the iPhone version of the XPENG app running on Apple Silicon.

## What it does

At the configured interval, XPengWatcher:

1. Launches the XPENG iPhone app without activating it when possible.
2. Waits for its window and gives the app time to refresh the vehicle data.
3. Reads the available information through the Accessibility interface.
4. Optionally opens the XPENG settings screen to read the odometer.
5. Stores changed telemetry in SQLite.
6. Updates trip and charging-session statistics.
7. Optionally publishes telemetry to an MQTT broker.
8. Closes the XPENG app to prevent it from consuming CPU between readings.

The menu-bar item displays the latest battery state, available range, odometer, trip, charge, and collection status.

## Installation

### 1. Install the XPENG iPhone app

On the Apple Silicon Mac that will run XPengWatcher:

1. Open the App Store.
2. Find the official XPENG iPhone app.
3. Install it and sign in to a new XPENG account.
4. Open it once and confirm that the vehicle information is visible.
5. Configure the Country/Region to Norge
6. Configure the Language to English
7. Grant access to this new account from your main XPeng account ( as if you are sharing the car ) Acccept the invite on the MacOS XPENG app.

### 2. Install XPengWatcher

1. Download `XPengWatcher.app` from the latest GitHub release.
2. Move it to `/Applications`.
3. Launch it. Its icon appears in the macOS menu bar; it does not appear in the Dock.
4. Grant the requested Accessibility permission.
5. If MQTT or the HTTP report is enabled, also grant Local Network access.
6. Open **Settings** from the menu-bar item and review the collection interval, battery capacity, SOH, MQTT, and HTTP options.

The distributed Release build is signed with a Developer ID. Published releases should also be notarized before distribution.

### Building from source

Open [`XPengWatcher.xcodeproj`](XPengWatcher.xcodeproj) in Xcode, select the `XPengWatcher` scheme, and build the macOS target.

Release builds use Developer ID signing. You will need to replace the development team and signing identity with your own if you are building a distributable copy.

## Data storage and backups

The database is stored at:

```text
~/Documents/XPengWatcher/xpeng.db
```

Keeping it in Documents makes it easy to include in Time Machine, iCloud Drive, or another backup system.

The database contains:

- timestamped vehicle telemetry;
- battery state of charge and available range;
- odometer readings;
- charging power and AC/DC charging sessions;
- reconstructed journeys and estimated consumption.

## Background collection and the odometer

Reading the odometer requires XPengWatcher to bring the XPENG app to the foreground, open its settings, and sometimes scroll its interface.

For quieter background collection, create this empty marker file:

```text
~/Documents/XPengWatcher/noodometer
```

When this file exists, XPengWatcher skips the foreground settings navigation and reuses the last known odometer value. Other information is still collected when the XPENG app exposes it in the background.

Remove the file to restore full odometer collection.

## Reports

XPengWatcher provides a native report window containing:

- the latest reading time, odometer, SOC, and available range;
- recent trips, duration, distance, SOC change, and estimated consumption;
- recent charging sessions, added energy, type, maximum power, and state;
- AC/DC charging ratios by session and energy.

Reports are available in English, French, Portuguese, Spanish, German, Dutch, Italian, and Danish.

## HTTP report

An optional HTTP server can expose the report to other devices on the local network. Enable it and choose a port in XPengWatcher settings. The default URL is:

```text
http://<mac-hostname-or-ip>:8080/
```

The server selects the report language from the browser preferences. A language can also be selected explicitly, for example:

```text
http://<mac-hostname-or-ip>:8080/?lang=fr
http://<mac-hostname-or-ip>:8080/?lang=de
```

The plain-text version is available at `/report.txt`.

> [!CAUTION]
> The built-in HTTP server currently provides neither TLS nor authentication. Enable it only on a trusted local network and do not expose its port directly to the Internet.

## MQTT

MQTT publishing is optional. Configure the broker host, port, username, password, and base topic in Settings. The password is stored in the macOS Keychain.

Telemetry fields are published below the configured base topic, for example:

```text
xpeng/g6/telemetry/soc
xpeng/g6/telemetry/range
xpeng/g6/telemetry/online
```

## Operational recommendations

- Use a dedicated Mac acting as a home server.
- Keep the Mac logged in; Accessibility automation requires a graphical user session.
- Disable sleep or configure wake behaviour appropriate for the collection schedule.
- Back up `~/Documents/XPengWatcher/` regularly.
- Expect the XPENG interface to change after app updates; Accessibility-based parsing may then require an XPengWatcher update.

## Privacy

Vehicle data remains in the local SQLite database unless MQTT or the HTTP report is explicitly enabled. XPengWatcher does not provide a cloud service.

## Disclaimer

XPengWatcher is an unofficial, independent project. It is not affiliated with, endorsed by, or supported by XPENG. XPENG names and trademarks belong to their respective owner.
