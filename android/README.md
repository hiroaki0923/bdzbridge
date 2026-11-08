# RecBridge for Android

The Android app, in Kotlin and Jetpack Compose, over the same RecorderKit as the iOS app: RecorderKit stays in Swift
and is built for Android with the Swift SDK for Android, and the screens call it through
[swift-java](https://github.com/swiftlang/swift-java)'s JNI mode. Why this way, and what was measured on the way, is
in `docs/android-port-study.md`.

It is the iOS app's model with Android's screens over it: the same `AppModel` (`app/RecorderKit/Sources/
RecBridgeModel`), one for the process as the iOS app has one, with a window in front of it for each screen. So far it
connects to a recorder as the iOS app's tutorial does -- by the search for both kinds (レコーダーとテレビを探す), by an
address, or to the demo's invented recorder -- and shows the guide as the iOS guide's list does (a broadcasting type,
every station or one, a broadcast day, opening at what is on now, 今 and 番組表を更新, and what an empty guide says),
a programme's sheet without its reservation part, and the reservations and the recordings as lists. It writes nothing
to a device yet. As on iOS, a connect wakes a recorder that does not answer with a magic packet when its MAC is known.

## Layout

- `core/` — the Swift side and the Android library around it. `Sources/AndroidBridge` holds the windows over the
  model: `App.swift` (the model, made once, on `Surroundings` of Android's own, and how a window tells Kotlin that what
  it shows has changed), `Devices.swift`, `Guide.swift` and `Lists.swift`. A window is a plain class, since swift-java
  cannot hand Kotlin a class on the main actor: what the reader does goes to the model as an async call, and what the
  screen shows is one value, worded as the iOS screen words it, read again each time the window says it changed
  (`ScreenListener`, which Kotlin implements; it is told nothing more, as structs cannot go that way). swift-java
  generates the Java side (`jp.hiroaki.bdbridge.bridge`) as the package is built. `build.gradle` builds the package for
  arm64 through swiftly, adds the generated Java to the library's sources, and packs the built libraries with Swift's
  runtime as jniLibs. `Tests/` runs the windows on the Mac against the demo's recorder.
- `app/` — the Compose app: `Bridge.kt` opens the model, keeps what each window shows for the screens and turns the
  windows' calls into suspending ones; `Screens.kt` draws them.

The model's settings are kept in `files/settings/recbridge.plist`: Foundation on Android keeps a `UserDefaults` suite
named by the path of its file, and writes it out only when told to, which `WrittenDefaults` does at each change.

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
on now, a programme's sheet, another day, the reservations and the recordings, and leaving the demo. Before the model
first opens it deletes what the app keeps, a saved address among it, and it uses only the demo, so it reaches nothing
on the LAN. With more than one device attached, name the one to
use:

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
```

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
on the main thread, so while the app is on screen, and while a call to Swift is out, `Bridge.kt` calls
`runWhatWaitsOnTheMainQueue()` (`core/Sources/AndroidBridge/MainQueue.swift`) from the main thread about once a frame
-- the calls so that one made as the app goes out of sight, the model told that it has, is answered: it runs the run
loop once,
doing what has come since the last call, and returns at once. Only public calls are made; the ways that wake the
looper exactly when work comes, by the main queue's own file descriptor or by an executor of the app's own for the
main actor, are not public in Swift 6.4.2.

A window tells Kotlin of a change on the main thread, from the model's own turn; what a read hands back reaches
Kotlin on Swift's own threads, is turned into Kotlin's values off the main thread, and is put where Compose reads it
on the main thread. A window is read one read at a time, and only its latest: told again while a read is out, it is
read once more after it.
