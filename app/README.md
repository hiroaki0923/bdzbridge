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
  -recorderHost 192.0.2.63 -refreshOnStart 1 -startTab reservations
```

`-recorderHost` fills in the address, `-refreshOnStart 1` fetches the guide at launch, `-startTab` opens
`guide`, `reservations`, `recordings` or `settings`, `-guideMode` picks `list` or `grid`, `-recordingsMode`
picks `list`, `groups` or `dups`, `-startDay 6` opens the guide six days out, and `-scanOnStart 1` starts the
duplicate scan, which only reads.

**A launch argument pins the value for that run.** Anything passed this way lands in `UserDefaults`'
argument domain, which outranks what the app saves, so picking another mode in a run started with
`-recordingsMode` appears to do nothing: the pick is written but the argument keeps being read back. Launch
without the flag to use the app normally. The same goes for the address typed into Settings while
`-recorderHost` is in force.

## What works

Typing in a recorder's address and connecting to it, fetching all four broadcasting types' guides and logos
into the on-device cache, browsing a day's programmes as a list or as a time-by-channel grid with the station
logos and genres, opening a programme, and listing the reservations the recorder holds. Verified against a
BDZ-FBT4100 from the simulator.

The grid mirrors the web app's: an hour ruler down the left and the channel names across the top, genre
colours, the elapsed part of what is on air shaded up to a red line at the current time, and a time axis
that pinches. Today
opens at the current time.

A programme can be reserved: the sheet offers the recording mode and the repeat, asks the recorder what the
new reservation would clash with, and creates it behind a confirmation. Reserved programmes are tinted and
labelled in both views. A reservation can be undone from any of the three places it shows up: swiped in the
list, from the reservation sheet the list opens, or from the guide's own sheet.

Creating and deleting have both been done against a real BDZ-FBT4100 from the app and the recorder followed
along, 42 reservations before and 42 after.

The recordings screen lists what the recorder holds, as a flat list or gathered into programmes, with the free
space, the genre counts, a sort and a watch-state filter. A recording opens a sheet that plays it on the
television, protects it against the recorder's own tidying, and deletes it behind a confirmation.

The duplicate copies of one broadcast can be found: recordings with the same title and nearly the same
length are candidates, and asking the recorder what each one is about confirms them. The copy to keep is
marked with the reason, and the rest come pre-selected for deletion.

A programme's recordings can be worked on together: select some of them, or the whole programme, and delete
or protect them. The recorder takes one request at a time, so the run shows its progress and can be stopped,
and it lives outside the sheet that started it: closing the sheet neither stops it nor hides the stop button.

## What is missing

Finding the recorder by scanning instead of typing its address, and the queue that holds reservations made
while away from home.
