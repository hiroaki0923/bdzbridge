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

## On a real iPhone

A free Apple ID is enough. Nothing here needs a capability a personal team cannot have: the background
refresh is an Info.plist key, not an entitlement, and the local network is a user grant rather than
something Apple hands out. The build expires after seven days and has to be installed again, which is
the only cost of not paying.

1. Put the team identifier in `app/Signing.local.xcconfig`, which is gitignored:
   `echo 'DEVELOPMENT_TEAM = ABCDE12345' > Signing.local.xcconfig`. Xcode > Settings > Accounts shows
   it once an Apple ID is added there.
2. On the phone, Settings > Privacy & Security > Developer Mode, then let it restart.
3. `xcodegen generate`, open the project, pick the phone, and run it once from Xcode. That first run is
   what registers the device and asks for the certificate; after it, the command line below works.
4. The phone has to be on the same Wi-Fi as the recorder. iOS asks for the local network the first time
   the app looks for it, and refusing leaves the app with nothing to talk to (Settings > the app > Local
   Network puts it back).

Once installed, a device takes the same launch arguments a simulator does:

```
xcrun devicectl list devices
xcrun devicectl device install app --device <udid> <path to RecorderApp.app>
xcrun devicectl device process launch --device <udid> io.github.hiroaki0923.recorderapp \
  -recorderHost 192.0.2.63 -startTab guide
```

The overnight refresh can be made to happen instead of waited for: pause the app in Xcode and, in the
console,

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"io.github.hiroaki0923.recorderapp.guideRefresh"]
```

which runs the real task the real way, whereas `-runBackgroundWork 1` only runs its body.

## Driving it without tapping through it

Two launch arguments exist for testing on a simulator or a device. They do nothing unless passed, and nobody
installing from the App Store can pass them.

```
xcrun simctl launch <device> io.github.hiroaki0923.recorderapp \
  -recorderHost 192.0.2.63 -refreshOnStart 1 -startTab reservations
```

`-wakeOnStart 1` sends the magic packet at launch, which is the only way to see whether a broadcast gets
out of the sandbox at all. `-recorderHost` fills in the address, `-refreshOnStart 1` fetches the guide at
launch, `-startTab` opens
`guide`, `reservations`, `recordings` or `settings`, `-guideMode` picks `list` or `grid`, `-recordingsMode`
picks `list`, `groups` or `dups`, `-startDay 6` opens the guide six days out, `-scanOnStart 1` starts the
duplicate scan, which only reads, and `-searchFor <word>` fills in the search box, `-searchScope guide|reservations|recordings` picks which list it searches, and `-runBackgroundWork 1` does what the overnight guide
refresh does, which is the only way to watch that path without waiting for iOS to schedule it.

**A launch argument pins the value for that run.** Anything passed this way lands in `UserDefaults`'
argument domain, which outranks what the app saves, so picking another mode in a run started with
`-recordingsMode` appears to do nothing: the pick is written but the argument keeps being read back. Launch
without the flag to use the app normally. The same goes for the address typed into Settings while
`-recorderHost` is in force.

## What works

Finding the recorder: a button looks through the subnet the device is on and offers whatever answers as a
recorder, so the address does not have to be typed. On a home network 253 addresses take about seven seconds.

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

The guide is fetched again overnight on its own, a little after the recorder rebuilds its own guide files, so
the morning's eight days are current without opening the app or being at home. iOS decides whether to run it:
never while the app is force-quit, Background App Refresh is off, or the battery is in Low Power Mode, and
nothing breaks when a night is missed. The settings screen shows when it last succeeded.

Searching: programmes still to come whose title or description contains the words, across every broadcasting
type and all eight days, read from the cache so it works away from home. A result opens the same sheet the
guide does, and one that is already reserved says so.

Reservations are shown under the day they record on, and can be narrowed to the ones an app put in or the
ones the recorder's own automatic recording did. Sony's app splits those into two lists as well; the recorder
marks its own with `reservationCreatorID` 1100 and will put one back after it is deleted, which the app says
before it deletes.

The recordings screen lists what the recorder holds, as a flat list or gathered into programmes, with the free
space, the genre counts, a sort and a watch-state filter. A recording opens a sheet that plays it on the
television, protects it against the recorder's own tidying, and deletes it behind a confirmation.

The duplicate copies of one broadcast can be found: recordings with the same title and nearly the same
length are candidates, and asking the recorder what each one is about confirms them. The copy to keep is
marked with the reason, and the rest come pre-selected for deletion.

A programme's recordings can be worked on together: select some of them, or the whole programme, and delete
or protect them. The recorder takes one request at a time, so the run shows its progress and can be stopped,
and it lives outside the sheet that started it: closing the sheet neither stops it nor hides the stop button.

Waking the recorder: a BDZ-FBT4100 leaves the LAN on its own after a while and then answers nothing at
all, which is below the network standby that `X_PowerControl` can reach. A magic packet is the only way
back, and the recorder both says it takes one (`X_WakeupOnLAN` in its description) and hands over the
address to send it to (`X_GetPrivateIp`), so nothing has to be typed in — which matters, because iOS
cannot read an ARP table. The address is kept whenever the recorder answers, and a screen with no recorder
offers to wake it.

## What is missing

The queue that holds reservations made while away from home. Finding the recorder over SSDP, which would be
quicker than looking through the subnet but needs an entitlement from Apple.
