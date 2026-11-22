#!/bin/sh
# Archive a Release build of Wake On and upload it to App Store Connect for TestFlight.
# Run from native/ios: scripts/testflight.sh
# Signs and uploads with the App Store Connect API key in ~/.appstoreconnect/deploy.env
# (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH), so no Xcode prompts. The key never leaves that
# folder. The build number is the current time (TestFlight needs it to go up every upload).
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
env_file="$HOME/.appstoreconnect/deploy.env"
[ -f "$env_file" ] || { echo "Missing $env_file"; exit 1; }
ASC_KEY_ID=$(sed -n 's/^ASC_KEY_ID=//p' "$env_file" | tr -d '"')
ASC_ISSUER_ID=$(sed -n 's/^ASC_ISSUER_ID=//p' "$env_file" | tr -d '"')
ASC_KEY_PATH=$(eval echo "$(sed -n 's/^ASC_KEY_PATH=//p' "$env_file" | tr -d '"')")
[ -f "$ASC_KEY_PATH" ] || { echo "The key file named in $env_file is missing"; exit 1; }
auth="-authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"

build=$(date -u +%Y%m%d%H%M)
out=build-testflight
rm -rf "$out"
echo "Archiving build $build…"
# shellcheck disable=SC2086
xcodebuild -project WakeOn.xcodeproj -scheme WakeOn -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/WakeOn.xcarchive" \
  -allowProvisioningUpdates $auth CURRENT_PROJECT_VERSION="$build" archive -quiet

app="$out/WakeOn.xcarchive/Products/Applications/WakeOn.app"
if strings "$app/WakeOn" | grep -qi MediaRemote; then
  echo "Release binary mentions MediaRemote (private API): App Store Connect would reject it."; exit 1
fi
[ -f "$app/PrivacyInfo.xcprivacy" ] || { echo "Privacy manifest missing from the app."; exit 1; }
grep -q 'static let url: URL? = nil' WakeOn/LobbyServer.swift && \
  echo "Note: LobbyServer.url isn't set, so invite codes won't work in this build."

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>JDR6VAV2RA</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
echo "Uploading…"
# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$out/WakeOn.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates $auth
echo "Uploaded build $build. Waiting for App Store Connect to process it…"
# Apple can still reject the build here (for example a missing purpose string), after the
# upload itself succeeded, so wait for the verdict instead of assuming it worked.
node scripts/asc-upload-status.mjs com.kamikaz1k.wakeon "$build" 30
