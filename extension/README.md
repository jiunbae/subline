# Now Playing Chrome extension

No build step or npm dependencies. Requires Chrome 120+ (30-second reconnect alarm watchdog).

1. Build/install the companion macOS app and register `com.nowplaying.host` using the repository's app setup scripts.
2. Open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select this `extension/` directory.
3. Confirm the extension ID is `npkfiaebcfackgbinodgjobdlmeceaij`. The public key is embedded in `manifest.json`; never distribute the private key.
4. Reload existing YouTube / YouTube Music tabs so the document-start scripts attach. Start playback; the native panel should receive metadata and playback state. Clicking the extension action requests a fresh snapshot.
5. The companion app auto-connects captions when a YouTube video has none (setting **Auto-Connect Captions**, default on), or use its **Connect captions** action to briefly toggle captions and restore their previous state. Captions already requested by the page are observed automatically. Playback controls are routed back to that tab.

Run parser and worker tests from the repository root:

```sh
node --test extension/test/*.test.mjs
```

## Behavior and boundaries

- Native messages follow `../PROTOCOL.md`. The worker reconnects with 1/2/4/…/30-second backoff and sends `hello`, then each tab's track/clock/cues. The additional `alarms` permission provides a wake watchdog when MV3 suspension loses a JS retry timer. Sequence numbers increase per tab across native reconnects; a time-derived epoch handles service worker restarts (a backwards system-clock adjustment is a limitation).
- YT and YTM metadata adapters are separate. Artwork URLs are best-first candidates; generated maxres/YTM 1200px candidates can fail, so the app must try remaining candidates.
- MAIN-world hooks clone same-origin `/api/timedtext` fetch/XHR responses. JSON3 and legacy XML/SRV text are supported; ASR rolling windows are normalized. Request URLs, PoTokens and cookies are neither posted to the extension nor logged/stored.
- YTM tries one same-origin `next` → mobile-client `browse` lookup per track. This is an experimental private API and can fail due to account, authentication, client version or schema changes. No PoToken generation, audio download or stream extraction is performed.
- Lyrics order on YTM: LRCLIB synced lyrics first (retried once with bracketed/localized suffixes and " - Topic" removed), then YTM's own unsynced lyrics via authenticated same-origin `next`/`browse` (SAPISIDHASH computed in-page, never posted). YTM `next`/`browse` responses of the page are not inspected because the page prefetches upcoming queue items. This implementation requests LRCLIB with the displayed track title, artist, album and duration. This sends that metadata to LRCLIB. It validates returned duration within ±3s and uses timestamped LRC only. Covers/live versions can still mismatch. The incoming implementation task explicitly requested this automatic fallback; the planning document's optional source selector is not implemented here.
- If no timed cues exist, `.ytp-caption-segment` changes are sent as `liveCaption`. Ads suppress lyric/caption publishing. Caption caches are memory-only, bounded and expire after five minutes; cache identity includes video, language, kind, source and parser version.
- One-second clock ticks run only while playing and while the native panel reports visible. Playback/seek/buffering events still send clocks while hidden. Narrow player/player-bar/caption observers and SPA events handle updates; no perpetual DOM polling or video frame capture.
- MAIN-world/page messages are untrusted. Isolated code and the worker restrict origins, shapes, sizes, message types and command actions; a page script can still spoof its own metadata. There is no privileged arbitrary-URL fetch or command execution interface.

## Integration checks still required

Real Chrome/native integration is not covered by Node tests. Verify native-host disconnect/restart, hidden-panel clock suppression, SPA next/previous, ad entry/exit, CC restoration, tab close/navigation, YouTube auto captions, YTM artwork/artist selectors, the mobile lyrics route, LRCLIB no-match/429 and buffering recovery. Private selectors/client schemas and CC load latency are assumptions until tested with a signed-in browser session. No claimed CPU/RAM figures have been measured.
