#!/bin/sh
# Archives the app and uploads it to TestFlight.
#
# Needs two gitignored files next to project.yml: Signing.local.xcconfig with DEVELOPMENT_TEAM, and
# TestFlight.local.env with the App Store Connect API key:
#
#   ASC_KEY_ID=ABC123DEFG
#   ASC_ISSUER_ID=12345678-1234-1234-1234-123456789012
#   ASC_KEY_PATH=$HOME/.appstoreconnect/private_keys/AuthKey_ABC123DEFG.p8
#
# The build number is the minute of the upload, so every run is newer than the last without anybody
# editing project.yml. Signing is automatic: xcodebuild registers the app id and makes the profiles and
# the distribution certificate through the key. Paths with spaces are not handled.
set -eu
cd "$(dirname "$0")/.."
. ./TestFlight.local.env
team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Signing.local.xcconfig)
build=$(date +%Y%m%d%H%M)
auth="-allowProvisioningUpdates -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"

xcodegen generate -q
rm -rf build/BDBridge.xcarchive build/export
xcodebuild -project BDBridge.xcodeproj -scheme BDBridge -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/BDBridge.xcarchive \
    CURRENT_PROJECT_VERSION="$build" $auth archive -quiet

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/BDBridge.xcarchive \
    -exportOptionsPlist build/ExportOptions.plist -exportPath build/export $auth
echo "build $build uploaded; TestFlight lists it once App Store Connect has processed it (usually minutes)"
