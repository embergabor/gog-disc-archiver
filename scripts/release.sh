#!/bin/bash
# Builds a Developer ID-signed, notarized GOG Disc Archiver and zips it into dist/.
#   scripts/release.sh            build, sign, notarize, staple, zip
#   scripts/release.sh --publish  the same, then create a DRAFT GitHub release with the zip
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

step "Checks"
[[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes; commit first"
grep -q "Developer ID Application: .*($TEAM)" <<<"$(security find-identity -v -p codesigning)" || fail "no Developer ID Application certificate for $TEAM"
xcrun notarytool history --keychain-profile notary >/dev/null 2>&1 || fail "notarytool profile 'notary' missing"
VERSION=$(xcodebuild -project GOGDiscArchiver.xcodeproj -scheme GOGDiscArchiver -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
BUILD=$(xcodebuild -project GOGDiscArchiver.xcodeproj -scheme GOGDiscArchiver -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}')
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION"
TAG="v$VERSION"
ZIP="dist/GOG-Disc-Archiver-$VERSION.zip"
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

step "Notarize (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile notary --wait --output-format json > "$OUT/notary.json" || true
ID=$(sed -n 's/.*"id"[^"]*"\([^"]*\)".*/\1/p' "$OUT/notary.json" | head -1)
if ! grep -q '"status"[^"]*"Accepted"' "$OUT/notary.json"; then
  cat "$OUT/notary.json"; echo
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile notary
  fail "notarization not accepted"
fi
echo "accepted ($ID)"

step "Staple and zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP" 2>&1 | tee "$OUT/spctl.txt"
grep -q "Notarized Developer ID" "$OUT/spctl.txt" || fail "Gatekeeper does not accept the app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP ($(du -h "$ZIP" | cut -f1))"

if (( PUBLISH )); then
  step "Draft GitHub release $TAG"
  gh release create "$TAG" "$ZIP" --draft --target "$(git rev-parse HEAD)" \
    --title "$APP_NAME $VERSION" \
    --notes "Download **GOG-Disc-Archiver-$VERSION.zip**, unzip it and move **$APP_NAME** to your Applications folder. Requires macOS 14 or later."
  echo "Draft created: add release notes and press Publish on GitHub."
else
  echo
  echo "Not published. Run with --publish to create a draft GitHub release."
fi
