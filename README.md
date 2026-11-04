# Now Playing — YouTube / YouTube Music overlay for macOS

Shows the artwork, title, and time-synced captions or lyrics of whatever is playing in Chrome as a floating PiP-style panel.
Playback stays in Chrome. The app only receives metadata, the clock, and captions, so nothing is decoded twice.

```
Chrome extension (MV3) ──Native Messaging──▶ np-host ──Unix socket──▶ NowPlaying.app (menu bar)
```

- Plan: [PLAN.md](PLAN.md) · Wire protocol: [PROTOCOL.md](PROTOCOL.md) · Extension details: [extension/README.md](extension/README.md)

## Install (development)

```bash
scripts/build-app.sh --install     # builds, copies to ~/Applications/NowPlaying.app, launches it
```

1. On launch the app registers the Native Messaging manifest for every installed Chromium browser
   (`~/Library/Application Support/<Browser>/NativeMessagingHosts/com.nowplaying.host.json`).
2. In Chrome, open `chrome://extensions`, turn on Developer mode, choose **Load unpacked**, and select `extension/`.
   The ID is fixed as `npkfiaebcfackgbinodgjobdlmeceaij`.
3. Reload any open YouTube tabs. A ♪ icon appears in the menu bar and the overlay appears.

If the app isn't running, the extension's connection attempt launches it automatically.
After you quit from the menu, it won't be relaunched automatically until you open it yourself again.

## Usage

| Action | How |
|---|---|
| Move | Drag the panel. It snaps to screen edges and corners |
| Resize | Hover, then drag the ↘ grip in the bottom-right corner |
| Play/pause | Double-click the panel · hover controls · ⌃⌥⌘Space |
| Show/hide overlay | ⌃⌥⌘O |
| Click-through (mouse passes through) | ⌃⌥⌘L or the menu bar → Click-Through |
| Layouts | Menu bar → Layout: Cover / Cover + Line / Lyrics / Mini |
| Caption sync | Menu bar → Captions → Earlier/Later (±0.5s) |
| Captions on YouTube | Captured from the player's own caption request. If CC is off, the app briefly toggles CC and restores it (Captions → **Auto-Connect Captions**, on by default; **Connect Captions** does it manually). The language is whatever the player picks |
| Lyrics on YouTube Music | Synced lyrics from LRCLIB (retried with localized/`(Official Audio)` suffixes removed). Otherwise YTM's own lyrics, unsynced (Lyrics layout only) |

## Tests

```bash
cd app && swift test                         # Core: framing, messages, clock interpolation, cue timeline, tab selection
node --test extension/test/*.test.mjs        # Extension: JSON3/LRC/timedLyrics parsers, service worker mocks
```

Measured on Apple Silicon, release build, with simulated input:

| | Result | Target |
|---|---|---|
| App / host memory footprint (`footprint`, not RSS) | 23 MB / 2.6 MB | ≤ 80 MB |
| CPU, idle | ~0.13% | ≤ 0.2% |
| CPU, playing, no text (1 clock msg/s) | ~0.03% | |
| CPU, playing, line change every 3 s: Cover / Mini / Cover + Line | ~0.9% / ~0.9% / ~1.0% | ≤ 1% |
| CPU, playing, line change every 3 s: Lyrics (200 lines, scrolling) | ~2.6% | ≤ 1% (over; the scroll animation itself) |

Most of the playing cost is the line-change animation. Per-line blur/scale (14% in Lyrics), text shadows and
spring tails were removed for this reason; keep new effects to opacity/offset with short fixed curves.

## Debugging

```bash
defaults write com.nowplaying.app debugDump -bool true   # writes state to ~/Library/Application Support/NowPlaying/debug-state.json
```
