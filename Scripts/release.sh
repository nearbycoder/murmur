#!/usr/bin/env bash
# Builds a Developer ID–signed, notarized release of Murmur.
#   ./Scripts/release.sh            archive, notarize and package into build/release
#   ./Scripts/release.sh publish    ...then tag v<version> and publish a GitHub release
#
# Signing and notarization go through the Apple account you're signed into in Xcode
# (Xcode → Settings → Accounts), or, with no account signed in, an App Store Connect
# API key (Admin role): set ASC_KEY_PATH (the .p8 file), ASC_KEY_ID and ASC_ISSUER_ID.
# Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist before each release.
set -euo pipefail

cd "$(dirname "$0")/.."
ACTION="${1:-build}"
TEAM_ID="${TEAM_ID:-4F2YLTHL8T}"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)"
TAG="v$VERSION"
ARCHIVE="build/Murmur.xcarchive"
NOTARIZED="build/notarized"
OUT="build/release"

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen"; exit 1; }

AUTH_ARGS=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_ID:?Set ASC_KEY_ID with ASC_KEY_PATH}" "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID with ASC_KEY_PATH}"
  AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

if [[ "$ACTION" == "publish" ]] && git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists. Bump the version in Resources/Info.plist first."
  exit 1
fi

echo "→ Generating Xcode project"
xcodegen generate --quiet

echo "→ Running tests"
swift test --package-path Packages/MurmurKit --quiet
xcodebuild test -project Murmur.xcodeproj -scheme Murmur -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet

echo "→ Archiving Murmur $VERSION"
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project Murmur.xcodeproj \
  -scheme Murmur \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  -quiet

echo "→ Signing with Developer ID and uploading for notarization"
# With an API key, export the signed app and notarize it with notarytool; otherwise Xcode uploads it.
DESTINATION=upload
[[ ${#AUTH_ARGS[@]} -gt 0 ]] && DESTINATION=export
mkdir -p build
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>$DESTINATION</string>
</dict>
</plist>
EOF
rm -rf build/export
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  -quiet

echo "→ Waiting for Apple's notary service"
if [[ "$DESTINATION" == export ]]; then
  rm -rf "$NOTARIZED"
  mkdir -p "$NOTARIZED"
  ditto build/export/Murmur.app "$NOTARIZED/Murmur.app"
  ditto -c -k --keepParent "$NOTARIZED/Murmur.app" build/notarize-upload.zip
  if ! xcrun notarytool submit build/notarize-upload.zip \
      --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
      --wait --timeout 30m >build/notarize.log 2>&1 \
     || ! grep -q "status: Accepted" build/notarize.log; then
    echo "Notarization failed; see build/notarize.log"
    exit 1
  fi
  xcrun stapler staple "$NOTARIZED/Murmur.app" >/dev/null
else
  for attempt in $(seq 1 80); do
    rm -rf "$NOTARIZED"
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$NOTARIZED" >build/notarize.log 2>&1; then
      break
    fi
    if [[ "$attempt" == 80 ]]; then
      echo "Notarization did not finish in time; see build/notarize.log"
      exit 1
    fi
    sleep 15
  done
fi

APP="$NOTARIZED/Murmur.app"
echo "→ Verifying"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP" >/dev/null
spctl --assess --type exec "$APP"

echo "→ Packaging"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Murmur-$VERSION.zip"

# Styled installer DMG (background, icon layout, volume icon) via dmgbuild.
if [[ ! -x build/.venv/bin/dmgbuild ]]; then
  python3 -m venv build/.venv
  build/.venv/bin/pip install --quiet dmgbuild
fi
build/.venv/bin/dmgbuild -s Resources/dmg/settings.py -D app="$APP" \
  "Murmur" "$OUT/Murmur-$VERSION.dmg" >/dev/null 2>&1
# Version-less copy so …/releases/latest/download/Murmur.dmg always points at the newest build.
cp "$OUT/Murmur-$VERSION.dmg" "$OUT/Murmur.dmg"
(cd "$OUT" && shasum -a 256 "Murmur-$VERSION.dmg" "Murmur.dmg" "Murmur-$VERSION.zip" > SHA256SUMS.txt)

echo "✓ Murmur $VERSION is signed, notarized and packaged in $OUT"

if [[ "$ACTION" == "publish" ]]; then
  echo "→ Publishing GitHub release $TAG"
  git tag -a "$TAG" -m "Murmur $VERSION"
  git push origin "$TAG"
  NOTES_ARGS=(--generate-notes)
  [[ -n "${RELEASE_NOTES:-}" ]] && NOTES_ARGS=(--notes-file "$RELEASE_NOTES")
  gh release create "$TAG" \
    "$OUT/Murmur-$VERSION.dmg" \
    "$OUT/Murmur.dmg" \
    "$OUT/Murmur-$VERSION.zip" \
    "$OUT/SHA256SUMS.txt" \
    --title "Murmur $VERSION" \
    --latest \
    "${NOTES_ARGS[@]}"
fi
