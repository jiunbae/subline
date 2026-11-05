# Now Playing Overlay for YouTube / YouTube Music — 기획서 v0.1

> Claude(%30)와 Codex 피어(%31)가 Muxa로 각자 조사한 뒤 2라운드에 걸쳐 합의한 내용입니다 (2026-11-04).
> 표기: ✅ 합의 · ⚠️ 검증 필요 가설 · 🔬 실험 기능

## 0. 한 줄 정의
Chrome에서 재생 중인 YouTube / YouTube Music을 **다시 재생하지 않고**, 커버 아트와 시간에 맞춘 자막·가사를
macOS 화면 위에 PiP처럼 떠 있는 **네이티브 패널**로 보여주는 초경량 메뉴바 앱입니다.

**핵심 원칙 ✅**: 재생은 Chrome만 합니다. 네이티브 앱은 메타데이터, 재생 상태, 자막 cue만 받아서 그립니다.
그래서 영상 디코딩이 두 번 일어나지 않고 스트림을 추출할 필요도 없습니다. 이 원칙이 요구사항 4번
(자원 최소화)과 약관 리스크를 동시에 해결합니다.

---

## 1. 아키텍처 ✅

```
┌──────────── Chrome ────────────┐        ┌──────────── macOS ─────────────┐
│ youtube.com / music.youtube.com│        │                                │
│  ├ MAIN-world bridge (inject)  │        │  NowPlaying.app (LSUIElement)  │
│  │  · fetch/XHR 후킹 → 자막 응답 │        │   ├ 메뉴바 아이템                │
│  │  · player API → 시간/상태     │        │   ├ NSPanel (SwiftUI)          │
│  │  postMessage                │        │   └ UDS 서버 (owner)            │
│  ├ content script (isolated)   │        │            ▲                   │
│  │  · <video> 이벤트, 메타데이터  │        │            │ Unix domain sock │
│  │  · 사이트별 어댑터(YT / YTM)   │        │            │ (0700 dir/0600)  │
│  └ service worker              │ stdio  │  Contents/Helpers/np-host      │
│     · connectNative() ─────────┼───────▶│   (NM host = 얇은 중계 CLI)      │
└────────────────────────────────┘ JSON   └────────────────────────────────┘
```

| 결정 | 선택 | 근거 / 기각한 대안 |
|---|---|---|
| Ext↔Native | **Native Messaging** | Chrome 105+ `connectNative` 포트가 SW 수명을 유지합니다. localhost WebSocket은 포트 충돌, Origin 검증, 인증 토큰, 앱 선실행 문제가 있어 기각했습니다. |
| Host 형태 | 앱 번들 안의 **얇은 CLI 중계기** | Chrome은 연결할 때마다 host 프로세스를 새로 띄웁니다. GUI 앱을 host로 쓰면 stdout이 프로토콜과 섞이고 인스턴스가 중복됩니다. |
| Host↔App | **Unix domain socket** (앱이 owner, host는 client) | XPC보다 단순합니다. App Sandbox나 강한 신원 검증이 필요해지면 그때 XPC를 다시 검토합니다. |
| 앱 미실행 시 | host가 `open -g -b <bundleid>` 실행(인자 배열) → backoff → handshake timeout | 실행 요청이 성공했다고 앱이 준비된 것은 아닙니다. handshake로 준비 상태를 확인합니다. |
| 배포 | 서명 + 공증한 직접 배포(DMG/Homebrew cask) + Chrome Web Store 확장 | App Store는 5.2.2/5.2.3/4.2.3 조항과 sandbox 밖 manifest 등록 문제가 있어 MVP 범위에서 제외합니다. |

**프로토콜**: 길이 접두 JSON, `v`(버전), `seq`, `tabId`, `videoId`, `type`. 메시지 크기 상한을 자체 설정합니다
(NM 한도는 host→Chrome 1MB, Chrome→host 64MiB입니다). 오래된 `seq`/`videoId`의 메시지는 버립니다.
재연결하면 전체 상태 스냅샷을 다시 보냅니다.

주요 메시지: `track`(제목/아티스트/앨범/길이/artwork 후보) · `clock`(currentTime, rate, paused, monoTs) ·
`cues`(정규화된 자막 배열, source, lang, kind) · `cmd`(앱→확장: play/pause/next/prev/seek) · `frame`🔬

**보안**: `allowed_origins`에 확장 ID를 고정합니다. sender와 payload를 검증합니다. URL, pot, 쿠키는
로그·캐시에 남기지 않고 정규화한 cue만 캐시합니다. stale socket은 살아 있는 listener가 없을 때만 제거합니다.

---

## 2. 기능 설계

### ① 앨범 커버 (요구 1)
- **MVP ✅ 정적 커버**: YTM은 player metadata에 있는 실제 정사각 artwork를 최대 해상도로 씁니다. 일반 YouTube는
  thumbnail 후보 목록(maxres → sd → hq 순서로 폴백)을 씁니다. 16:9 영상 썸네일은 **center-crop**하거나 **블러 배경 + 원본 fit** 중에서 고릅니다.
- 다운샘플링(표시 크기 × backingScale)과 LRU 캐시(곡 몇 개 분량)를 적용하고, 곡이 바뀔 때만 다운로드합니다.
- **Phase 2 🔬 라이브 커버(opt-in)**: content script가 기존 `<video>`를 canvas로 `drawImage`하고, 저해상도
  JPEG/WebP로 만들어 `frame` 메시지로 보냅니다.
  - 시작값은 4–8fps에 짧은 변 240px입니다(상한 12fps, 360px). 인코딩은 한 번에 하나만 돌리고 최신 프레임 1장만 유지합니다. ACK 기반 역압력을 걸고 제어 메시지를 우선 처리합니다.
  - 첫 프레임 `drawImage` + `convertToBlob`이 성공할 때만 켭니다. taint, DRM, 검은 화면, 비가시 탭(rVFC 정지), timeout이 생기면 **정적 커버로 폴백하고 우회하지 않습니다**.
  - ⚠️ GPU→CPU readback, 인코딩, base64(+33%), 앱 디코딩 비용이 있습니다. tabCapture 대비 이득은 측정 전까지 가설입니다.
  - 진짜 영상이 꼭 필요하면 브라우저 PiP / Document PiP를 대안으로 안내합니다.

### ② 시간 동기 자막·가사 (요구 2) ✅
**출처별 어댑터 구조**로 만듭니다. 공통 체인 하나에 묶지 않습니다.

| 어댑터 | 방법 | 비고 |
|---|---|---|
| **YT 자막** | `document_start`에 MAIN-world에서 fetch/XHR을 후킹해 플레이어가 받은 `/api/timedtext` **응답 자체**를 복제하고 정규화합니다. PerformanceObserver는 URL 발견용 보조로만 씁니다. 필요하면 pot 포함 URL을 `fmt=json3`로 재요청합니다. | PoToken 때문에 직접 요청하면 빈 응답이나 429가 옵니다. pot을 자체 생성(bgutils)하지 **않습니다**. |
| **YTM 가사** | LRCLIB synced 가사만 씁니다(정확 조회 → 검색 1회) | 2026-11: YTM 웹은 무타임스탬프 가사만 주고 모바일 client 경로는 폐기. 웹 스토어 심사 위험(쿠키·내부 API) 때문에 YTM 자체 가사 대체 경로도 제거 |
| **화면 캡션 DOM** | 현재 표시 중인 캡션 DOM을 관찰합니다 | 위 방법이 실패할 때 쓰는 강등 경로입니다 |
| **LRCLIB** | 음악 트랙에서 사용자가 선택했을 때만 synced lyrics를 가져옵니다. 제목/아티스트/길이를 대조하고 오프셋을 조절할 수 있게 합니다 | 커버·라이브 버전 오매칭에 주의해야 합니다 |

- 자막이 꺼져 있을 때 자동으로 켜는 동작은 하지 않습니다. 사용자가 **“자막 연결” 버튼**을 누를 때만 1회 토글하고 원래 상태로 되돌립니다.
- 캐시 키: `videoId + lang + trackKind(asr/manual) + source + version`. 라이브나 변경 가능한 자막에는 TTL을 둡니다.
- 수동/자동(asr) 자막을 구분하고, 자동 자막의 롤링 세그먼트 중복은 병합해 정규화합니다.

**동기화 ✅**: play/pause/seeking/seeked/ratechange/waiting/playing 이벤트가 오면 즉시 `clock`을 보내고,
재생 중에는 1초마다 보정값을 보냅니다. 앱은 `monotonic clock + currentTime × rate`로 보간하고
**다음 cue 경계 시각에만 타이머 1개를 예약**합니다(프레임 루프 없음). 버퍼링 중에는 보간을 멈춥니다.

### ③ 플로팅 패널 (요구 3) ✅
- `NSPanel` + `.nonactivatingPanel`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
  (가용하면 `canJoinAllApplications`도 검토). 포커스를 빼앗지 않습니다.
- 드래그로 이동하고, 모서리 핸들이나 ⌥+스크롤로 크기를 조절합니다. 최소/최대 크기와 고정 비율 옵션을 둡니다.
- 놓으면 `visibleFrame` 기준으로 **화면 모서리 4곳에 스냅**하고 스프링 애니메이션을 줍니다. 위치는 화면별 상대좌표로 저장하고, 모니터가 분리되면 복구합니다.
- **클릭 통과 모드**(`ignoresMouseEvents`): 켜기 전에 메뉴바 해제 경로와 단축키를 반드시 제공합니다.
- 레이아웃 프리셋: **Cover**(커버만) · **Cover + Line**(커버와 현재 줄) · **Lyrics**(3–5줄 스크롤, 현재 줄 강조) · **Mini pill**(아이콘 + 한 줄).
- 호버 시 재생 컨트롤(⏮ ⏯ ⏭)과 진행바를 페이드인합니다. 명령은 `cmd`로 해당 탭에 보내고, 결과는 상태 메시지로 확인합니다.

### ④ 자원 예산 (요구 4) ✅ (초기 합격 목표이며 보장치는 아닙니다)
| 지표 (Apple Silicon, release) | 목표 |
|---|---|
| 앱 + host physical footprint | ≤ 80 MB |
| 숨김/정지 CPU | 평균 ≤ 0.2% |
| 커버 + 자막 재생 CPU | 평균 ≤ 1% (코어 1개 = 100%) |
| 확장(SW + content) 추가 부하 | 차분 측정으로 별도 보고 |

달성 수단: WebView 없음 · 상시 blur는 배경 1겹만, 정지 시 비활성 · 60fps 진행바 대신 cue/초 단위 갱신 ·
이벤트 구동 · 커버 다운샘플링 · 패널이 숨겨지면 확장에 “clock 전송 중단”을 알립니다.
Instruments로 정지/재생/seek/이동 시나리오를 각각 측정하는 단계를 CI 체크리스트에 넣습니다.

### ⑤ YouTube 연동 (요구 5) ✅
- 확장을 설치하면 youtube.com과 music.youtube.com 탭을 자동 감지합니다. 재생 중인 탭이 여럿이면 **가장 최근에 재생된 탭**을 따르고, 메뉴바에서 고정할 수 있습니다.
- 광고 중에는 메타데이터를 무시하고 “광고” 상태로 표시합니다(잘못된 커버가 뜨지 않게 합니다).
- 첫 실행 온보딩: 앱 설치 → NM manifest 자동 등록(`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`, Chromium·Arc·Brave 경로도 포함) → 확장 설치 링크 → “연결됨” 확인 → 문제가 있으면 복구 버튼.

### ⑥ UI/UX (요구 6)
- 둥근 모서리(continuous corner)와 `.ultraThinMaterial`을 쓰되, 커버 색상에서 추출한 그라데이션을 배경에 은은하게 깝니다(곡 전환 시 크로스페이드).
- 자막 타이포: SF Pro Rounded / 시스템 폰트, 현재 줄 100% 불투명, 이웃 줄 35%. 줄 전환은 위로 슬라이드하며 페이드합니다.
- 곡 전환 시 커버를 3D 플립하지 않고 크로스페이드 + 약간의 스케일을 줍니다(과하지 않게).
- 다크/라이트 자동 전환과 투명도 슬라이더를 둡니다. 전체화면 앱 위에서도 방해되지 않도록 “전체화면에서 자동 축소” 옵션을 둡니다.
- 메뉴바: 연결 상태 점, 현재 곡, 레이아웃, 클릭 통과, 항상 위, 자막 출처/언어/오프셋, 종료.

---

## 3. 로드맵
| 단계 | 범위 | 완료 기준 |
|---|---|---|
| **M0 스파이크 (1주)** | NM 왕복, UDS 중계, MAIN-world timedtext 캡처 PoC, YTM timedLyrics PoC | 실제 세션에서 자막 획득 성공률 기록, 메시지 지연 < 50ms |
| **M1 MVP** | 탭 1개 추적, 정적 커버, 제목/아티스트, play/pause/next, 행 단위 자막, 이동/리사이즈/스냅/통과 토글, 메뉴바 | §2-④ 예산 충족 (Instruments 측정) |
| **M2** | LRCLIB, 다중 탭, 레이아웃 프리셋, 색상 추출 테마, 온보딩/복구 UX | |
| **M3 🔬** | 라이브 커버, 단축키, 다중 모니터 정교화 | 라이브 커버 on 상태의 CPU를 별도 측정해 opt-in 유지 여부 결정 |

**기술 스택**: Swift 6 / SwiftUI + AppKit(NSPanel), 최소 macOS 14 · 확장은 TypeScript + Vite, MV3 · host는 Swift CLI(의존성 0).

## 4. 리스크 ⚠️
- **YouTube 비공개 응답·DOM 변경, PoToken 정책 변경**: 어댑터를 격리하고, 실패하면 “자막 없음”으로 강등합니다. 셀렉터 의존을 최소화하고 player API·응답 데이터를 우선합니다.
- **약관**: 썸네일·자막만 써도 YouTube 약관상 자동 면책되지 않습니다. 스트림 추출은 영구 제외하고, 공개 배포 전에 권리·약관을 검토합니다.
- **timedtext 레이트리밋(429)**: 플레이어 응답을 복제하는 방식을 우선하고 재요청을 최소화합니다(캐시).
- **SW 종료 / 브라우저 재시작**: `onDisconnect`에서 재연결하고 상태 스냅샷을 다시 보냅니다.
- **전체화면, Stage Manager, 다중 모니터 동작**: M1 QA 매트릭스에 포함합니다.

## 5. 참고
- Chrome [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) · [SW lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) · [Document PiP](https://developer.chrome.com/docs/web-platform/document-picture-in-picture)
- timedtext PoToken 대응 사례: [yt-dual-subs](https://github.com/Gythiro/yt-dual-subs), [MoonDigest PR](https://github.com/PathGao/MoonDigest/pull/12), [2026 scraper 정리](https://dev.to/jamhimself/why-your-youtube-transcript-scraper-started-returning-empty-strings-and-how-to-fix-it-in-2026-20ed)
- YTM 가사: [ytmusicapi get_lyrics](https://ytmusicapi.readthedocs.io/en/stable/reference/browsing.html#ytmusicapi.YTMusic.get_lyrics), [synced lyrics gist](https://gist.github.com/limhenry/d9ba0f65234a496a16999714fc87ac78), [Better Lyrics](https://github.com/better-lyrics/better-lyrics), [LRCLIB](https://lrclib.net/docs.txt)
- Apple: [collectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications), [ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents), [LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement), [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
