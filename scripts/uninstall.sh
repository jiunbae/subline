#!/usr/bin/env bash
# Removes Now Playing and everything it wrote outside the app bundle.
# usage: scripts/uninstall.sh [--dry-run] [--yes] [--keep-app]
#   --dry-run   only list what would be removed
# Remove the browser extension yourself on the browser's Extensions page.
set -euo pipefail
YES=0; KEEP_APP=0; DRY=0
for a in "$@"; do
  case "$a" in --yes) YES=1;; --keep-app) KEEP_APP=1;; --dry-run) DRY=1;; *) echo "unknown option $a" >&2; exit 2;; esac
done
AS="$HOME/Library/Application Support"
targets=()
apps=()
for app in "$HOME/Applications/NowPlaying.app" "/Applications/NowPlaying.app"; do
  if [[ -d "$app" ]]; then apps+=("$app"); fi
done
# The Chrome Web Store ID (if this build had one) names the external-install request file.
STORE_ID=""
for app in "${apps[@]:-}"; do
  if [[ -n "$app" && -z "$STORE_ID" ]]; then
    STORE_ID="$(/usr/libexec/PlistBuddy -c 'Print :NPStoreExtensionID' "$app/Contents/Info.plist" 2>/dev/null || true)"
  fi
done
if [[ $KEEP_APP -eq 0 ]]; then
  for app in "${apps[@]:-}"; do if [[ -n "$app" ]]; then targets+=("$app"); fi; done
fi
for b in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Dev" "Google/Chrome Canary" "Chromium" \
         "BraveSoftware/Brave-Browser" "Microsoft Edge" "Vivaldi" "Arc/User Data"; do
  host="$AS/$b/NativeMessagingHosts/com.nowplaying.host.json"
  if [[ -f "$host" ]]; then targets+=("$host"); fi
  if [[ -n "$STORE_ID" && -f "$AS/$b/External Extensions/$STORE_ID.json" ]]; then
    targets+=("$AS/$b/External Extensions/$STORE_ID.json")
  fi
done
# App data: socket, lock, recently played thumbnails, unpacked extension copy, debug dump.
if [[ -d "$AS/NowPlaying" ]]; then targets+=("$AS/NowPlaying"); fi
if [[ ${#targets[@]} -eq 0 ]]; then echo "Nothing to remove."; exit 0; fi
printf 'Will remove:\n'; printf '  %s\n' "${targets[@]}"; echo "  preferences: com.nowplaying.app (defaults)"
if [[ $DRY -eq 1 ]]; then echo "(dry run: nothing removed)"; exit 0; fi
if [[ $YES -eq 0 ]]; then
  read -r -p "Proceed? [y/N] " ans
  if [[ "$ans" != [yY]* ]]; then echo "Cancelled."; exit 1; fi
fi
pkill -x NowPlaying 2>/dev/null || true
for t in "${targets[@]}"; do rm -rf "$t"; done
defaults delete com.nowplaying.app 2>/dev/null || true
echo "Removed. Now remove the extension on the browser's Extensions page."
