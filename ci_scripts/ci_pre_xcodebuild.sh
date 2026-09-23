#!/bin/sh
# Xcode Cloud runs this before each xcodebuild action. Before an archive -- the build that goes to TestFlight
# -- it runs RecorderKit's tests, and their failure fails the build. Until this script, the cloud generated
# the project and uploaded whatever compiled; nothing checked it first.
#
# RecorderKit's tests are the ones that need nothing but the Mac: the protocol, the decoders, the guide cache
# and the queue, checked against the vectors in docs/port, in a minute or two. The app's own tests
# (BDBridgeTests) and the demo's UI tests need a simulator, which is what a Test action in the workflow is
# for; the scheme already lists both. The workflow itself is set up in App Store Connect, not here.
#
# Like ci_post_clone.sh, it has to live in ci_scripts at the root of the repository.
set -eu

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
    exit 0
fi

cd "$(dirname "$0")/../app/RecorderKit"

echo "--- RecorderKit: swift test"
swift test
