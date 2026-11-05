#!/usr/bin/env bash
# Builds the universal app and zips it for distribution: build/NowPlaying-<version>.zip
# (ditto keeps the bundle's signature and extended attributes). For other people's Macs, sign with a
# Developer ID first (CODESIGN_IDENTITY="Developer ID Application: …") and notarize the zip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
OUT="$ROOT/build/NowPlaying-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/NowPlaying.app" "$OUT"
echo "wrote $OUT"
