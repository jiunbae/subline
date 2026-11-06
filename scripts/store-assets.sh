#!/usr/bin/env bash
# Renders Chrome Web Store images into store/assets/ using the built app (scripts/build-app.sh first).
# Screenshots: 1280x800 PNG. Small promo tile: 440x280 PNG.
# README branding into docs/assets/: banner (1600x560 pt) and social preview at capture resolution, plus the icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/Subline.app/Contents/MacOS/Subline"
OUT="$ROOT/store/assets"; mkdir -p "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/wid.swift" <<'SW'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where (w[kCGWindowOwnerPID as String] as? Int) == pid { print(w[kCGWindowNumber as String]!); break }
SW
shot() { # name width height
  "$BIN" --store-shot "$1" >/dev/null 2>&1 & local pid=$!
  sleep 2.5
  local wid; wid="$(swift "$TMP/wid.swift" "$pid")"
  screencapture -x -o -l"$wid" "$TMP/raw.png"
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  local name="$4" out="${5:-$OUT}"; mkdir -p "$out"; local rel="${out#"$ROOT"/}"
  # README images keep the capture's native (Retina) resolution.
  if [[ "$out" != "$OUT" ]]; then cp "$TMP/raw.png" "$out/$name"; echo "wrote $rel/$name"; return; fi
  sips -s format png -z "$3" "$2" "$TMP/raw.png" --out "$out/$name" >/dev/null
  # Web Store wants no alpha channel in screenshots.
  sips -s format jpeg "$out/$name" --out "$TMP/flat.jpg" >/dev/null && sips -s format png "$TMP/flat.jpg" --out "$out/$name" >/dev/null
  echo "wrote $rel/$name"
}
shot 1 1280 800 screenshot-1-hero.png
shot 2 1280 800 screenshot-2-lyrics.png
shot 3 1280 800 screenshot-3-styles.png
shot promo 440 280 promo-small-440x280.png
DOCS="$ROOT/docs/assets"
shot banner - - banner.png "$DOCS"
shot social - - social.png "$DOCS"
sips -s format png -z 256 256 "$ROOT/app/Resources/AppIcon.icns" --out "$DOCS/icon.png" >/dev/null && echo "wrote docs/assets/icon.png"
