# RecBridge for Android

The Android app, in Kotlin and Jetpack Compose, over the same RecorderKit as the iOS app: RecorderKit stays in Swift
and is built for Android with the Swift SDK for Android, and the screens call it through
[swift-java](https://github.com/swiftlang/swift-java)'s JNI mode. Why this way, and what was measured on the way, is
in `docs/android-port-study.md`.

It is the iOS app's model with Android's screens over it: the same `AppModel` (`app/RecBridgeModel/Sources/
RecBridgeModel`), one for the process as the iOS app has one, with a window in front of it for each screen. So far it
connects to a recorder as the iOS app's tutorial does -- by the search for both kinds (レコーダーとテレビを探す), by an
address, or to the demo's invented recorder -- and shows the guide as the iOS guide does (a broadcasting type, a
broadcast day, opening at what is on now, 今 and 番組表を更新, and what an empty guide says), as its list, every station
or one, or as its grid, time down and the stations across, laid out by the model's rules (`GuideGridDay`,
`GuideGridScale`, `GuideMark`, `GuideGenre`) and kept as the iOS screens keep the list or the grid and the grid's
scale; the grid moves either way at once under a finger and flings, and its time axis pinches or is zoomed by its
buttons, the time under the fingers or in the middle held still, at the column the reader is at; the reservations and
the recordings as lists -- the reservations' with its 種類 and 並び順, pulled down to send what waits and read again,
a row swiped to the left to delete it after its question and a waiting row a device refused swiped to the right to
send it again, over the model's state of the screen (`ReservationsState`), with the recorder's
own keyword conditions (おまかせ・まる録) on a page of their own, a row swiped to delete it and a form for a new one
(`RecorderRulesState`, `RecorderRuleSheetState`) -- and the two sheets
that write: a programme's, which reserves it on the
recorder or the television (where it goes, the disk, the mode, the repeat, what it would clash with) and deletes or
sends again what waits for it, and a reservation's, which changes and deletes it; and a recording's, which plays,
protects and deletes it. What each sheet holds, offers, holds back and says is the model's own state of it
(`ProgramSheetState`, `ReservationSheetState`, `TitleSheetState`), as on iOS, and each sheet labels its rows and
buttons in the model's words too: its state's own, and those the sheets say alike (`SheetWords`), which Kotlin keeps
from the model's start for the rows a programme's sheet shows before its window is first read. The recordings are a list,
the same recordings gathered into programmes, or the ones recorded more than once (一覧, まとめ, 重複): a row swiped to the left
asks to delete it or takes the protection off a protected one, a programme opens a page with the selection that bulk
deletes and protects need, the duplicates are scanned for and their ticked copies deleted, and the bulk job's bar
says how far it is with 中止, over the model's states of them (`RecordingsState`, `GroupSheetState`,
`DuplicatesState`). Its search is one box over the
programmes still to come, the reservations and the recordings, with the three as chips under it, over the model's
state of it (`SearchState`): what is found opens the same sheets. On a window 840 dp wide or more -- a tablet in
landscape -- the guide, the search, the reservations and the recordings' list and duplicates show what is opened from
them in a pane beside the list rather than on a sheet, a form of Android's own, since the iOS app is an iPhone's alone:
the same content, and while it has a request of its own out, by the rule that keeps a sheet from being put away,
nothing that would replace it is taken. A turn or a resize does not make the activity again (`configChanges` in the
manifest), and changes the form, not what is shown: the lists stay where they were scrolled, the top app bars keep
what they have open, and what is open goes from the pane onto a sheet or back as the width crosses 840 dp, with the
one window it has to the model, so its picks, its question and a request of its own still out go with it. Its settings
have the recorder (what it says of itself, how the link stands, its address and MAC, このアドレスに接続 and 再接続), the mode
a new reservation starts at, the television (what it says of itself, 対応状況を調べる, 登録する or 再接続, the helper on it,
テレビを外す), the search and the recorders and televisions it found, which stations the guide shows and in what order,
the guide kept on the device and which device it is fetched from, the demo and ご利用上の注意, over the model's states of
them (`RecorderSettingsState`, `TVSettingsState`, `ChannelsState`) and in the model's words: `SettingsWords` and the
recorder's part's own, and the television's part's, which Kotlin keeps from the model's start as it keeps the sheets'.
The chooser is the tutorial: the introduction and the four steps, then the search, an address and the demo, over the
model's state of it (`WelcomeState`) and its sentences
(`Tutorial`), but for three that are Android's own (the introduction and the second step's title say this device, and
the third step has no detail, as Android asks no local network question); the settings' セットアップ手順を見る opens it
again. A television is added from a search, the settings or the
strip's 登録 on a sheet over the model's state of it (`TVRegisterState`), and the helper on it on another
(`HelperRegisterState`), each in its state's words, and what the television speaks is read on a page in the model's
words too (`TVCapabilitiesWords`); the television's words that never change -- the part's, the sheets' and the page's --
are handed over once, at the model's start (`TelevisionWordsText`), as are the guide's and the stations' screen's
words (`GuideWordsText`) and the names of the tabs (`TabWordsText`). As on iOS, a
connect wakes a recorder that does not answer with a magic packet when its MAC is known. The stations' logos are on the
guide's rows, on the reservations' and the recordings' and on the search's; the demo's stations have tiles that Kotlin
draws (`Tiles.kt`) and hands to the model as files (`TileDrawer`). The model is told when the network changes, by a
`ConnectivityManager` callback (`RecBridgeApp.networkChanged`), and each line of a search for devices is written to
the system log under the tag `RecBridgeScan` (`adb logcat -s RecBridgeScan`): counts and codes, as the iOS `ScanLog`'s
are, never an address or a name. What a search for devices came to, which iOS
announces to VoiceOver, is a polite live region for TalkBack. At night, with no screen, it wakes the recorder, sends
what waits for the recorder and the television and fetches the guide, as the iOS app's background task does, and the
settings say when it last fetched it (最終自動更新): below, "The overnight run".

## Layout

- `core/` — the Swift side and the Android library around it. `Sources/AndroidBridge` holds the windows over the
  model: `App.swift` (the model, made once, on `Surroundings` of Android's own, and how a window tells Kotlin that what
  it shows has changed), `Devices.swift`, `Guide.swift` (the list or the grid, made again as each minute turns while
  the grid is shown, which is how its line at now and what is on the air move), `Lists.swift`, `Recordings.swift`
  (the bulk job's bar, a programme's page and the duplicates), `Conditions.swift`
  (the keyword conditions and their form), `Strip.swift` (the strip at the top of
  every screen, as the model chooses and words its line and its button, and the one a recording's sheet and a new
  condition's form have of their own, without the demo's line),
  `Search.swift` (the search, whose window runs for as long as the
  screen is on what the iOS screen runs with `task(id:)`), `Settings.swift` (the settings, whose fields keep what is typed and
  take the model's value when the model sets them itself), `Television.swift` (the television's sheets, its part of
  the settings and the televisions a search found), `Kept.swift` (where the television's registration and the
  helper's token are kept), `Night.swift` (the overnight run, and the rule that it goes only on the network of a device
  saved), `Channels.swift` (the stations' page) and `Sheets.swift`
  (the sheets, a window made as a sheet opens and
  ended as it closes, doing for the sheet what the iOS sheet does with `onChange` and `task(id:)`). A window is a plain class, since swift-java
  cannot hand Kotlin a class on the main actor: what the reader does goes to the model as an async call, and what the
  screen shows is one value, worded as the iOS screen words it, read again each time the window says it changed
  (`ScreenListener`, which Kotlin implements; it is told nothing more, as structs cannot go that way). swift-java
  generates the Java side (`jp.hiroaki.bdbridge.bridge`) as the package is built. `build.gradle` builds the package for
  arm64 through swiftly, adds the generated Java to the library's sources, and packs the built libraries with Swift's
  runtime as jniLibs. `Tests/` runs the windows on the Mac against the demo's recorder.
- `app/` — the Compose app: `Bridge.kt` opens the model, keeps what each window shows for the screens and turns the
  windows' calls into suspending ones. The screens are Material 3's, as an Android app's are: `Theme.kt` (the colours,
  the text marked as Japanese), `App.kt` (the place to choose a recorder over the rest, and the navigation: a bar at
  the foot of a phone, a rail down the side of anything 600 dp wide, the screen moved from one to the other rather
  than made again), `Guide.kt`, `GuideGrid.kt` (the grid: one gesture handler for the pan, the fling and the pinch, the
  rulers placed from the same position as the body, and only the columns and the hours around what is in view
  composed), `Search.kt`, `Lists.kt`, `Panes.kt` (the pane beside a list on a wide window, the list and the top app bar
  at the same place whatever the width, what is refused while what is open in the pane is held, and what it says while
  nothing is), `Recordings.kt` (the job's bar, a programme's page, the duplicates), `Conditions.kt` (the keyword
  conditions' page and the full-screen form for a new one), `Devices.kt`, `Sheets.kt` (the sheets, which open at once
  with what the row says and fill in as their window is read, the window the screen opened for what is open, whichever
  form shows it), `Settings.kt` (the settings and ご利用上の注意), `Television.kt` (the television's sheets, the
  televisions a search found, and the television's 対応状況), `Channels.kt` (the stations' page, a station dragged by
  its handle to another place), `Night.kt` (the overnight run's worker, and when it is asked for), and `Parts.kt` (the
  empty states, the marks, the strip with its 登録 sheet put up at one place whichever strip it was pressed on, what a
  search found, and a row with what a swipe either way asks for, which never takes the row with it).

The model's settings are kept in `files/settings/recbridge.plist`: Foundation on Android keeps a `UserDefaults` suite
named by the path of its file, and writes it out only when told to, which `WrittenDefaults` does at each change. One
`WrittenDefaults` is made for the file in a process, which the screens' model and an overnight run share. The
television's registration and the helper's token are kept apart from them, in `no_backup/` (`Context.getNoBackupFilesDir`),
which Android's backup rules always leave out, to the cloud and to another device alike: as on iOS, they stay on the
device, and a device the app comes to some other way registers again.

## The overnight run

The run is the model's (`BackgroundWork.refreshNow(in:)`), handed by `NightRun` what it reaches of Android: the
model's defaults object, the app's folder, the sessions the screens send through, the television's registration and
notifications that do nothing, as the app posts none yet. `NightWorker` is asked for at each start of the app and
again as it begins, as on iOS: one request waits at a time, tagged `overnight`, from the next 02:00 by the model's rule
(`BackgroundWork.nextNightlyRun`), on an unmetered network, charging or not. A request not yet begun is replaced; a run
under way is left alone, since replacing it would stop it.

WorkManager can wait for Wi-Fi but not for the home's, so the run's first step is a rule of Android's own
(`NightRun.mayGo`): the recorder or the television saved is at an IPv4 address on the network of one of the device's
interfaces, by that interface's mask. Otherwise it ends there, with nothing opened, sent or written. No location
permission is asked for and no network's name is read. An address the rule cannot place -- a name, an IPv6 address --
lets the run go, as the iOS run goes whenever it has a connection, rather than stop every night for good.

It goes through the bridge's call, which runs Swift's main queue while it is out, with no Activity as with one. When
the system stops the worker, the Swift task is cancelled (`NightRun.stop`), which is what the model's rules for a run
whose time is up look at, and the worker ends without waiting for Swift. WorkManager runs a stopped run again later;
that one does nothing, as iOS runs no night twice. WorkManager adds to the manifest `WAKE_LOCK`,
`RECEIVE_BOOT_COMPLETED` and `FOREGROUND_SERVICE`, its initializer, services and receivers, and Room's invalidation
service, and keeps its database in `no_backup/`.

## What has to be in place

- swiftly with Swift 6.4.2, and the Swift SDK for Android 6.4.2 set up against NDK r30 (`docs/android-port-study.md`,
  「Android 向けのビルドとテストのやり方」).
- The Android SDK with platform 34 and NDK 30.0.16248370, named by `ANDROID_HOME`.
- JDK 17 or later as `JAVA_HOME`. With Homebrew's, name the JDK's own home
  (`/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`), not the `opt` folder: swift-java reads the
  version from the `release` file there.
- swift-java's Java support library, SwiftKitCore 0.7.0, in the local Maven repository: it is not on Maven Central.
  Once, after `swift package resolve` inside `core/`:

  ```
  ./core/.build/checkouts/swift-java/gradlew --project-dir core/.build/checkouts/swift-java \
      :SwiftKitCore:publishToMavenLocal -PswiftJavaJdk=21
  ```

  `-PswiftJavaJdk` names the JDK it builds with; without it swift-java asks for JDK 25.

## Building and testing

```
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The windows' tests run on the Mac, inside `core/`. Kotlin's listeners need Java compiled as the package is built,
which swift-java does with Gradle, so the build is let out of SwiftPM's sandbox and given the JDK:

```
JAVA_HOME=<the JDK's home> swift test --disable-sandbox
```

`app/src/androidTest` drives the demo through the screens on a device or an emulator: the guide opening at what is
on now, a programme's sheet, another day, the grid with a block's sheet and its zoom buttons, the reservations and the
recordings, and leaving the demo. Before the model first opens it deletes what the app keeps, a saved address among
it, and it uses only the demo, so it reaches nothing on the LAN. `NightTests` sees the overnight run asked for once the
app has started, and runs the worker itself in the demo. With more than one device attached, name the one to use:

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
```

The tests of the pane beside a list run only on a window 840 dp wide or more and skip themselves on a narrower one. An
emulator is made that wide with `adb shell wm size 1280x800` and `adb shell wm density 160`, and put back with
`adb shell wm size reset` and `adb shell wm density reset`. The tests that turn the device turn it the other way from
how it is and put it back as it was. At either size the emulator's display does not rotate, and the upright window is
letterboxed: at 1280x800 to about 580 dp wide, so the turn crosses both 600 dp and 840 dp; at
`adb shell wm size 1760x1100`, with the same density, to about 800 dp, so it crosses 840 dp alone, as a tablet does
going from its side to upright.

A file added to `app/RecorderKit` is sometimes not seen by the Android build, which goes on with the build
description SwiftPM wrote before ("cannot find type" for something the Mac's build finds): deleting
`core/.build/aarch64-unknown-linux-android28/debug/description.json` has SwiftPM write it again.

The first build compiles RecorderKit for Android, which takes a minute or two. A debug APK for arm64 alone is about
160 MB: the Swift runtime and Foundation are in it, with their symbols, and nothing is shrunk.

A release build shrinks the Java side with R8 (`core/consumer-rules.pro` keeps what the Swift side reaches by name),
builds the Swift side optimised and strips the libraries' symbols. There is no release key yet, so to try one on a
device it is signed with the debug key:

```
./gradlew :app:assembleRelease -PswiftConfiguration=release -PsignWithDebugKey
```

That came to 76 MB. Of it, ICU's data for Foundation's dates and text is 38 MB: RecorderKit words dates in Japanese
through `DateFormatter`, which needs it.

Swift's main actor needs the app's help on Android: nothing runs Swift's main queue there, so a job on the main
actor, where much of RecorderKit runs, would wait for ever. Foundation's run loop serves the main queue when it runs
on the main thread, so while the app is on screen, while a call to Swift is out, and while a step of a bulk job is
held -- the step in hand when the reader leaves the app, finished as on iOS (`StepsHeld`, which `Surroundings.holdTime`
counts in `App.swift`, and which `runWhatWaitsOnTheMainQueue()` answers with) -- `Bridge.kt` calls
`runWhatWaitsOnTheMainQueue()` (`core/Sources/AndroidBridge/MainQueue.swift`) from the main thread about once a frame
-- the calls so that one made as the app goes out of sight, the model told that it has, is answered: it runs the run
loop once,
doing what has come since the last call, and returns at once. Only public calls are made; the ways that wake the
looper exactly when work comes, by the main queue's own file descriptor or by an executor of the app's own for the
main actor, are not public in Swift 6.4.2. Which thread is the main one is Foundation's to say: the one that loaded
it. So the first call to Swift in a process is made on Android's main thread, by the model's opening or by the
overnight run's worker, which makes its calls there; made first on another thread, nothing on the main actor runs.

A window tells Kotlin of a change on the main thread, from the model's own turn; what a read hands back reaches
Kotlin on Swift's own threads, is turned into Kotlin's values off the main thread, and is put where Compose reads it
on the main thread. A window is read one read at a time, and only its latest: told again while a read is out, it is
read once more after it.
