# The iOS app

- `RecorderKit/` — the recorder-facing Swift package: protocols, decoders, the HTTP client and the guide
  cache. No UI, and testable from the command line. See its own README.
- `RecorderApp/` — the app itself: SwiftUI, three screens, no server in the middle.
- `project.yml` — the Xcode project is generated from this by XcodeGen and is **not** committed.

## Build and run

```
brew install xcodegen
cd app && xcodegen generate
open RecorderApp.xcodeproj
```

The product name and bundle identifier in `project.yml` are working values; the store name has not been
decided yet.

## Driving it without tapping through it

Two launch arguments exist for testing on a simulator or a device. They do nothing unless passed, and nobody
installing from the App Store can pass them.

```
xcrun simctl launch <device> io.github.hiroaki0923.recorderapp \
  -recorderHost 192.168.0.63 -refreshOnStart 1 -startTab reservations
```

`-recorderHost` fills in the address, `-refreshOnStart 1` fetches the guide at launch, and `-startTab` opens
`guide`, `reservations` or `settings`.

## What works

Typing in a recorder's address and connecting to it, fetching all four broadcasting types' guides and logos
into the on-device cache, browsing a day's programmes with the station logos and genres, opening a programme,
and listing the reservations the recorder holds. Verified against a BDZ-FBT4100 from the simulator.

## What is missing

Finding the recorder by scanning instead of typing its address, creating a reservation from a programme, the
recordings screen, the time-by-channel grid, and the queue that holds reservations made while away from home.
