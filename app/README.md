# The iOS app

- `RecorderKit/` — the recorder-facing Swift package: protocols, decoders, the HTTP client and the guide
  cache. No UI, and testable from the command line. See its own README.
- `RecorderApp/` — the app itself: SwiftUI, five tabs, no server in the middle.
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

**Only ever done here with a paid membership.** Everything below was carried out with an Apple Developer
Program team, so read the free-account paragraph as an expectation rather than a report.

Apple documents on-device testing with a free Apple Account, at
<https://developer.apple.com/support/compare-memberships/>: ten App IDs, three devices, three apps per
device, and provisioning profiles that expire seven days from issue, so the app has to be built and
installed again each week. The same page says advanced app capabilities need a membership, without saying
which capabilities those are. Nothing here asks for an entitlement — the overnight refresh is the
`UIBackgroundModes` and `BGTaskSchedulerPermittedIdentifiers` keys in Info.plist rather than a capability,
and the local network is a prompt the reader answers — so a personal team ought to be able to sign it. That
has not been tried.

1. Put the team identifier in `app/Signing.local.xcconfig`, which is gitignored:
   `echo 'DEVELOPMENT_TEAM = ABCDE12345' > Signing.local.xcconfig`. Xcode > Settings > Accounts shows
   it once an Apple ID is added there.
2. On the phone, Settings > Privacy & Security > Developer Mode, then let it restart.
3. `xcodegen generate`, open the project, pick the phone, and run it once from Xcode. That first run is
   what registers the device and asks for the certificate; after it, the command line below works.
4. The phone has to be on the same Wi-Fi as the recorder. iOS asks for the local network the first time
   the app looks for it, and refusing leaves the app with nothing to talk to (Settings > the app > Local
   Network puts it back).

Once installed:

```
xcrun devicectl list devices
xcrun devicectl device install app --device <udid> <path to RecorderApp.app>
xcrun devicectl device process launch --device <udid> jp.hiroaki.bdbridge
```

A device takes the same launch arguments a simulator does, but they have to come after `--` or devicectl
reads them as its own options.


## Driving it without tapping through it

Four launch arguments exist so that the app can be checked without tapping through it. They do nothing
unless passed, and nobody installing from the App Store can pass them.

```
xcrun simctl launch <device> jp.hiroaki.bdbridge \
  -recorderHost <recorder ip> -startTab search -searchFor ニュース -searchScope recordings

xcrun devicectl device process launch --device <udid> jp.hiroaki.bdbridge \
  -- -recorderHost <recorder ip> -startTab guide
```

`-recorderHost` fills in the address, which is what a fresh install needs before it can do anything;
`-startTab` opens `guide`, `search`, `reservations`, `recordings` or `settings`; `-searchFor <word>` fills
in the search box and `-searchScope guide|reservations|recordings` picks which list it searches.

**A launch argument pins the value for that run.** Anything passed this way lands in `UserDefaults`'
argument domain, which outranks what the app saves, so the address typed into Settings appears to do
nothing while `-recorderHost` is in force. Launch without the flag to use the app normally.

The overnight guide refresh is not one of these. Pause the app in Xcode and, in the console,

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"jp.hiroaki.bdbridge.guideRefresh"]
```

which runs the real task the real way rather than only its body.

## What works

Finding the recorder: a button looks through the subnet the device is on and offers whatever answers as a
recorder, so the address does not have to be typed. On a home network 253 addresses take about seven seconds.

Typing in a recorder's address and connecting to it, fetching all four broadcasting types' guides and logos
into the on-device cache, browsing a day's programmes as a list or as a time-by-channel grid with the station
logos and genres, opening a programme, and listing the reservations the recorder holds. Verified against a
BDZ-FBT4100 from the simulator.

The grid mirrors the web app's: an hour ruler down the left and the channel names across the top, genre
colours, the elapsed part of what is on air shaded up to a red line at the current time, and a time axis
that pinches. Today opens at the current time, and pinching keeps the hour under the fingers where it is.

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

Searching, over any of three lists: programmes still to come, whose title or description contains the words,
across every broadcasting type and all eight days; the reservations the recorder holds; and the recordings on
its disk. The guide half reads the cache, so it works away from home. A result opens the same sheet its own
screen would, and a programme that is already reserved says so.

Reservation and recording rows carry the station's logo, in the same place the guide's rows do, with the
space held even where a station has none so that the names line up.

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

Waking the recorder, without being asked to: a BDZ-FBT4100 leaves the LAN on its own after a while and
then answers nothing at all, which is below the network standby that `X_PowerControl` can reach. A magic
packet is the only way back, and the recorder both says it takes one (`X_WakeupOnLAN` in its description)
and hands over the address to send it to (`X_GetPrivateIp`), so nothing has to be typed in — which matters,
because iOS cannot read an ARP table. Connecting sends the packet itself when the recorder answered nothing
at all, and waits for it to come back: measured at eleven seconds from launching the app to the recorder
answering again. Nobody has to know their recorder left the network.

Tapping the guide tab while it is already showing goes to what is on at this minute, and to today if
another day was open. The tab bar's own answer to that tap is the top of the broadcast day, which is four
in the morning; there is no declining it, so the screen waits for it and then goes where the tap meant.

## What is missing

The queue that holds reservations made while away from home. Finding the recorder over SSDP, which would be
quicker than looking through the subnet but needs an entitlement from Apple.
