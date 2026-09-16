#!/bin/sh
# Xcode Cloud runs this after cloning and before building, which is where this project's Xcode project comes
# from: it regenerates it from app/project.yml with XcodeGen, so that a cloud build matches the definition
# rather than whatever was last committed.
#
# It has to live in ci_scripts at the root of the repository. A copy beside the Xcode project is reported as
# "Post-Clone script not found at ci_scripts/ci_post_clone.sh".
#
# The workflow has to set one environment variable:
#   DEVELOPMENT_TEAM   the ten-character team identifier, as Signing.local.xcconfig holds locally
set -eu
cd "$(dirname "$0")/../app"

echo "--- installing XcodeGen"
brew install xcodegen

echo "--- writing the signing configuration"
# Signing.xcconfig includes this file optionally, so a local checkout keeps its own and Xcode Cloud gets one
# made here. Xcode Cloud manages the certificates and profiles itself; only the team has to be named.
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    echo "DEVELOPMENT_TEAM = $DEVELOPMENT_TEAM" > Signing.local.xcconfig
else
    echo "DEVELOPMENT_TEAM is not set in the workflow; the archive will not be signed" >&2
fi

echo "--- generating BDBridge.xcodeproj"
xcodegen generate
