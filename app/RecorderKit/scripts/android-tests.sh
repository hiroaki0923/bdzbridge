#!/bin/sh
# Builds RecorderKit's tests for Android and runs them on the one device or emulator adb sees. The package's
# Android check runs this (.github/workflows/android.yml), and so can anyone with the toolchain
# (docs/android-port-study.md).
#
#   scripts/android-tests.sh build <arch>    arch: aarch64 or x86_64, the device's
#   scripts/android-tests.sh run <arch> [RecorderKitTests.<Class>[/<test>][,...]]    all of them unless named
#
# SWIFT is the swift to build with, "swift" unless set. Xcode's cannot build for Android, so on a Mac it is
# swiftly's: SWIFT="swiftly run swift +6.4.2". ANDROID_NDK_HOME is the NDK the Swift SDK for Android was set up
# with, SCRATCH where the build goes (the package's .build unless set).
set -eu

command=${1:?build or run}
arch=${2:?aarch64 or x86_64}
shift 2
swift=${SWIFT:-swift}
sdk=${SWIFT_ANDROID_SDK:-swift-6.4.2-RELEASE_android}
triple=$arch-unknown-linux-android28
package=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-$package/.build}
device=/data/local/tmp/recorderkit

case $command in
build)
    # $swift is split into words on purpose: it may be a command with arguments of its own.
    $swift build --package-path "$package" --scratch-path "$scratch" --build-tests \
        --swift-sdk "$sdk" --triple "$triple"
    ;;
run)
    # XCTest is there only as a shared library, so the tests are run as a program that loads theirs, with
    # Swift's runtime and the NDK's C++ library beside it.
    products=$scratch/out/Products/Debug-android-$arch
    resources=$($swift sdk configure --show-configuration "$sdk" "$triple" | sed -n 's/^swiftResourcesPath: //p')
    libcxx=$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/"$arch"-linux-android/libc++_shared.so)
    adb shell rm -rf "$device"
    adb shell mkdir -p "$device/lib" "$device/tmp" "$device/docs"
    adb push "$products/RecorderKitTests-test-runner" "$products/RecorderKitTests.so" "$device/"
    adb push "$resources"/android/*.so "$libcxx" "$device/lib/"
    # The vectors the tests check the package against, found by RECORDERKIT_VECTORS (Vectors.swift).
    adb push "$package/../../docs/port" "$device/docs/"
    adb shell "cd $device && TMPDIR=$device/tmp HOME=$device RECORDERKIT_VECTORS=$device/docs/port \
LD_LIBRARY_PATH=$device:$device/lib ./RecorderKitTests-test-runner --testing-library xctest $*"
    ;;
*)
    echo "usage: $0 build|run aarch64|x86_64" >&2
    exit 64
    ;;
esac
