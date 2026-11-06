#!/usr/bin/env bash
# Builds Subline.app (release) into build/ and optionally installs to ~/Applications.
# Usage: scripts/build-app.sh [--install]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Subline.app"
cd "$ROOT/app"
# Universal (Apple Silicon + Intel) by default; ARCHS="arm64" for a faster local build.
ARCH_FLAGS=(); for a in ${ARCHS:-arm64 x86_64}; do ARCH_FLAGS+=(--arch "$a"); done
# APPSTORE=1 compiles out private-API use (see BackgroundCursor.swift).
SWIFT_FLAGS=(); if [[ "${APPSTORE:-0}" == 1 ]]; then SWIFT_FLAGS+=(-Xswiftc -DAPPSTORE); fi
swift build -c release "${ARCH_FLAGS[@]}" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"

# Version: VERSION file (marketing) and the commit count (build number), unless overridden.
APP_VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Subline" "$APP/Contents/MacOS/Subline"
cp "$BIN/subline-host" "$APP/Contents/Helpers/subline-host"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT"/app/Resources/*.lproj "$APP/Contents/Resources/"
# Bundled extension for the setup window's "Load unpacked" path (tests/docs excluded).
rsync -a --delete --exclude test --exclude README.md --exclude '.*' "$ROOT/extension/" "$APP/Contents/Resources/extension/"
# Chrome Web Store ID (after publishing): env STORE_EXTENSION_ID or keys/store-extension-id.txt.
STORE_ID="${STORE_EXTENSION_ID:-$(cat "$ROOT/keys/store-extension-id.txt" 2>/dev/null || true)}"
STORE_ID="$(echo "$STORE_ID" | tr -d '[:space:]')"
if [[ -n "$STORE_ID" && ! "$STORE_ID" =~ ^[a-p]{32}$ ]]; then echo "invalid store extension id: $STORE_ID" >&2; exit 1; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.jiun.subline</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>CFBundleName</key><string>Subline</string>
  <key>CFBundleDisplayName</key><string>Subline</string>
  <key>CFBundleExecutable</key><string>Subline</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>SLStoreExtensionID</key><string>${STORE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Subline reads what Spotify or Music is playing (title, position, artwork) to show its lyrics, and sends play/pause/next/previous when you use the overlay controls.</string>
</dict></plist>
PLIST
# Ad-hoc sign by default. For distribution set CODESIGN_IDENTITY to a Developer ID identity
# (scripts/package-app.sh then notarizes); notarization needs a secure timestamp.
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/subline-host"
codesign "${SIGN_FLAGS[@]}" --entitlements "$ROOT/app/Subline.entitlements" "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/Subline.app"
  mkdir -p "$HOME/Applications"
  pkill -x Subline 2>/dev/null || true
  # Previous name: the app migrates its data on first launch.
  pkill -x NowPlaying 2>/dev/null || true; rm -rf "$HOME/Applications/NowPlaying.app"
  rm -rf "$DEST" && cp -R "$APP" "$DEST"
  echo "installed $DEST"
  open "$DEST"
fi
