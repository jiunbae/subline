#!/usr/bin/env bash
# Packages extension/ for Chrome Web Store upload: build/subline-extension-<version>.zip
# The Web Store rejects a manifest "key" (it assigns its own ID), so it is stripped here only;
# the repo keeps it so unpacked development builds keep the fixed dev ID.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/extension/manifest.json")"
STAGE="$ROOT/build/extension-store"
OUT="$ROOT/build/subline-extension-$VERSION.zip"
rm -rf "$STAGE" "$OUT"; mkdir -p "$STAGE"
rsync -a --exclude test --exclude README.md --exclude '.*' "$ROOT/extension/" "$STAGE/"
python3 - "$STAGE/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m.pop("key", None)
open(p, "w").write(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
PY
(cd "$STAGE" && zip -qrX "$OUT" .)
echo "wrote $OUT"; unzip -l "$OUT" | tail -n +4 | sed '$d' | awk '{print "  " $4}' | sed '/^  $/d'
