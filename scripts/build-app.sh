#!/usr/bin/env bash
# Builds NowPlaying.app (release) into build/ and optionally installs to ~/Applications.
# Usage: scripts/build-app.sh [--install]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/NowPlaying.app"
cd "$ROOT/app"
# Universal (Apple Silicon + Intel) by default; ARCHS="arm64" for a faster local build.
ARCH_FLAGS=(); for a in ${ARCHS:-arm64 x86_64}; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/NowPlaying" "$APP/Contents/MacOS/NowPlaying"
cp "$BIN/np-host" "$APP/Contents/Helpers/np-host"
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
  <key>CFBundleIdentifier</key><string>com.nowplaying.app</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>CFBundleName</key><string>Now Playing</string>
  <key>CFBundleDisplayName</key><string>Now Playing</string>
  <key>CFBundleExecutable</key><string>NowPlaying</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NPStoreExtensionID</key><string>${STORE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
# Ad-hoc sign (use a Developer ID identity + notarization for distribution).
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Helpers/np-host"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/NowPlaying.app"
  mkdir -p "$HOME/Applications"
  pkill -x NowPlaying 2>/dev/null || true
  rm -rf "$DEST" && cp -R "$APP" "$DEST"
  echo "installed $DEST"
  open "$DEST"
fi
