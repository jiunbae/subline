# Wire protocol v1

Chrome extension (service worker) ⇄ `np-host` (Native Messaging host) ⇄ `NowPlaying.app` (Unix domain socket).

## Transport
- Extension ↔ host: Chrome Native Messaging. Each frame is a 4-byte **little-endian** uint32 length followed by UTF-8 JSON.
- Host ↔ app: the **same framing** over the Unix socket `~/Library/Application Support/NowPlaying/np.sock`. The host is a dumb byte relay. It reframes and validates the length but does not parse the JSON.
- Size limits enforced by the app: 4 MiB per frame in, 64 KiB per frame out.
- NM host name: `com.nowplaying.host`. Extension ID (fixed via `key` in manifest): `npkfiaebcfackgbinodgjobdlmeceaij`.
- If the app is not running, the host launches it (`open -g -b com.nowplaying.app`) and retries the connection with backoff for up to about 5 s. If that fails, it exits with code 1 and the extension retries `connectNative` with backoff (1 s, 2 s, 4 s … max 30 s).

## Common fields
Every message is a JSON object with `"v": 1` and `"type"`. Messages from the extension also carry `tabId` (number) and `seq` (monotonic per extension session). The app drops any message whose `seq` is ≤ the last `seq` seen for that tab.

## Extension → App
| type | fields | when |
|---|---|---|
| `hello` | `ext` (version string), `ua` | on every (re)connect, followed by a full `track`+`clock`+`cues` snapshot of each active tab |
| `track` | `site` (`"yt"`\|`"ytm"`), `videoId`, `title`, `artist`, `album`?, `duration` (s, number), `artwork`: `[{url,w,h}]` sorted best-first, `isAd` (bool) | on video change, metadata change, ad start/end |
| `clock` | `videoId`, `t` (currentTime, s), `rate`, `paused` (bool), `buffering` (bool) | immediately on play/pause/seeking/seeked/ratechange/waiting/playing, and every 5 s while playing (drift correction; the app extrapolates) |
| `cues` | `videoId`, `source` (`"yt-captions"`\|`"ytm-lyrics"`\|`"lrclib"`\|`"dom"`), `lang`?, `kind` (`"manual"`\|`"asr"`\|`"lyrics"`), `synced` (bool), `cues`: `[{s, e?, text}]` (seconds, sorted by `s`; `e` optional, `text` may contain `\n`) | when a track is obtained; an empty `cues` array means "none available". `ytm-lyrics` may be unsynced (`synced:false`, `s` = line index). `slot: 2` marks the secondary caption track (empty `cues` = secondary off) |
| `captionTracks` | `videoId`, `tracks`: `[{id, lang, name, kind?}]` (`id` = `lang` or `lang:asr`; `kind:"asr"` for auto-generated; deduplicated by `id`) | YouTube only, when the player's track list is known or changes, and in snapshots; an empty list means the video has no captions |
| `liveCaption` | `videoId`, `text` (string, `""` = clear) | DOM-observer fallback only, on change |
| `gone` | — | tab closed / navigated away from a watch page |

When several tabs are active, the app follows the tab that most recently went from paused to playing (periodic 1 s ticks never steal focus). If no tab is playing, it follows the most recently active tab. The user can pin a tab from the menu. `clock`, `cues` and `liveCaption` whose `videoId` differs from the tab's current `track` are dropped, and a new `track.videoId` clears the previous clock, cues and caption.

## App → Extension
| type | fields |
|---|---|
| `cmd` | `tabId`, `action`: `"play"`\|`"pause"`\|`"toggle"`\|`"next"`\|`"prev"`\|`"seek"`, `t`? (s, for seek) |
| `visibility` | `visible` (bool). When false the extension may drop periodic `clock` ticks; event-driven ones are still sent |
| `requestSnapshot` | — the extension resends `track`+`clock`+`cues` for all tabs |
| `connectCaptions` | `tabId`. The user asked to obtain captions: toggle CC once, capture the timedtext response, restore the original CC state |
| `selectCaptions` | `tabId`, `trackId` (a `captionTracks` id), `slot` (1 main, 2 secondary; `trackId:""` with slot 2 turns the secondary off). Make the player load that track (`setOption('captions','track',{languageCode,kind})`), capture it, then restore the player's own track and CC state. From then on the tab ignores captured captions of other tracks for this video |

## Example
```json
{"v":1,"type":"clock","tabId":412,"seq":88,"videoId":"dQw4w9WgXcQ","t":42.37,"rate":1,"paused":false,"buffering":false}
```
