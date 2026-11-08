# The Swift side calls into swift-java's Java support and into the generated wrappers by their names (JNI), which
# R8 cannot see: neither is to be renamed or removed.
-keep class org.swift.swiftkit.** { *; }
-keep class jp.hiroaki.bdbridge.bridge.** { *; }
# SwiftKitCore's annotations name JDK Flight Recorder's, which Android has not: annotations only, nothing runs them.
-dontwarn jdk.jfr.**
