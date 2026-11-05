# Chrome Web Store listing: Now Playing Overlay

Copy these fields into the Developer Dashboard. Each field is given in English (default) and Korean.

## Store listing tab

| Field | Value |
|---|---|
| Name | Now Playing Overlay |
| Category | Entertainment |
| Language | English (add Korean as a second locale if you want to) |
| Store icon | `extension/icons/icon128.png` (128×128) |
| Screenshots | `store/assets/screenshot-1-hero.png`, `screenshot-2-lyrics.png`, `screenshot-3-styles.png` (1280×800) |
| Small promo tile | `store/assets/promo-small-440x280.png` |

**Summary** (132 characters max)

- en: `Show YouTube and YouTube Music artwork with time-synced lyrics and captions in a floating macOS overlay.` (104)
- ko: `YouTube·YouTube Music의 앨범 아트와 시간 맞춤 가사·자막을 macOS 화면 위 작은 창에 띄웁니다.`

**Description (en)**

```
Now Playing Overlay sends what is playing in your YouTube or YouTube Music tab to the free
Now Playing app for macOS, which shows it in a small floating window above your other apps.

• Album art or the video thumbnail, with colors that follow the artwork
• Time-synced lyrics (YouTube Music) and captions (YouTube), with the next line previewed
• Glass, Tinted and Clear styles; cover, cover + line, lyrics and mini layouts
• Drag anywhere, resize from any edge, snap to screen edges, click-through mode
• Play/pause, next and previous from the overlay or global shortcuts
• Lightweight: the extension only relays events; the overlay uses about 1% CPU while playing

Requires the Now Playing app for macOS (macOS 14 or later; universal app for Apple Silicon and Intel).
Without it the extension does nothing and sends nothing. It does not run in incognito windows.

Privacy: no accounts, analytics or tracking. Playback information goes only to the Now Playing
app on your Mac. To find synced lyrics, the song title, artist, album and length are sent to
lrclib.net, a public lyrics database. See the privacy policy for details.
```

**Description (ko)**

```
Now Playing Overlay는 YouTube나 YouTube Music 탭에서 재생 중인 곡 정보를 macOS용 Now Playing 앱으로
보내, 다른 앱 위에 떠 있는 작은 창에 보여 줍니다.

• 앨범 아트 또는 영상 썸네일. 색은 아트워크를 따라갑니다
• 시간에 맞춘 가사(YouTube Music)와 자막(YouTube). 다음 줄도 미리 보여 줍니다
• Glass·Tinted·Clear 스타일, 커버·커버+한 줄·가사·미니 레이아웃
• 어디서든 끌어 옮기고, 모든 가장자리에서 크기를 조절하고, 화면 가장자리에 붙일 수 있습니다. 클릭 통과 모드도 있습니다
• 오버레이나 전역 단축키로 재생/일시정지, 이전/다음 곡
• 가볍습니다. 확장은 이벤트를 전달만 하고, 오버레이는 재생 중 CPU를 1% 정도 씁니다

macOS용 Now Playing 앱(macOS 14 이상, Apple Silicon·Intel 공용)이 있어야 동작합니다. 앱이 없으면 아무것도 하지 않고
아무 데이터도 보내지 않습니다. 시크릿 창에서는 동작하지 않습니다.

개인정보: 계정, 분석, 추적이 없습니다. 재생 정보는 내 Mac의 Now Playing 앱으로만 갑니다.
시간 맞춤 가사를 찾을 때만 곡 제목, 아티스트, 앨범, 길이를 공개 가사 데이터베이스 lrclib.net에 보냅니다.
```

## Privacy practices tab

**Single purpose**

> Shows the media playing in the user's YouTube or YouTube Music tab (title, artwork, playback position, captions and lyrics) in the companion Now Playing macOS app, and relays play/pause/next/previous commands from that app back to the tab.

**Permission justifications**

| Permission | Justification |
|---|---|
| `nativeMessaging` | Sends playback state, artwork URLs and captions/lyrics to the user's locally installed Now Playing macOS app, and receives playback commands from it. This is the extension's only output. |
| `alarms` | Schedules a reconnect to the local Now Playing app after it restarts or is launched later, without keeping the service worker alive. |
| Host `www.youtube.com`, `music.youtube.com` | Reads the current video/track (title, artist, artwork, position) and the captions the YouTube player itself downloads, and performs play/pause/seek/next/previous on the user's request. |
| Host `lrclib.net` | Looks up time-synced lyrics for the current song (title, artist, album, length) when YouTube Music doesn't provide synced lyrics — only while the companion app is connected. |

**Remote code:** No, I am not using remote code. All JavaScript is in the package.

**Data usage** (check exactly these):

- ☑ **Website content**. Track title, artist, album, duration and captions/lyrics of the playing video are sent to the user's own Now Playing app on the same Mac. Title, artist, album and duration are also sent to lrclib.net to look up lyrics.
- ☐ Everything else (personally identifiable info, health, financial, authentication, personal communications, location, web history, user activity) stays **unchecked**.
  - The extension never sends the YouTube session anywhere. For YouTube Music lyrics it makes the same same-origin request the page makes, signed in-page with the page's own session. The session stays in the page and is never read by the extension's service worker.

Certify all three:
- I do not sell or transfer user data to third parties, outside of the approved use cases.
- I do not use or transfer user data for purposes that are unrelated to my item's single purpose.
- I do not use or transfer user data to determine creditworthiness or for lending purposes.

**Privacy policy URL:** publish `store/PRIVACY.md` somewhere public (a public GitHub repo file, GitHub Pages or a gist) and paste that URL.

## Distribution tab

- Visibility: **Unlisted**. Only people with the link can install it; it is not searchable.
- Regions: all.
