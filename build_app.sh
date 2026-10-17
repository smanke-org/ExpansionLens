#!/bin/bash
# Builds the GitHub release of ExpansionLens into .build/app/ExpansionLens.app, ready for
# ./notarize.sh and ./make_dmg.sh.
#
# ExpansionLens syncs through CloudKit, which needs a provisioning profile in the app. So this
# archives the app, then exports it for Developer ID with automatic signing: Xcode (signed
# in to the developer account) fetches or renews the Developer ID profile as needed.
#
# The App Store build is archived from Xcode instead (configuration AppStore).
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate >/dev/null
rm -rf .build/xcode-release .build/app .build/ExpansionLens.xcarchive .build/export
xcodebuild -project ExpansionLens.xcodeproj -scheme ExpansionLens -configuration Release \
  -destination 'generic/platform=macOS' -archivePath .build/ExpansionLens.xcarchive \
  -derivedDataPath .build/xcode-release -allowProvisioningUpdates archive | grep -E "error:|ARCHIVE" || true
[ -d .build/ExpansionLens.xcarchive ] || { echo "Archive failed." >&2; exit 1; }

cat > .build/export-options.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>32CWL275JJ</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath .build/ExpansionLens.xcarchive -exportPath .build/export \
  -exportOptionsPlist .build/export-options.plist -allowProvisioningUpdates | grep -E "error:|EXPORT" || true

APP=".build/export/ExpansionLens.app"
[ -d "$APP" ] || { echo "Export failed." >&2; exit 1; }
for f in MacOS/ExpansionLens; do
  lipo -archs "$APP/Contents/$f" | grep -q "x86_64 arm64\|arm64 x86_64" || { echo "$f isn't universal." >&2; exit 1; }
  if codesign -d --entitlements - "$APP/Contents/$f" 2>/dev/null | grep -q get-task-allow; then
    echo "$f carries get-task-allow; notarization would reject it." >&2; exit 1
  fi
done
# CloudKit only works with the Developer ID profile inside, pointed at Production.
[ -f "$APP/Contents/embedded.provisionprofile" ] || { echo "No provisioning profile in the app; CloudKit won't work." >&2; exit 1; }
# (plutil can't be used here: it reads the dots in the key as a path.)
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
case "$ENTITLEMENTS" in
  *"<key>com.apple.developer.icloud-container-environment</key><string>Production</string>"*) ;;
  *) echo "The app isn't set to CloudKit's Production environment." >&2; exit 1 ;;
esac

mkdir -p .build/app
ditto "$APP" .build/app/ExpansionLens.app
codesign --verify --deep --strict .build/app/ExpansionLens.app
codesign -dvv .build/app/ExpansionLens.app 2>&1 | grep -E "^Authority=Developer ID|^Timestamp="
echo "Built .build/app/ExpansionLens.app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .build/app/ExpansionLens.app/Contents/Info.plist))"
