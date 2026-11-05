#!/bin/zsh
# Measures NowPlaying CPU for a fixed synthetic replay (stable numbers; a live tab is too noisy).
# usage: scripts/perf/cpu.sh [mode=fast|lyrics|nocues] [layout] [style] [seconds=40]
# Installs build/NowPlaying.app to ~/Applications first. Keep the pointer off the overlay while it runs.
set -e
ROOT="${0:A:h:h:h}"; MODE=${1:-fast}; LAYOUT=${2:-lyrics}; STYLE=${3:-glass}; SECS=${4:-40}
D=com.nowplaying.app
OLD_L=$(defaults read $D layout 2>/dev/null || echo coverLine); OLD_S=$(defaults read $D style 2>/dev/null || echo glass)
pkill -x NowPlaying || true; sleep 0.5
rm -rf ~/Applications/NowPlaying.app && cp -R "$ROOT/build/NowPlaying.app" ~/Applications/
defaults write $D layout $LAYOUT; defaults write $D style $STYLE
open -g ~/Applications/NowPlaying.app; sleep 3
P=$(pgrep -x NowPlaying)
secs() { /bin/ps -o time= -p $P | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
python3 "$ROOT/scripts/perf/feed.py" $MODE $((SECS + 12)) >/dev/null 2>&1 &
sleep 10; a=$(secs); sleep $SECS; b=$(secs); wait
FP=$(footprint $P 2>/dev/null | sed -n 2p | sed 's/.*Footprint: //;s/ (.*//')
echo "$MODE $LAYOUT/$STYLE: cpu=$(echo "scale=2; ($b-$a)*100/$SECS" | bc)% footprint=$FP"
pkill -x NowPlaying; sleep 0.5; defaults write $D layout $OLD_L; defaults write $D style $OLD_S; open -g ~/Applications/NowPlaying.app
