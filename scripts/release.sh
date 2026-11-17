#!/bin/bash
# Builds a Developer ID-signed, notarized GOG Disc Archiver and packs it into a notarized DMG in dist/.
#   scripts/release.sh            build, sign, notarize, staple, DMG
#   scripts/release.sh --publish  the same, then create a DRAFT GitHub release with the DMG
# Needs: "Developer ID Application" certificate in the keychain, notarytool profile "notary", gh login.
# The version comes from MARKETING_VERSION in the Xcode project (tag v<version>).
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

# Port 22 to GitHub can time out on this network; fetch over 443 unless told otherwise.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o Hostname=ssh.github.com -o Port=443 -o HostKeyAlias=github.com -o BatchMode=yes -o ConnectTimeout=15}"

APP_NAME="GOG Disc Archiver"
TEAM=679574875X
OUT=build/release
step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# notarize <file> <name>: submit to Apple, wait, print Apple's log on rejection.
notarize() {
  local json="$OUT/notary-$2.json" id
  xcrun notarytool submit "$1" --keychain-profile notary --wait --output-format json > "$json" || true
  id=$(sed -n 's/.*"id"[^"]*"\([^"]*\)".*/\1/p' "$json" | head -1)
  if ! grep -q '"status"[^"]*"Accepted"' "$json"; then
    cat "$json"; echo
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile notary
    fail "notarization of $2 not accepted"
  fi
  echo "accepted ($id)"
}

step "Checks"
[[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes; commit first"
grep -q "Developer ID Application: .*($TEAM)" <<<"$(security find-identity -v -p codesigning)" || fail "no Developer ID Application certificate for $TEAM"
xcrun notarytool history --keychain-profile notary >/dev/null 2>&1 || fail "notarytool profile 'notary' missing"
VERSION=$(xcodebuild -project GOGDiscArchiver.xcodeproj -scheme GOGDiscArchiver -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
BUILD=$(xcodebuild -project GOGDiscArchiver.xcodeproj -scheme GOGDiscArchiver -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}')
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION"
TAG="v$VERSION"
DMG="dist/GOG-Disc-Archiver-$VERSION.dmg"
echo "version $VERSION (build $BUILD), commit $(git rev-parse --short HEAD)"
if (( PUBLISH )); then
  git fetch -q origin
  git merge-base --is-ancestor HEAD origin/main || fail "HEAD is not pushed to origin/main; push first"
  ! gh release view "$TAG" >/dev/null 2>&1 || fail "release $TAG already exists; bump MARKETING_VERSION"
fi

step "Archive (Release, Developer ID)"
rm -rf "$OUT" && mkdir -p "$OUT" dist
xcodebuild -project GOGDiscArchiver.xcodeproj -scheme GOGDiscArchiver -configuration Release \
  -archivePath "$OUT/App.xcarchive" -derivedDataPath "$OUT/dd" archive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=$TEAM \
  OTHER_CODE_SIGN_FLAGS="--timestamp" > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; fail "archive failed (log: $OUT/build.log)"; }
APP="$OUT/App.xcarchive/Products/Applications/$APP_NAME.app"
[[ -d "$APP" ]] || fail "app missing from archive"

step "Verify signature"
codesign --verify --deep --strict "$APP"
SIG=$(codesign -dv --verbose=2 "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<<"$SIG" || fail "not signed with Developer ID"
grep -q "flags=.*runtime" <<<"$SIG" || fail "hardened runtime is off"
grep -q "Timestamp=" <<<"$SIG" || fail "signature has no secure timestamp"

step "Notarize the app (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
notarize "$OUT/app.zip" app
xcrun stapler staple -q "$APP"
xcrun stapler validate -q "$APP"

step "Build the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "Developer ID Application: " --timestamp "$DMG"   # matches the one Developer ID certificate by name
codesign --verify --strict "$DMG"

step "Notarize the DMG"
notarize "$DMG" dmg
xcrun stapler staple -q "$DMG"
xcrun stapler validate -q "$DMG"
GK=$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1); echo "$GK"
grep -q "Notarized Developer ID" <<<"$GK" || fail "Gatekeeper does not accept the DMG"
echo "$DMG ($(du -h "$DMG" | cut -f1))"

if (( PUBLISH )); then
  step "Draft GitHub release $TAG"
  gh release create "$TAG" "$DMG" --draft --target "$(git rev-parse HEAD)" \
    --title "$APP_NAME $VERSION" \
    --notes "Download **GOG-Disc-Archiver-$VERSION.dmg**, open it and drag **$APP_NAME** to Applications. Requires macOS 14 or later."
  echo "Draft created: add release notes and press Publish on GitHub."
else
  echo
  echo "Not published. Run with --publish to create a draft GitHub release."
fi
