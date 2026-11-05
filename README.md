# Now Playing — YouTube / YouTube Music overlay for macOS

Shows the artwork, title, and time-synced captions or lyrics of whatever is playing in Chrome as a floating PiP-style panel.
Playback stays in Chrome. The app only receives metadata, the clock, and captions, so nothing is decoded twice.

```
Chrome extension (MV3) ──Native Messaging──▶ np-host ──Unix socket──▶ NowPlaying.app (menu bar)
```

- Plan: [PLAN.md](PLAN.md) · Wire protocol: [PROTOCOL.md](PROTOCOL.md) · Extension details: [extension/README.md](extension/README.md)

## Install (development)

```bash
scripts/build-app.sh --install     # universal build (Apple Silicon + Intel), copies to ~/Applications, launches it
ARCHS=arm64 scripts/build-app.sh   # faster single-architecture build for local work
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
| VoiceOver | The overlay is announced as "title, artist" with the current line as its value, and offers Play/Pause, Next, Previous and Skip ±10 s as actions (the hover controls aren't needed). Lyric lines are buttons; the progress line is adjustable. Menu bar → Skip Back/Forward 10 Seconds |
| Nothing playing | Shown only when you open the overlay yourself (⌃⌥⌘O): the last video with ▶ resume (plays in its tab if still open, otherwise opens it in the default browser) and up to 3 more recent ones. Menu bar → Recently Played lists them and can clear the list (kept on this Mac only) |
| Paused | The overlay dims and desaturates, with a ❚❚ mark by the title (a pause glyph on Cover); it fades out after 5 min |
| No text | Cover + Line shows the title larger instead of an empty slot, with a status chip: Loading captions… / Load captions / Show lyrics (unsynced) |
| Lyrics on YouTube Music | Synced lyrics from LRCLIB (retried with localized/`(Official Audio)` suffixes removed, then one LRCLIB search matched by title, artist and length ±3 s, skipping instrumentals). Songs LRCLIB doesn't have show the title only |

## Install, update, uninstall (for users)

- **Install:** unzip `NowPlaying-<version>.zip` (made by `scripts/package-app.sh`) and move `NowPlaying.app` to
  `/Applications` or `~/Applications`, open it once, then add the extension (setup window). Universal app (Apple Silicon
  and Intel), macOS 14 or later; tested on Apple Silicon.
- **Update:** quit from the menu bar, replace the app, open it again. Opening the app re-registers it with every
  browser, so moving or replacing it is safe; if a browser can't reach it, open the app (or Setup → Troubleshooting → Retry).
  An unpacked extension must be reloaded on the browser's Extensions page; the menu shows when it's outdated.
- **Uninstall:** `scripts/uninstall.sh --dry-run` lists everything; `scripts/uninstall.sh` removes the app, the browser
  registrations, Chrome install requests, `~/Library/Application Support/NowPlaying` (recently played, thumbnails,
  extension copy, debug dump) and the preferences. Then remove the extension in the browser.
- **Versions:** `VERSION` (marketing version) and the git commit count (build number) are stamped by `scripts/build-app.sh`.
- **Signing:** builds are ad-hoc signed. For other people's Macs, set `CODESIGN_IDENTITY` to a Developer ID and notarize the zip.

## Language

The app follows the system language (English and Korean). To use Korean in the app only:
`defaults write com.nowplaying.app AppleLanguages -array ko` (undo: `defaults delete com.nowplaying.app AppleLanguages`), then reopen it.

## Verification tools

| Script | What it checks |
|---|---|
| `scripts/perf/cpu.sh [fast\|lyrics\|nocues] [layout] [style]` | CPU and memory for a fixed synthetic replay (stable, unlike a live tab) |
| `scripts/perf/feed.py MODE SECONDS` | Feeds synthetic states to the app: `lyrics`, `fast`, `none`, `loading`, `gap`, `dual`, `paused` |
| `scripts/ui/run.sh` | Real pointer input: resize from all 8 handles (cursor + which edges move), Dock placement, context menu |
| `node scripts/e2e/youtube.mjs <url> [secs] [--cc-off] [--expect cur=es --expect 'n2>0' …] [--expect-cc same] [--debug]` | Real YouTube in Chromium with the unpacked extension; prints the app's state and exits 1 if an expectation fails (needs `debugDump`). `--debug` shows the bridge's log |
| `localStorage['nowplaying-debug']='1'` (in a YouTube tab's console) | Bridge diagnostics in that tab's console: caption selections, each player attempt, captured / refused (e.g. 429) caption requests. Nothing leaves the page |

`scripts/ui` and `scripts/e2e` move the real pointer / open a browser; they close what they open.

## Tests

```bash
cd app && swift test                         # Core: framing, messages, clock interpolation, cue timeline, tab selection
node --test extension/test/*.test.mjs        # Extension: JSON3/ASR/LRC parsers, service worker and bridge (MAIN world) in a VM
```

Measured on Apple Silicon, release build, with simulated input:

| | Result | Target |
|---|---|---|
| App / host memory footprint (`footprint`, not RSS) | 25–29 MB / 2.4 MB | ≤ 80 MB |
| CPU, idle / playing with no text | ~0.03% / ~0.03–0.1% | ≤ 0.2% |
| CPU, lyric pace (a line every 3 s): Lyrics / Cover + Line | ~1.1% / ~1.0% | ≤ 1% (at target) |
| CPU, fast auto-generated captions (1500 lines, every 1.3 s): Lyrics / Cover + Line | ~1.0% / ~1.1% (was 13% / 4.1%) | ≤ 1% |
| YouTube tab main thread, with vs without the extension (40 s playing) | 2.5–2.8% vs 2.5–3.3% (no measurable difference) | |
| App ↔ extension messages while playing | 1 clock per 5 s (+ events); a fixed feedback loop had reached ~1,500/s | |

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
