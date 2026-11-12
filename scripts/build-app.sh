#!/bin/bash
# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds Verbalog.app.
#
#   scripts/build-app.sh [debug|release]   build/Verbalog.app, for this Mac: the app runs the
#                                          backend from this folder.
#   scripts/build-app.sh --distribution    build/dist/Verbalog.app, for others: the app carries
#                                          the backend code and uv,
#                                          installs Python and packages on first launch, and is
#                                          signed with Developer ID and the hardened runtime.
#
# macOS ties microphone and screen-recording permissions to the signature: with an ad-hoc one
# they must be granted again after every rebuild, so a real signing identity is used when the
# keychain has one. SIGN_IDENTITY overrides the choice.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DISTRIBUTION=0
if [ "${1:-}" = "--distribution" ]; then
    DISTRIBUTION=1
    CONFIG=release
    APP="$ROOT/build/dist/Verbalog.app"
else
    CONFIG="${1:-release}"
    APP="$ROOT/build/Verbalog.app"
fi

# The uv shipped in releases. Update both together, from the release's .sha256 file.
UV_VERSION=0.13.7
UV_SHA256=81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731

swift build -c "$CONFIG" --package-path "$ROOT/app"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT/app" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R "$ROOT/app/Resources/"*.lproj "$APP/Contents/Resources/"
cp "$BIN_DIR/Verbalog" "$APP/Contents/MacOS/Verbalog"
cp "$BIN_DIR/verbalog-capture" "$APP/Contents/MacOS/verbalog-capture"

ICONSET="$(mktemp -d)/Verbalog.iconset"
swift "$ROOT/scripts/make-iconset.swift" "$ROOT/verbalog-icon.png" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Verbalog.icns"
rm -rf "$(dirname "$ICONSET")"

cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
ENTITLEMENTS="$ROOT/app/Verbalog.entitlements"
if [ -n "${VERSION:-}" ]; then
    # Sparkle and macOS compare CFBundleVersion: the commit count only ever grows.
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C "$ROOT" rev-list --count HEAD)" "$APP/Contents/Info.plist"
fi

if [ "$DISTRIBUTION" = 1 ]; then
    /usr/libexec/PlistBuddy -c "Delete :VerbalogRepoRoot" "$APP/Contents/Info.plist"

    # The backend's own code, run in place by the installed Python (see BackendLayout.bundled).
    BACKEND="$APP/Contents/Resources/backend"
    mkdir -p "$BACKEND"
    cp "$ROOT/pyproject.toml" "$ROOT/uv.lock" "$BACKEND/"
    rsync -a --exclude __pycache__ --exclude '*.pyc' "$ROOT/verbalog" "$BACKEND/"

    # GPL-3.0 for Verbalog itself, and the notice of the uv binary shipped alongside.
    mkdir -p "$APP/Contents/Resources/Licenses"
    cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/Verbalog-LICENSE.txt"
    cp "$ROOT/app/Resources/Licenses/"*.txt "$APP/Contents/Resources/Licenses/"

    CACHE="$ROOT/build/cache"
    ARCHIVE="$CACHE/uv-$UV_VERSION-aarch64-apple-darwin.tar.gz"
    mkdir -p "$CACHE"
    if [ ! -f "$ARCHIVE" ]; then
        curl -fsSL -o "$ARCHIVE.part" "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz"
        mv "$ARCHIVE.part" "$ARCHIVE"
    fi
    echo "$UV_SHA256  $ARCHIVE" | shasum -a 256 -c --quiet
    mkdir -p "$APP/Contents/Helpers"
    tar -xzf "$ARCHIVE" -C "$APP/Contents/Helpers" --strip-components 1 uv-aarch64-apple-darwin/uv

    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
    if [ -z "$IDENTITY" ]; then
        echo "No Developer ID Application certificate in the keychain (or set SIGN_IDENTITY)." >&2
        exit 1
    fi
    SIGN_FLAGS=(--options runtime --timestamp)
else
    /usr/libexec/PlistBuddy -c "Set :VerbalogRepoRoot $ROOT" "$APP/Contents/Info.plist"
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
    SIGN_FLAGS=()
fi

# codesign refuses files carrying extended attributes, and iCloud sync adds them to anything
# under ~/Documents at any moment. So sign outside the synced tree, then move the result in.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto --noextattr --norsrc "$APP" "$STAGING/Verbalog.app"
STAGED="$STAGING/Verbalog.app"
sign() {  # path, identifier, then any extra codesign options
    local path="$1" identifier="$2"
    shift 2
    codesign --force --sign "${IDENTITY:--}" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} --identifier "$identifier" "$@" "$path"
}
# Inside out: nested code first, the app last.
if [ "$DISTRIBUTION" = 1 ]; then
    sign "$STAGED/Contents/Helpers/uv" app.verbalog.uv
fi
sign "$STAGED/Contents/MacOS/verbalog-capture" app.verbalog.Verbalog --entitlements "$ENTITLEMENTS"
sign "$STAGED" app.verbalog.Verbalog --entitlements "$ENTITLEMENTS"
codesign --verify --strict --deep "$STAGED"
rm -rf "$APP"
ditto "$STAGED" "$APP"
echo "Built $APP (signature: ${IDENTITY:-ad hoc}${SIGN_FLAGS[*]:+, hardened runtime})"
