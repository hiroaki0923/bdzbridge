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
#
# The build number comes from CI_BUILD_NUMBER, which Xcode Cloud counts up for the product, so no version
# has to be edited by hand between builds. App Store Connect refuses a number it has already accepted; if a
# cloud number ever collides with one uploaded from a Mac, raise the next build number in the workflow.
set -eu

# This writes Signing.local.xcconfig, which on a development machine holds the team and belongs to whoever
# checked out the repository. Only run where that file is ours to write.
if [ "${CI:-}" != "TRUE" ] && [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    echo "this script is for Xcode Cloud; it would overwrite Signing.local.xcconfig" >&2
    exit 1
fi

cd "$(dirname "$0")/../app"

echo "--- installing XcodeGen"
brew install xcodegen

echo "--- writing the signing configuration"
# Signing.xcconfig includes this file optionally, so a local checkout keeps its own and Xcode Cloud gets one
# made here. Xcode Cloud manages the certificates and profiles itself; only the team has to be named.
: > Signing.local.xcconfig
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    echo "DEVELOPMENT_TEAM = $DEVELOPMENT_TEAM" >> Signing.local.xcconfig
else
    echo "DEVELOPMENT_TEAM is not set in the workflow; the archive will not be signed" >&2
fi
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
    echo "CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER" >> Signing.local.xcconfig
fi
echo "--- signing configuration:"
sed -E 's/= .*/= <set>/' Signing.local.xcconfig

echo "--- generating BDBridge.xcodeproj"
xcodegen generate
