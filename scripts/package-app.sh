#!/usr/bin/env bash
# Builds the universal app and zips it for distribution: build/Subline-<version>.zip
# (ditto keeps the bundle's signature and extended attributes).
#
# Ad-hoc signed by default (runs only on this Mac). For other people's Macs:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<issuer uuid> \
#   scripts/package-app.sh
# or NOTARY_PROFILE=<name> for credentials saved with `xcrun notarytool store-credentials`.
# With a Developer ID and notary credentials the app is notarized, stapled and zipped again as
# build/Subline-<version>.zip; anything else is written as Subline-<version>-local.zip.
# RELEASE=1 fails unless the result will be signed and notarized.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Subline.app"
NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}" --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER is required}")
fi
SIGNED=0; [[ "${CODESIGN_IDENTITY:--}" != "-" ]] && SIGNED=1
RELEASE_READY=0; [[ $SIGNED -eq 1 && ${#NOTARY_ARGS[@]} -gt 0 ]] && RELEASE_READY=1
# RELEASE=1: refuse to produce anything that isn't Developer ID signed and notarized.
if [[ "${RELEASE:-0}" == 1 && $RELEASE_READY -eq 0 ]]; then
  echo "RELEASE=1 needs CODESIGN_IDENTITY (Developer ID) and notary credentials" >&2; exit 1
fi
"$ROOT/scripts/build-app.sh"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
zip_app() { rm -f "$1"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$1"; }

if [[ $RELEASE_READY -eq 1 ]]; then
  # The distribution-named zip appears only after notarization, stapling and the Gatekeeper check
  # succeed; the upload goes through a temporary archive that is always removed.
  OUT="$ROOT/build/Subline-$VERSION.zip"
  rm -f "$OUT"
  SUBMIT="$(mktemp -d)/Subline-submit.zip"; trap 'rm -rf "$(dirname "$SUBMIT")"' EXIT
  zip_app "$SUBMIT"
  echo "notarizing (usually a few minutes)…"
  xcrun notarytool submit "$SUBMIT" "${NOTARY_ARGS[@]}" --wait --timeout 30m | tee "$ROOT/build/notary.log"
  grep -q 'status: Accepted' "$ROOT/build/notary.log" || { echo "notarization was not accepted; see build/notary.log and 'xcrun notarytool log <id>'" >&2; exit 1; }
  xcrun stapler staple "$APP"
  spctl -a -t exec -vv "$APP"
  zip_app "$OUT"
else
  # Not for distribution: marked local.
  OUT="$ROOT/build/Subline-$VERSION-local.zip"
  zip_app "$OUT"
fi
if [[ $RELEASE_READY -eq 1 ]]; then :
elif [[ $SIGNED -eq 1 ]]; then
  echo "signed but NOT notarized (local use only): set NOTARY_PROFILE or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER" >&2
else
  echo "ad-hoc signed (this Mac only); use RELEASE=1 with a Developer ID for distribution" >&2
fi
echo "wrote $OUT"
