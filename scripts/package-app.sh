#!/usr/bin/env bash
# Builds the universal app and zips it for distribution: build/NowPlaying-<version>.zip
# (ditto keeps the bundle's signature and extended attributes).
#
# Ad-hoc signed by default (runs only on this Mac). For other people's Macs:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<issuer uuid> \
#   scripts/package-app.sh
# or NOTARY_PROFILE=<name> for credentials saved with `xcrun notarytool store-credentials`.
# With a Developer ID and notary credentials the app is notarized, stapled and zipped again.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/NowPlaying.app"
"$ROOT/scripts/build-app.sh"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
OUT="$ROOT/build/NowPlaying-$VERSION.zip"
zip_app() { rm -f "$OUT"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"; }
zip_app

NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}" --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER is required}")
fi
if [[ "${CODESIGN_IDENTITY:--}" != "-" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  echo "notarizing $OUT (usually a few minutes)…"
  xcrun notarytool submit "$OUT" "${NOTARY_ARGS[@]}" --wait --timeout 30m | tee "$ROOT/build/notary.log"
  grep -q 'status: Accepted' "$ROOT/build/notary.log" || { echo "notarization was not accepted; see build/notary.log and 'xcrun notarytool log <id>'" >&2; exit 1; }
  xcrun stapler staple "$APP"
  spctl -a -t exec -vv "$APP"
  zip_app
elif [[ "${CODESIGN_IDENTITY:--}" != "-" ]]; then
  echo "signed but not notarized: set NOTARY_PROFILE or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER" >&2
fi
echo "wrote $OUT"
