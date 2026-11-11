#!/bin/bash
# Builds, notarizes and packages a release: build/dist/Verbalog-<version>.dmg.
#
#   scripts/release.sh 0.2.0
#
# Needs a "Developer ID Application" certificate in the keychain, and notarization credentials:
#   - locally, a keychain profile saved once with
#       xcrun notarytool store-credentials verbalog-notary --key <AuthKey.p8> --key-id <id> --issuer <uuid>
#   - in CI, NOTARY_KEY (path to the .p8), NOTARY_KEY_ID and NOTARY_ISSUER.
# SKIP_NOTARIZE=1 builds and packages without notarizing, to test the steps before.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/release.sh <version>, e.g. 0.2.0}"
export VERSION

if [ -n "$(git -C "$ROOT" status --porcelain)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
    echo "The working tree has uncommitted changes: a release must match a commit (ALLOW_DIRTY=1 to override)." >&2
    exit 1
fi

"$ROOT/scripts/build-app.sh" --distribution
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"

notarize() {
    if [ -n "${SKIP_NOTARIZE:-}" ]; then
        echo "Not notarizing $1 (SKIP_NOTARIZE)."
        return
    fi
    if [ -n "${NOTARY_KEY:-}" ]; then
        xcrun notarytool submit "$1" --wait --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
    else
        xcrun notarytool submit "$1" --wait --keychain-profile verbalog-notary
    fi
}

# Everything happens outside ~/Documents: iCloud adds extended attributes that break signatures.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto --noextattr --norsrc "$ROOT/build/dist/Verbalog.app" "$WORK/Verbalog.app"
codesign --verify --strict --deep "$WORK/Verbalog.app"

# The app is notarized and stapled on its own first, so it passes Gatekeeper offline once
# copied out of the disk image. Then the disk image, which is what people download.
ditto -c -k --keepParent "$WORK/Verbalog.app" "$WORK/Verbalog.zip"
notarize "$WORK/Verbalog.zip"
[ -n "${SKIP_NOTARIZE:-}" ] || xcrun stapler staple "$WORK/Verbalog.app"

mkdir "$WORK/image"
ditto "$WORK/Verbalog.app" "$WORK/image/Verbalog.app"
ln -s /Applications "$WORK/image/Applications"
DMG="$WORK/Verbalog-$VERSION.dmg"
hdiutil create -quiet -volname "Verbalog $VERSION" -srcfolder "$WORK/image" -fs APFS -format ULFO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

mkdir -p "$ROOT/build/dist"
cp "$DMG" "$ROOT/build/dist/"
( cd "$ROOT/build/dist" && shasum -a 256 "Verbalog-$VERSION.dmg" > "Verbalog-$VERSION.dmg.sha256" )
echo "Released build/dist/Verbalog-$VERSION.dmg"
