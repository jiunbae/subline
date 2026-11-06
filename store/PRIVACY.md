# Subline: Privacy Policy

_Last updated: 2026-11-06_

Subline is a Chrome extension ("Subline") and a companion macOS app. Together they
show what you are playing on YouTube, YouTube Music, Spotify or Apple Music in a floating window on your Mac.

## What is processed

| Data | Where it goes | Why |
|---|---|---|
| Title, artist, album, duration, thumbnail URL, play/pause state and position of the video or track in your YouTube / YouTube Music tab | The Subline app on **your own Mac**, through Chrome Native Messaging. It is never sent to the developer or any server. | To display it in the overlay |
| Captions the YouTube player downloads for the current video | The Subline app on your Mac | To show time-synced text |
| Title, artist, album and duration of the current song (YouTube Music, Spotify, Apple Music) | **lrclib.net**, a public lyrics database ([lrclib.net](https://lrclib.net)), requested by the **macOS app** without cookies. The extension itself contacts no one. | To find time-synced lyrics |
| What Spotify or Apple Music is playing (title, artist, album, duration, position, artwork) | Read on your Mac by the app, through the apps' own playback notifications and macOS Automation (which macOS asks you to allow). Turn it off in the menu: Follow Spotify and Apple Music | To display it and its lyrics |
| Lyric or caption lines, when you turn on "Translate on This Mac" | Apple's on-device Translation framework. The text stays on your Mac | To show a translated second line |
| Thumbnail images | Downloaded by the app directly from YouTube's image servers (`i.ytimg.com` and related hosts) | To show artwork |

## What is not done

- No accounts, analytics, advertising, telemetry or tracking.
- No browsing history is read. The extension runs only on `www.youtube.com` and `music.youtube.com`.
- It never runs in incognito/private windows (the extension declares `incognito: not_allowed`).
- The extension makes no network requests at all; without the Subline app connected, it sends nothing anywhere.
- The extension never reads your cookies or YouTube session and never calls YouTube's internal APIs.
  It only reads the captions the YouTube player itself downloads, and switches the player's caption
  track when you choose a language (restoring your own setting afterwards).
- No data is sold or shared, and none is used for anything except the features above.

## Storage

The app keeps your preferences (layout, style, position, caption languages) in macOS user defaults on your Mac.
It also remembers the last 5 videos you played (video ID, title, artist, time, and a small thumbnail made from
the artwork it already showed) so the idle overlay can offer to resume them. This stays on your Mac; clear it
from the menu bar → Recently Played → Clear Recently Played.
Captions are held in memory only: in the YouTube tab for the current and up to 7 recently viewed videos
(so switching back is instant), until the tab is closed or reloaded, and in the app for the video shown.
Lyrics found on LRCLIB are cached by the app in `~/Library/Application Support/Subline/lyrics/` (up to
800 songs, oldest removed first), with the version you picked, so songs you've heard work offline.
Apple Music artwork is kept for the last 20 tracks in `…/Subline/native-art/`. Per-song sync offsets are
kept in the app's preferences.

Developer diagnostics are off by default. If you turn on `debugDump` (see the README), the app writes
the current title and caption line to `~/Library/Application Support/Subline/debug-state.json`;
turn it off and delete that file before sharing logs. **Copy Diagnostics** in the setup window copies
only app/helper/browser-registration status, no titles or captions.

## Contact

Questions: open an issue on the project repository, or email the developer at the address shown on
the Chrome Web Store listing.
