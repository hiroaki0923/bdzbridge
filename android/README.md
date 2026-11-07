# RecBridge for Android

The Android app, in Kotlin and Jetpack Compose, over the same RecorderKit as the iOS app: RecorderKit stays in Swift
and is built for Android with the Swift SDK for Android, and the screens call it through
[swift-java](https://github.com/swiftlang/swift-java)'s JNI mode. Why this way, and what was measured on the way, is
in `docs/android-port-study.md`.

So far it connects to a recorder by its address, by the search for both kinds (レコーダーとテレビを探す), or to the
demo's invented recorder, and reads its reservations and its recordings. It reads only: nothing here wakes a recorder
or writes to one.

## Layout

- `core/` — the Swift side and the Android library around it. `Package.swift` and `Sources/AndroidBridge` are a thin
  layer over `app/RecorderKit` that hands the screens rows already worded as the iOS app words them; swift-java
  generates its Java side (`jp.hiroaki.bdbridge.bridge`) as the package is built. `build.gradle` builds the package
  for arm64 through swiftly, adds the generated Java to the library's sources, and packs the built libraries with
  Swift's runtime as jniLibs. `Tests/` runs on the Mac against the demo's recorder: `swift test` inside `core/`.
- `app/` — the Compose app: `Bridge.kt` turns the Swift calls into suspending ones, `AppState.kt` holds what the screens
  show, `Screens.kt` draws them.

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

## Building

```
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
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

What Swift hands back reaches Kotlin on Swift's own threads; `Bridge.kt` awaits it in a coroutine started on the main
thread, so the screens' state is only ever changed there. A failure comes as the iOS app's own sentence for it.
