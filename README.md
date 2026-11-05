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
2. On first run a **setup window** walks through installing the extension. Without a Web Store ID it offers
   **Load Unpacked Extension…**, which copies the bundled extension to
   `~/Library/Application Support/NowPlaying/extension`, reveals it in Finder and opens `chrome://extensions`.
   Turn on Developer mode, then **Load unpacked** that folder. The dev ID is fixed as `npkfiaebcfackgbinodgjobdlmeceaij`.
3. Reload any open YouTube tabs. A ♪ icon appears in the menu bar; the overlay appears when playback starts.

Unpacked extensions keep running old code until reloaded. When the connected extension is older than the
one bundled with the app, the menu bar menu says so (reload it on the browser's Extensions page).

Open the app again (Finder/Spotlight) while it runs to bring the setup window back as a status page.
Publishing to the Chrome Web Store (unlisted) and the one-click install path: [store/SUBMISSION.md](store/SUBMISSION.md).

If the app isn't running, the extension's connection attempt launches it automatically.
After you quit from the menu, it won't be relaunched automatically until you open it yourself again.

## Usage

| Action | How |
|---|---|
| Move | Drag the panel. It snaps to screen edges and corners |
| Resize | Drag any edge or corner (the cursor changes, also while another app is frontmost). Dragged edges stop at the screen edge; the opposite edges never move |
| Placement | Anywhere below the menu bar, including over the Dock. Snaps to the screen edge or to just above the Dock |
| Options | Right-click the overlay (same menu as the menu bar), or **Appearance…** (⌘,) for the gallery |
| Style | **Glass** (transparent; text on Liquid Glass on macOS 26+, HUD material before), **Tinted**, **Clear** |
| Show/hide automatically | On by default: appears when playback starts, fades 2.5 s after the tab goes away or after 5 min paused. A manual hide lasts for the current video |
| Play/pause | Double-click the panel · hover controls · ⌃⌥⌘Space |
| Show/hide overlay | ⌃⌥⌘O |
| Click-through (mouse passes through) | ⌃⌥⌘L or the menu bar → Click-Through |
| Layouts | Menu bar → Layout: Cover / Cover + Line / Lyrics / Mini |
| Caption sync | Menu bar → Captions → Earlier/Later (±0.5s) |
| Captions on YouTube | Captured from the player's own caption request. If CC is off, the app briefly toggles CC and restores it (Captions → **Auto-Connect Captions**, on by default; **Connect Captions** does it manually) |
| Caption language | Captions → Language, or the CC pill in the hover controls. The choice is remembered and applied to later videos that offer that language (manual tracks before auto-generated). The player's own CC state and language are restored |
| Auto-translate | Language / Second Language → Auto-translate ▸ (your system languages first): the player translates its caption track, e.g. English original + Korean translation |
| Auto-generated captions | Rebuilt into sentences from YouTube's per-word timing (breaks at punctuation, pauses, or ~26 CJK / 48 Latin chars) instead of its rolling windows |
| Second language | Captions → Second Language (or the CC pill): a sub track shown under the main line, and under each row in the Lyrics layout. Remembered like the main language; it replaces the next-line preview |
| Next line | The following line is shown dimmed under the current one; ♪ during instrumental gaps (Captions → Show Next Line) |
| Nothing playing | Shown only when you open the overlay yourself (⌃⌥⌘O): the last video with ▶ resume (plays in its tab if still open, otherwise opens it in the default browser) and up to 3 more recent ones. Menu bar → Recently Played lists them and can clear the list (kept on this Mac only) |
| Paused | The overlay dims and desaturates, with a ❚❚ mark by the title (a pause glyph on Cover); it fades out after 5 min |
| No text | Cover + Line shows the title larger instead of an empty slot, with a status chip: Loading captions… / Load captions / Show lyrics (unsynced) |
| Lyrics on YouTube Music | Synced lyrics from LRCLIB (retried with localized/`(Official Audio)` suffixes removed). Otherwise YTM's own lyrics, unsynced (Lyrics layout only) |

## Verification tools

| Script | What it checks |
|---|---|
| `scripts/perf/cpu.sh [fast\|lyrics\|nocues] [layout] [style]` | CPU and memory for a fixed synthetic replay (stable, unlike a live tab) |
| `scripts/perf/feed.py MODE SECONDS` | Feeds synthetic states to the app: `lyrics`, `fast`, `none`, `loading`, `gap`, `dual`, `paused` |
| `scripts/ui/run.sh` | Real pointer input: resize from all 8 handles (cursor + which edges move), Dock placement, context menu |
| `node scripts/e2e/youtube.mjs <url> [secs] [--cc-off]` | Real YouTube in Chromium with the unpacked extension; prints the app's state (needs `debugDump`) |

`scripts/ui` and `scripts/e2e` move the real pointer / open a browser; they close what they open.

## Tests

```bash
cd app && swift test                         # Core: framing, messages, clock interpolation, cue timeline, tab selection
node --test extension/test/*.test.mjs        # Extension: JSON3/LRC/timedLyrics parsers, service worker mocks
```

Measured on Apple Silicon, release build, with simulated input:

| | Result | Target |
|---|---|---|
| App / host memory footprint (`footprint`, not RSS) | 29 MB / 2.4 MB (after 70 s of soak; stable) | ≤ 80 MB |
| CPU, idle / playing with no text | ~0% / ~0.03% | ≤ 0.2% |
| CPU, lyric pace (a line every 3 s): Lyrics / Cover + Line | ~1.2% / ~1.2% | ≤ 1% (about at target) |
| CPU, fast auto-generated captions (1500 lines, every 1.3 s): Lyrics / Cover + Line | ~0.7% / ~1.0% (was 13% / 4.1%) | ≤ 1% |

Almost all playing cost is animation frames, which SwiftUI renders text for on the CPU. Rules that came out of
the measurements: no implicit animation on every lyric row (it was ~90% of the Lyrics cost); when lines change
faster than every 2 s (or Reduce Motion is on) skip transitions and jump-scroll; no per-line blur/scale, text
shadows or spring tails; the next-line preview swaps text without its own fade. A Rust core was considered
and rejected: non-rendering app work is ~0.03% CPU, and a Rust relay would save at most ~1–3 MB.
Measure with `soak` replays of fixed content, not a live tab (live numbers swing with playback and pointer activity).

## Debugging

```bash
defaults write com.nowplaying.app debugDump -bool true   # writes state to ~/Library/Application Support/NowPlaying/debug-state.json
```
