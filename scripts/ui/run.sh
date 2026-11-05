#!/bin/zsh
# Real-input UI checks (moves the actual pointer: needs Accessibility permission for the terminal).
# usage: scripts/ui/run.sh            – resize from all 8 handles, Dock placement, context menu capture
# The overlay is kept visible by a synthetic replay; don't touch the mouse while it runs (~1 min).
set -e
ROOT="${0:A:h:h:h}"; OUT="$ROOT/build/ui-e2e"; mkdir -p "$OUT"
for t in resize-e2e dock-e2e context-menu-e2e; do swiftc -O -o "$OUT/$t" "$ROOT/scripts/ui/$t.swift" 2>&1 | grep -v warning || true; done
pgrep -x NowPlaying >/dev/null || { open -g ~/Applications/NowPlaying.app; sleep 3; }
P=$(pgrep -x NowPlaying)
python3 "$ROOT/scripts/perf/feed.py" gap 90 >/dev/null 2>&1 & FEED=$!
sleep 3
echo "== resize"; "$OUT/resize-e2e" $P 2>&1 | grep -v "linkd\|Connection\]"
echo "== dock";   "$OUT/dock-e2e" $P 2>&1 | grep -v "linkd\|Connection\]"
echo "== context menu"; "$OUT/context-menu-e2e" $P "$OUT/context-menu.png" 2>&1 | grep -v "linkd\|Connection\]"; echo "   screenshot: $OUT/context-menu.png"
kill $FEED 2>/dev/null || true
