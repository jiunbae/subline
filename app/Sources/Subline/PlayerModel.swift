import AppKit
import SwiftUI
import Observation
import SublineCore

enum OverlayLayout: String, CaseIterable, Identifiable {
    case cover, coverLine, lyrics, mini
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cover: L10n.string("Cover")
        case .coverLine: L10n.string("Cover + Line")
        case .lyrics: L10n.string("Lyrics")
        case .mini: L10n.string("Mini")
        }
    }
    var defaultSize: CGSize {
        switch self {
        case .cover: CGSize(width: 240, height: 240)
        case .coverLine: CGSize(width: 380, height: 120)
        case .lyrics: CGSize(width: 320, height: 440)
        case .mini: CGSize(width: 320, height: 56)
        }
    }
    var minSize: CGSize {
        switch self {
        case .cover: CGSize(width: 120, height: 120)
        case .coverLine: CGSize(width: 260, height: 84)
        case .lyrics: CGSize(width: 220, height: 260)
        case .mini: CGSize(width: 200, height: 44)
        }
    }
    var maxSize: CGSize { CGSize(width: 960, height: 960) }
}

/// Visual theme of the overlay.
enum OverlayStyle: String, CaseIterable, Identifiable {
    /// Transparent window; artwork floats, text sits on Liquid Glass (macOS 26+, material fallback).
    case glass
    /// The original blurred, artwork-tinted panel.
    case tinted
    /// No backing at all; text keeps a soft shadow for contrast.
    case clear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: L10n.string("Glass")
        case .tinted: L10n.string("Tinted")
        case .clear: L10n.string("Clear")
        }
    }
}

/// UI-facing state. Property writes are guarded so SwiftUI only invalidates on real change.
@MainActor @Observable
final class PlayerModel {
    // Track
    private(set) var hasTrack = false
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album: String?
    private(set) var site: String?
    private(set) var isAd = false
    private(set) var isPlaying = false
    private(set) var duration: Double?
    private(set) var artwork: NSImage?
    private(set) var accent: Color = Color(white: 0.35)

    // Text
    private(set) var cues: [Cue] = []
    private(set) var synced = false
    private(set) var cueSource: String?
    private(set) var activeIndex: Int?
    private(set) var upcomingIndex: Int?
    /// Lines are changing faster than every 2 s (auto-generated captions): views skip their
    /// transitions, which would otherwise be running most of the time.
    private(set) var fastLines = false
    @ObservationIgnored private var lastLineChangeAt: Double = 0
    /// Secondary ("sub") caption track shown under the main line.
    private(set) var secondaryCues: [Cue] = []
    private(set) var secondaryActiveIndex: Int?
    private(set) var secondaryTrackID: String?
    /// For each main cue, the secondary text that overlaps its start (Lyrics layout rows).
    private(set) var secondaryByRow: [String?] = []
    /// Recently played videos (newest first) and their thumbnails, for the idle overlay.
    private(set) var recents: [RecentTrack] = RecentStore.load()
    private(set) var recentThumbs: [String: NSImage] = [:]
    /// The connected extension is older than the one bundled with this app (reload it).
    private(set) var extensionOutdated: (running: String, bundled: String)?
    private(set) var liveCaption: String?
    /// Caption tracks the YouTube player offers for this video, and the one currently shown.
    private(set) var captionTracks: [CaptionTrack] = []
    /// Auto-translation targets ("x-<lang>") the player offers for this video.
    private(set) var translations: [CaptionTrack] = []
    private(set) var captionTrackID: String?
    /// A caption fetch was requested and nothing has arrived yet.
    private(set) var captionsLoading = false
    /// LRCLIB versions for the current song, the one shown, and whether a lookup is running.
    private(set) var lyricsCandidates: [LyricsCandidate] = []
    private(set) var lyricsChosenID: Int?
    private(set) var lyricsSearching = false
    /// Why the on-device second line isn't shown (e.g. a language still to download), for the menu.
    private(set) var derivedNote: String?

    enum TextStatus: Equatable {
        case timed      // synced cues or live captions
        case unsynced   // lyrics without timestamps (Lyrics layout only)
        case loading    // captions requested, not here yet
        case available  // the video has captions but none were loaded (auto-connect off)
        case none       // nothing to show
    }
    var textStatus: TextStatus {
        if isAd { return .none }
        if liveCaption != nil || (synced && !cues.isEmpty) { return .timed }
        if !cues.isEmpty { return .unsynced }
        if captionsLoading || lyricsSearching { return .loading }
        if site == "yt" && !captionTracks.isEmpty { return .available }
        return .none
    }

    // Environment
    private(set) var connectionCount = 0
    var hovering = false
    var clickThrough = false
    var layout: OverlayLayout = OverlayLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .coverLine {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "layout") }
    }
    var style: OverlayStyle = OverlayStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .glass {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "style") }
    }
    var opacity: Double = UserDefaults.standard.object(forKey: "opacity") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(opacity, forKey: "opacity") }
    }
    /// When a YouTube video has no captions yet, briefly toggle CC so the player fetches them.
    var autoCaptions: Bool = UserDefaults.standard.object(forKey: "autoCaptions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCaptions, forKey: "autoCaptions"); refresh() }
    }
    /// Caption delay in seconds: positive shows text later, negative earlier. Remembered per song/video.
    var captionOffset: Double = 0 {
        didSet {
            reschedule()
            guard let k = offsetKey, !loadingOffset else { return }
            var all = UserDefaults.standard.dictionary(forKey: "syncOffsets") as? [String: Double] ?? [:]
            all[k] = abs(captionOffset) < 0.001 ? nil : captionOffset
            if all.count > 500 { for key in all.keys.filter({ $0 != k }).prefix(all.count - 400) { all[key] = nil } }
            UserDefaults.standard.set(all, forKey: "syncOffsets")
        }
    }
    @ObservationIgnored private var offsetKey: String?
    @ObservationIgnored private var loadingOffset = false

    /// Seeks so that cue `i` is the current line (accounts for the sync offset).
    func seek(toCue i: Int) {
        guard synced, cues.indices.contains(i) else { return }
        command("seek", t: max(0, cues[i].s + captionOffset + 0.01))
    }

    @ObservationIgnored private(set) var store = SessionStore()
    @ObservationIgnored var send: ((Outgoing, Int?) -> Void)?
    /// Spotify / Apple Music source (menu toggle).
    @ObservationIgnored var native: NativePlayers? {
        didSet { native?.onDeniedChange = { [weak self] d in self?.assign(\.automationDenied, d) } }
    }
    /// macOS Automation access to Spotify/Music was declined (setup window explains how to allow it).
    private(set) var automationDenied = false
    /// What's shown comes from the Spotify or Music app (no browser extension involved).
    var playingFromNativeApp: Bool { hasTrack && (site == "spotify" || site == "music") }
    /// Fired after every state projection: (hasTrack, isPlaying, videoId). Drives overlay auto show/hide.
    @ObservationIgnored var onPresence: ((Bool, Bool, String?) -> Void)?
    /// Opens the setup window (wired by the app delegate).
    @ObservationIgnored var openSetup: (() -> Void)?
    /// Opens the appearance gallery.
    @ObservationIgnored var openAppearance: (() -> Void)?
    /// Pops the caption language menu at the mouse (wired by the status menu controller).
    @ObservationIgnored var showCaptionMenu: (() -> Void)?
    /// Switches the overlay layout (wired by the panel controller).
    @ObservationIgnored var requestLayout: ((OverlayLayout) -> Void)?
    /// Caption track requested per video. A request that produced nothing may be retried (reloads,
    /// returning to a video, a player that wasn't ready).
    private struct CaptionRequest { var id: String; var at: Double; var tries: Int }
    @ObservationIgnored private var captionSelectSent: [String: CaptionRequest] = [:] // videoId → request
    private func recentRequest(_ vid: String) -> CaptionRequest? {
        guard let r = captionSelectSent[vid] else { return nil }
        return (Self.now - r.at < 10 || r.tries >= 2) ? r : nil
    }
    @ObservationIgnored private var loadingTimeout: DispatchWorkItem?
    @ObservationIgnored private var recentSavedAt: Double = 0
    /// Artwork candidate key whose image is currently in `artwork` (set when the load lands).
    @ObservationIgnored private var artworkShownKey: String?
    @ObservationIgnored private var thumbsLoaded = false
    /// Secondary request per video; retried (once) when nothing matching arrived within 10 s.
    @ObservationIgnored private var secondarySent: [String: CaptionRequest] = [:]
    @ObservationIgnored private var secondaryMappedFor: [Cue] = []
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var panelVisible = false // the panel starts hidden
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var artworkFailedAt: [String: Double] = [:]
    @ObservationIgnored private var currentVideo: String?
    @ObservationIgnored private var autoCaptionTried: [String: Int] = [:]
    @ObservationIgnored private var autoCaptionWork: DispatchWorkItem?
    @ObservationIgnored private let artworkLoader = ArtworkLoader()
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private let lyricsService = LyricsService()
    @ObservationIgnored private var lyricsFor: String?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsRetries = 0
    @ObservationIgnored private var derivedSig: String?
    @ObservationIgnored private var derivedFor: [Cue] = []
    @ObservationIgnored private var derivedGen = 0
    /// Language pair waiting for a download (menu: the note item starts it).
    @ObservationIgnored private(set) var pendingDownload: (String, String)?

    func downloadTranslationLanguages() {
        #if canImport(Translation)
        guard let (from, to) = pendingDownload else { return }
        TranslationDownloader.show(source: from, target: to) { [weak self] in
            guard let self else { return }
            self.pendingDownload = nil
            self.derivedSig = nil
            self.refresh()
        }
        #endif
    }
    @ObservationIgnored private var derivedTask: Task<Void, Never>?

    /// Remembered caption choice (track id like "ko" or "en:asr"); applied to later videos by language.
    var preferredCaptionID: String? = UserDefaults.standard.string(forKey: "captionTrack") {
        didSet { UserDefaults.standard.set(preferredCaptionID, forKey: "captionTrack") }
    }
    /// Remembered secondary track (nil = off).
    var preferredSecondaryID: String? = UserDefaults.standard.string(forKey: "captionTrack2") {
        didSet { UserDefaults.standard.set(preferredSecondaryID, forKey: "captionTrack2") }
    }

    var showNextLine: Bool = UserDefaults.standard.object(forKey: "showNextLine") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNextLine, forKey: "showNextLine") }
    }

    /// The following synced line, shown dimmed under the current one.
    var nextLine: String? {
        guard showNextLine, synced, let i = upcomingIndex, i < cues.count else { return nil }
        return cues[i].text
    }

    var secondaryLine: String? {
        guard let i = secondaryActiveIndex, i < secondaryCues.count else { return nil }
        return secondaryCues[i].text
    }

    var currentLine: String? {
        if let i = activeIndex, i < cues.count { return cues[i].text }
        return liveCaption
    }

    var tabs: [TabState] { store.tabs.values.sorted { $0.key.tab < $1.key.tab } }
    var pinned: TabKey? { store.pinned }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Interpolated media time (for progress UI only).
    func position() -> Double { store.active?.clock?.position(at: Self.now) ?? 0 }

    // MARK: Inputs

    func connected(_ id: Int) {
        connectionCount += 1
    }

    func disconnected(_ id: Int) {
        connectionCount = max(0, connectionCount - 1)
        store.removeConnection(id)
        checkExtensionVersion()
        refresh()
    }

    func handle(conn: Int, _ msg: Incoming) {
        if store.apply(msg, conn: conn, now: Self.now) { refresh() }
        if case .hello = msg { checkExtensionVersion() }
    }

    func pin(_ key: TabKey?) {
        store.pinned = key
        refresh()
    }

    // MARK: Commands

    func command(_ action: String, t: Double? = nil) {
        guard let k = store.activeKey else { return }
        send?(.cmd(tab: k.tab, action: action, t: t), k.conn)
        // Optimistic UI for play/pause; the next clock message confirms.
        if action == "toggle" { assign(\.isPlaying, !isPlaying) }
    }

    /// Relative seek (menu, VoiceOver).
    func skip(by seconds: Double) {
        guard hasTrack else { return }
        let t = max(0, position() + seconds)
        command("seek", t: duration.map { min(t, max(0, $0 - 1)) } ?? t)
    }

    func connectCaptions() {
        guard let k = store.activeKey else { return }
        if let target = preferredTrack(in: store.active?.captionTracks ?? []) {
            selectCaptions(target.id, remember: false)
            return
        }
        send?(.connectCaptions(tab: k.tab), k.conn)
        setLoading(true)
    }

    /// Shows `id` in the overlay (the player's own caption setting is restored afterwards).
    /// Secondary track: shown under the main text. nil turns it off.
    func selectSecondary(_ id: String?, remember: Bool = true) {
        guard let k = store.activeKey, let vid = store.active?.track?.videoId else { return }
        if let id, id == captionTrackID { return } // the main track can't also be the sub
        derivedTask?.cancel(); derivedSig = nil
        if DerivedLines.isDerived(id) || (id == nil && DerivedLines.isDerived(secondaryTrackID)) {
            // Made on this Mac: stop any YouTube sub track, then (re)build from the main text.
            if remember { preferredSecondaryID = id }
            if k.conn != NativePlayers.conn, secondaryTrackID != nil, !DerivedLines.isDerived(secondaryTrackID) {
                send?(.selectCaptions(tab: k.tab, trackID: "", slot: 2), k.conn)
            }
            derivedSig = nil; derivedTask?.cancel(); assign(\.derivedNote, nil)
            clearSecondary(k, vid)
            refresh()
            return
        }
        if remember { preferredSecondaryID = id }
        let tries = (secondarySent[vid].map { $0.id == (id ?? "") ? $0.tries + 1 : 1 } ?? 1)
        secondarySent[vid] = CaptionRequest(id: id ?? "", at: Self.now, tries: remember ? 1 : tries)
        send?(.selectCaptions(tab: k.tab, trackID: id ?? "", slot: 2), k.conn)
        if id == nil {
            assign(\.secondaryCues, []); assign(\.secondaryActiveIndex, nil); assign(\.secondaryTrackID, nil)
            assign(\.secondaryByRow, [])
        }
    }

    private func clearSecondary(_ k: TabKey, _ vid: String) {
        let empty = CueSet(videoId: vid, source: "derived", lang: nil, kind: "manual", synced: true, cues: [], slot: 2)
        store.apply(.cues(tab: k.tab, seq: nil, empty), conn: k.conn, now: Self.now)
    }

    func selectCaptions(_ id: String, remember: Bool = true) {
        guard let k = store.activeKey, let vid = store.active?.track?.videoId else { return }
        if remember { preferredCaptionID = id }
        // Main and sub can't be the same track (incl. the same auto-translation).
        if secondaryTrackID == id || (remember && preferredSecondaryID == id) { selectSecondary(nil, remember: remember) }
        let tries = remember ? 1 : (captionSelectSent[vid].map { $0.id == id ? $0.tries + 1 : 1 } ?? 1)
        captionSelectSent[vid] = CaptionRequest(id: id, at: Self.now, tries: tries)
        send?(.selectCaptions(tab: k.tab, trackID: id), k.conn)
        setLoading(true)
    }

    /// Best track for the remembered choice: exact id, else same language (manual before auto-generated).
    func preferredTrack(in tracks: [CaptionTrack]) -> CaptionTrack? {
        CaptionTrack.best(for: preferredCaptionID, in: tracks + (store.active?.translations ?? []))
    }

    /// Display name for a track id (native or "x-<lang>" translation).
    func trackName(_ id: String?) -> String? {
        guard let id else { return nil }
        if let t = (captionTracks + translations).first(where: { $0.id == id }) {
            return t.isTranslation ? L10n.format("%@ (auto-translated)", t.name) : t.name
        }
        return id
    }

    private func setLoading(_ on: Bool) {
        loadingTimeout?.cancel(); loadingTimeout = nil
        assign(\.captionsLoading, on)
        guard on else { return }
        let w = DispatchWorkItem { [weak self] in self?.assign(\.captionsLoading, false) }
        loadingTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: w)
    }

    func setVisible(_ visible: Bool) {
        panelVisible = visible
        updateVisibility()
    }

    /// Menu bar / notch lines that need the current line even while the overlay is hidden.
    @ObservationIgnored private var lineMirrors: Set<String> = []
    func setLineMirror(_ name: String, on: Bool) {
        if on { lineMirrors.insert(name) } else { lineMirrors.remove(name) }
        updateVisibility()
    }
    private var showingText: Bool { panelVisible || !lineMirrors.isEmpty }
    @ObservationIgnored private var sentVisible = false

    private func updateVisibility() {
        // Broadcast only real changes: every visibility message makes each tab answer with a clock.
        guard showingText != sentVisible else { reschedule(); return }
        sentVisible = showingText
        send?(.visibility(showingText), nil)
        reschedule()
    }

    // MARK: State projection

    private func assign<T: Equatable>(_ kp: ReferenceWritableKeyPath<PlayerModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    private func refresh() {
        guard let s = store.active, let t = s.track else {
            assign(\.hasTrack, false)
            assign(\.isPlaying, false)
            assign(\.cues, [])
            assign(\.activeIndex, nil)
            assign(\.upcomingIndex, nil)
            assign(\.secondaryCues, [])
            assign(\.secondaryActiveIndex, nil)
            assign(\.secondaryTrackID, nil)
            assign(\.secondaryByRow, [])
            assign(\.liveCaption, nil)
            assign(\.captionTracks, [])
            assign(\.translations, [])
            assign(\.captionTrackID, nil)
            setLoading(false)
            assign(\.lyricsSearching, false)
            // Nothing plays: a later return of the same song (new tab, reconnect) starts fresh.
            lyricsTask?.cancel(); lyricsTask = nil; lyricsFor = nil
            derivedTask?.cancel(); derivedTask = nil; derivedSig = nil; derivedFor = []
            currentVideo = nil
            timer?.cancel()
            onPresence?(false, false, nil)
            if Self.debugDump { dumpState() }
            return
        }
        if currentVideo != t.videoId {
            currentVideo = t.videoId
            offsetKey = t.site + ":" + t.videoId
            let saved = (UserDefaults.standard.dictionary(forKey: "syncOffsets") as? [String: Double])?[offsetKey!] ?? 0
            loadingOffset = true
            if captionOffset != saved { captionOffset = saved }
            loadingOffset = false
            // Nothing from the previous song's lookups may land on this one.
            lyricsTask?.cancel(); lyricsTask = nil; lyricsFor = nil; lyricsRetries = 0
            assign(\.lyricsCandidates, []); assign(\.lyricsChosenID, nil); assign(\.lyricsSearching, false)
            derivedTask?.cancel(); derivedTask = nil; derivedSig = nil; pendingDownload = nil
            assign(\.derivedNote, nil)
        }
        assign(\.hasTrack, true)
        assign(\.title, t.title)
        assign(\.artist, t.artist)
        assign(\.album, t.album)
        assign(\.site, t.site)
        assign(\.isAd, t.isAd ?? false)
        assign(\.duration, t.duration)
        assign(\.isPlaying, s.isPlaying)
        // During an ad, hide the video's cues (kept in the store, restored when the ad ends).
        let cueSet = (s.cueSet?.videoId == t.videoId && !(t.isAd ?? false)) ? s.cueSet : nil
        // Timeline cues are pre-sorted and share storage across ticks, so == hits the identity fast path.
        assign(\.cues, cueSet == nil ? [] : s.timeline.cues)
        let sub = (s.secondaryCueSet?.videoId == t.videoId && !(t.isAd ?? false) && cueSet != nil && !s.timeline.cues.isEmpty) ? s.secondaryCueSet : nil
        let subCues = sub == nil ? [] : s.secondaryTimeline.cues
        // Rebuild when either track's content changes (not just the row count: a different main track
        // with the same number of lines must not keep the old mapping). Equal arrays share storage, so
        // this is a pointer check on ordinary ticks.
        if subCues != secondaryCues || cues != secondaryMappedFor {
            secondaryMappedFor = cues
            assign(\.secondaryCues, subCues)
            assign(\.secondaryByRow, subCues.isEmpty ? [] : cues.map { c in
                s.secondaryTimeline.activeIndex(at: c.s + 0.05).map { s.secondaryTimeline.cues[$0].text }
            })
        }
        assign(\.secondaryTrackID, sub?.trackID)
        assign(\.synced, cueSet?.synced ?? false)
        assign(\.cueSource, cueSet?.source)
        assign(\.liveCaption, (t.isAd ?? false) ? nil : s.liveCaption)
        assign(\.captionTracks, s.captionTracks)
        assign(\.translations, s.translations)
        assign(\.captionTrackID, cueSet?.trackID)
        if captionsLoading, !cues.isEmpty || liveCaption != nil {
            // Done once the requested track (or any text, when none was specified) is here.
            let wanted = captionSelectSent[t.videoId]?.id
            if wanted == nil || wanted == captionTrackID || cueSet?.source != "yt-captions" { setLoading(false) }
        }
        if s.captionTracksKnown && s.captionTracks.isEmpty && captionsLoading { setLoading(false) }
        applyCaptionPreference(s, t)
        applySecondaryPreference(s, t)
        scheduleDerived(s, t, cueSet)
        recordRecent(t, playing: s.isPlaying)
        loadArtwork(t)
        reschedule()
        scheduleAutoCaptions(s, t)
        scheduleLyrics(s, t)
        onPresence?(true, s.isPlaying, t.videoId)
        if Self.debugDump, Self.now - lastDumpAt > 0.5 { lastDumpAt = Self.now; dumpState() } // ≤2 writes/s
    }

    /// Applies the remembered caption language once per video when the player offers it.
    private func applyCaptionPreference(_ s: TabState, _ t: TrackInfo) {
        guard t.site == "yt", !(t.isAd ?? false), s.isPlaying, recentRequest(t.videoId) == nil,
              autoCaptions || captionTrackID != nil,
              let target = preferredTrack(in: s.captionTracks), target.id != captionTrackID else { return }
        if captionSelectSent.count > 64 { captionSelectSent.removeAll() }
        selectCaptions(target.id, remember: false)
    }

    /// Romanized / translated second line for the current main text (rebuilt when the text changes).
    private func scheduleDerived(_ s: TabState, _ t: TrackInfo, _ main: CueSet?) {
        guard let pref = preferredSecondaryID, DerivedLines.isDerived(pref), let main, main.synced, !cues.isEmpty, !(t.isAd ?? false) else { return }
        let sig = ["\(s.key)", t.videoId, pref, main.trackID ?? main.source].joined(separator: "|")
        // Same session/track/choice and the same main text (equal arrays usually share storage) → done.
        guard sig != derivedSig || cues != derivedFor else { return }
        derivedSig = sig
        derivedFor = cues
        derivedGen &+= 1
        let gen = derivedGen
        derivedTask?.cancel()
        // Don't leave lines made from the previous text up while the new ones are built.
        if DerivedLines.isDerived(s.secondaryCueSet?.trackID) { clearSecondary(s.key, t.videoId) }
        let key = s.key, vid = t.videoId, source = cues, lang = DerivedLines.language(of: cues, hint: main.lang)
        derivedTask = Task { [weak self] in
            var out: [Cue] = []
            var note: String?
            var download: (String, String)?
            if pref == DerivedLines.romajiID {
                out = await Task.detached(priority: .utility) { DerivedLines.romanized(source, lang: lang) }.value
                if out.isEmpty { note = L10n.string("Nothing to romanize in this text") }
            } else {
                switch await DerivedLines.translated(source, source: lang) {
                case let .cues(c): out = c
                case let .needsDownload(from, to):
                    note = L10n.format("Download %@ → %@ for translation…", DerivedLines.name(from), DerivedLines.name(to))
                    download = (from, to)
                case .sameLanguage: note = L10n.string("Already in your language")
                case .unavailable: note = L10n.string("Translation isn't available for this language")
                }
            }
            guard !Task.isCancelled, let self, self.derivedGen == gen, self.store.active?.key == key,
                  self.store.active?.track?.videoId == vid else { return }
            self.assign(\.derivedNote, note)
            self.pendingDownload = download
            var set = CueSet(videoId: vid, source: pref == DerivedLines.romajiID ? "romanized" : "apple-translate",
                             lang: pref == DerivedLines.romajiID ? nil : DerivedLines.targetCode(for: lang), kind: "manual", synced: true, cues: out, slot: 2)
            set.trackId = pref
            if self.store.apply(.cues(tab: key.tab, seq: nil, set), conn: key.conn, now: Self.now) { self.refresh() }
        }
    }

    /// Applies the remembered secondary track once per video, after the main text is in.
    private func applySecondaryPreference(_ s: TabState, _ t: TrackInfo) {
        if DerivedLines.isDerived(preferredSecondaryID) { return }
        // Retry a request that produced nothing after 10 s, at most twice per video.
        if let r = secondarySent[t.videoId], r.id.isEmpty || r.id == secondaryTrackID || Self.now - r.at < 10 || r.tries >= 2 { return }
        guard t.site == "yt", !(t.isAd ?? false), s.isPlaying,
              captionTrackID != nil, !captionsLoading,
              let target = CaptionTrack.best(for: preferredSecondaryID, in: s.captionTracks + s.translations),
              target.id != captionTrackID else { return }
        if secondarySent.count > 64 { secondarySent.removeAll() }
        selectSecondary(target.id, remember: false)
    }

    // MARK: Recently played

    private func recordRecent(_ t: TrackInfo, playing: Bool) {
        guard playing, !(t.isAd ?? false), !t.title.isEmpty, !t.videoId.isEmpty else { return }
        if recents.first?.videoId == t.videoId {
            // Refresh "last played" at most every 30 s; also store the thumbnail once artwork is in.
            if recentThumbs[t.videoId] == nil, let art = artwork, artworkShownKey == t.artwork.map(\.url).joined(separator: "\n"),
               let thumb = RecentStore.saveThumb(art, for: t.videoId) {
                recentThumbs[t.videoId] = thumb
            }
            guard Self.now - recentSavedAt > 30 else { return }
            recents[0].at = Date()
        } else {
            var list = recents.filter { $0.videoId != t.videoId }
            list.insert(RecentTrack(videoId: t.videoId, site: t.site, title: t.title, artist: t.artist, at: Date()), at: 0)
            recents = Array(list.prefix(RecentStore.limit))
            let keep = Set(recents.map(\.videoId))
            recentThumbs = recentThumbs.filter { keep.contains($0.key) } // drop thumbs that fell off the list
        }
        recentSavedAt = Self.now
        RecentStore.save(recents)
    }

    /// Loads stored thumbnails the first time the idle view needs them.
    func loadRecentThumbs() {
        guard !thumbsLoaded else { return }
        thumbsLoaded = true
        for r in recents where recentThumbs[r.videoId] == nil {
            if let img = RecentStore.thumb(r.videoId) { recentThumbs[r.videoId] = img }
        }
    }

    /// Resumes in the tab that still has the video, otherwise opens it in the default browser
    /// (the overlay picks it up once it plays).
    func resume(_ r: RecentTrack) {
        if let tab = store.tabs.values.first(where: { $0.track?.videoId == r.videoId }) {
            send?(.cmd(tab: tab.key.tab, action: "play"), tab.key.conn)
        } else if let url = r.url {
            NSWorkspace.shared.open(url)
        }
    }

    func clearRecents() {
        RecentStore.clear()
        recents = []
        recentThumbs = [:]
    }

    private func checkExtensionVersion() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("extension/manifest.json"),
              let data = try? Data(contentsOf: url),
              let bundled = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String else { return }
        let running = store.extensionVersions.values.min { $0.compare($1, options: .numeric) == .orderedAscending }
        if let running, running.compare(bundled, options: .numeric) == .orderedAscending {
            extensionOutdated = (running, bundled)
        } else {
            extensionOutdated = nil
        }
    }

    // MARK: Previews (appearance gallery)

    /// Snapshot of `live` for static previews; falls back to sample content so every style shows text.
    func loadPreview(from live: PlayerModel) {
        hasTrack = true
        isPlaying = true
        if live.hasTrack {
            title = live.title; artist = live.artist; album = live.album; site = live.site
            artwork = live.artwork; accent = live.accent
        } else {
            title = "Sunset Drive"; artist = "Lumen Coast"; site = "ytm"
            artwork = Self.sampleArtwork; accent = Color(red: 0.55, green: 0.25, blue: 0.65)
        }
        if live.hasTrack, live.synced, live.cues.count > 2 {
            cues = live.cues; synced = true
            let i = min(max(live.activeIndex ?? 1, 0), cues.count - 2)
            activeIndex = i; upcomingIndex = i + 1
        } else {
            cues = ["City lights are fading slow", "Hold the moment, let it glow", "Every word is on its way",
                    "Sing it back another day", "Nothing left but you and me", "Floating where the light is free"]
                .enumerated().map { Cue(s: Double($0.offset) * 3, text: $0.element) }
            synced = true; activeIndex = 1; upcomingIndex = 2
        }
        liveCaption = nil
    }

    /// Original abstract "album art" for samples (never a real cover).
    @ObservationIgnored static let sampleArtwork: NSImage? = {
        let art = ZStack {
            LinearGradient(colors: [Color(red: 0.99, green: 0.55, blue: 0.38), Color(red: 0.55, green: 0.22, blue: 0.68)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1.0, green: 0.85, blue: 0.55)).frame(width: 150).offset(x: 40, y: 30).blur(radius: 2)
            Rectangle().fill(LinearGradient(colors: [.clear, Color(red: 0.14, green: 0.08, blue: 0.30)],
                                            startPoint: .top, endPoint: .bottom)).frame(height: 180).offset(y: 130)
        }
        .frame(width: 400, height: 400)
        let r = ImageRenderer(content: art)
        r.scale = 1
        return r.nsImage
    }()

    /// Preview/verification states (store shots): nothing playing with the saved recents, or paused.
    func loadIdlePreview() {
        hasTrack = false; isPlaying = false; connectionCount = 1
        recents = RecentStore.load(); thumbsLoaded = false; loadRecentThumbs()
    }
    func setPreviewPaused() { isPlaying = false }

    // MARK: Auto captions

    /// Up to two attempts per video (2 s and 8 s after playback starts), only while nothing is shown.
    private func scheduleAutoCaptions(_ s: TabState, _ t: TrackInfo) {
        let needs = autoCaptions && t.site == "yt" && !(t.isAd ?? false) && s.isPlaying
            && cues.isEmpty && liveCaption == nil && !(s.captionTracksKnown && s.captionTracks.isEmpty)
            && recentRequest(t.videoId) == nil
        let tries = autoCaptionTried[t.videoId] ?? 0
        guard needs, tries < 2 else { autoCaptionWork?.cancel(); autoCaptionWork = nil; return }
        guard autoCaptionWork == nil else { return }
        if tries == 0 { setLoading(true) } // shown from the start; cleared when text arrives or nothing does
        let key = s.key, vid = t.videoId
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoCaptionWork = nil
            guard self.autoCaptions, let a = self.store.active, a.key == key, a.track?.videoId == vid,
                  a.isPlaying, !(a.track?.isAd ?? false), self.cues.isEmpty, self.liveCaption == nil else { return }
            guard self.recentRequest(vid) == nil else { return }
            self.autoCaptionTried[vid, default: 0] += 1
            if self.autoCaptionTried.count > 64 { self.autoCaptionTried = [vid: self.autoCaptionTried[vid]!] }
            self.connectCaptions()
            // Re-arm for the second attempt if the first one yields nothing.
            if let a = self.store.active, let t = a.track { self.scheduleAutoCaptions(a, t) }
        }
        autoCaptionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 2 : 6), execute: work)
    }

    // MARK: Lyrics (LRCLIB, looked up by the app for YouTube Music, Spotify and Apple Music)

    static let lyricsSites: Set<String> = ["ytm", "spotify", "music"]

    private func lyricsQuery(_ t: TrackInfo) -> LyricsQuery? {
        guard Self.lyricsSites.contains(t.site), !(t.isAd ?? false), !t.title.isEmpty, !t.artist.isEmpty,
              let d = t.duration, d > 0 else { return nil }
        return LyricsQuery(title: t.title, artist: t.artist, album: t.album, duration: d)
    }

    /// Once per song; skipped when the page already sent synced lyrics of its own.
    private func scheduleLyrics(_ s: TabState, _ t: TrackInfo) {
        let ident = "\(s.key)|\(t.videoId)"
        guard lyricsFor != ident else { return }
        guard let q = lyricsQuery(t) else { return } // duration may arrive later: try again then
        // A page reports its own text first (YouTube Music sends an empty placeholder); wait for that,
        // so lyrics the page already has are never raced. Spotify/Music have no text of their own.
        let fromPage = s.key.conn != NativePlayers.conn
        if fromPage, s.cueSet?.videoId != t.videoId { return }
        if let cs = s.cueSet, cs.videoId == t.videoId, cs.synced, !cs.cues.isEmpty, cs.source != "lrclib" { return }
        lyricsFor = ident
        lyricsRetries = 0
        assign(\.lyricsCandidates, [])
        assign(\.lyricsChosenID, nil)
        runLyrics(q, key: s.key, vid: t.videoId, delay: 0)
    }

    private func runLyrics(_ q: LyricsQuery, key: TabKey, vid: String, delay: Double) {
        lyricsTask?.cancel()
        assign(\.lyricsSearching, delay == 0)
        lyricsTask = Task { [weak self, lyricsService] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.assign(\.lyricsSearching, true) }
            let outcome = await lyricsService.lookup(q)
            guard !Task.isCancelled, let self, self.lyricsFor == "\(key)|\(vid)" else { return }
            self.assign(\.lyricsSearching, false)
            switch outcome {
            case let .found(cues, chosen, candidates):
                self.assign(\.lyricsCandidates, candidates)
                self.assign(\.lyricsChosenID, chosen)
                self.applyLyrics(cues, key: key, vid: vid)
            case let .notFound(candidates):
                self.assign(\.lyricsCandidates, candidates)
            case .transient:
                // Offline or LRCLIB busy: try again in 20 s, then 60 s.
                guard self.lyricsRetries < 2 else { return }
                let wait = [20.0, 60.0][self.lyricsRetries]
                self.lyricsRetries += 1
                self.runLyrics(q, key: key, vid: vid, delay: wait)
            }
        }
    }

    private func applyLyrics(_ cues: [Cue], key: TabKey, vid: String) {
        let set = CueSet(videoId: vid, source: "lrclib", lang: nil, kind: "lyrics", synced: true, cues: cues)
        if store.apply(.cues(tab: key.tab, seq: nil, set), conn: key.conn, now: Self.now) { refresh() }
    }

    /// Shows another LRCLIB version for this song (remembered), or none.
    func chooseLyrics(_ id: Int?) {
        guard let s = store.active, let t = s.track, let q = lyricsQuery(t) else { return }
        let key = s.key, vid = t.videoId
        lyricsTask?.cancel()
        assign(\.lyricsSearching, id != nil)
        lyricsTask = Task { [weak self, lyricsService] in
            let cues = await lyricsService.choose(id, for: q)
            guard !Task.isCancelled, let self, self.store.active?.track?.videoId == vid else { return }
            self.assign(\.lyricsSearching, false)
            if id != nil, cues == nil { return } // fetch failed: keep what is shown
            self.assign(\.lyricsChosenID, id)
            self.applyLyrics(cues ?? [], key: key, vid: vid)
        }
    }

    /// Shows an .lrc file for this song (remembered). Returns false when the file has no timed lines.
    func importLyrics(_ text: String) async -> Bool {
        guard let s = store.active, let t = s.track, let q = lyricsQuery(t) else { return false }
        let key = s.key, vid = t.videoId
        lyricsTask?.cancel()
        guard let cues = await lyricsService.importLRC(text, for: q), store.active?.track?.videoId == vid else { return false }
        assign(\.lyricsChosenID, LyricsService.importedID)
        applyLyrics(cues, key: key, vid: vid)
        return true
    }

    /// Drops the cached result and asks LRCLIB again.
    func searchLyricsAgain() {
        guard let t = store.active?.track, let q = lyricsQuery(t) else { return }
        Task { [weak self, lyricsService] in
            await lyricsService.forget(q)
            guard let self else { return }
            self.lyricsFor = nil
            self.refresh()
        }
    }

    var lyricsAvailable: Bool { store.active?.track.flatMap(lyricsQuery) != nil }

    // MARK: Debug (defaults write dev.jiun.subline debugDump -bool true)

    @ObservationIgnored private static let debugDump = UserDefaults.standard.bool(forKey: "debugDump")
    @ObservationIgnored private var lastDumpAt: Double = 0

    private func dumpState() {
        let s = store.active
        let obj: [String: Any] = [
            "title": title, "artist": artist, "site": site ?? "", "isAd": isAd, "isPlaying": isPlaying,
            "artwork": artwork != nil, "artworkURL": s?.track?.artwork.first?.url ?? "",
            "cueSource": cueSource ?? "", "cueCount": cues.count, "synced": synced,
            "position": position(), "currentLine": currentLine ?? "", "tabs": store.tabs.count,
            "connections": connectionCount,
            "captionTracks": captionTracks.map(\.id), "captionTrackID": captionTrackID ?? "",
            "textStatus": "\(textStatus)", "captionsLoading": captionsLoading,
            "secondaryTrackID": secondaryTrackID ?? "", "derivedNote": derivedNote ?? "", "preferredSecondary": preferredSecondaryID ?? "", "secondaryCount": secondaryCues.count, "secondaryLine": secondaryLine ?? "",
            "extensionOutdated": extensionOutdated.map { "\($0.running)<\($0.bundled)" } ?? "",
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: SublinePaths.supportDir.appendingPathComponent("debug-state.json"), options: .atomic)
        }
    }

    /// Updates the active cue and arms a single timer for the next cue boundary.
    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard let s = store.active, let clock = s.clock, !isAd else {
            assign(\.activeIndex, nil)
            assign(\.upcomingIndex, nil)
            return
        }
        guard showingText else { return } // nothing to draw; resume on show
        let now = Self.now
        let position = clock.position(at: now)
        let mediaT = position - captionOffset
        let newIndex = s.timeline.activeIndex(at: mediaT)
        if newIndex != activeIndex, newIndex != nil {
            let now = Self.now
            // Hysteresis: fast below 2 s, slow again only after a 3.5 s gap.
            let gap = now - lastLineChangeAt
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { assign(\.fastLines, true) }
            else if gap < 2 { assign(\.fastLines, true) } else if gap > 3.5 { assign(\.fastLines, false) }
            lastLineChangeAt = now
        }
        assign(\.activeIndex, newIndex)
        assign(\.upcomingIndex, s.timeline.upcomingIndex(at: mediaT))
        assign(\.secondaryActiveIndex, secondaryCues.isEmpty ? nil : s.secondaryTimeline.activeIndex(at: mediaT))
        // Stop at the end of media; never re-arm for a deadline that already passed.
        if let d = clock.duration, d > 0, position >= d { return }
        let boundaries = [s.timeline.nextBoundary(after: mediaT),
                          secondaryCues.isEmpty ? nil : s.secondaryTimeline.nextBoundary(after: mediaT)].compactMap { $0 }
        guard let boundary = boundaries.min(),
              let wall = clock.wallTime(forMedia: boundary + captionOffset), wall > now - 0.05 else { return }
        let delay = max(0.01, wall - now + 0.005)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(15))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        t.resume()
        timer = t
    }

    private func loadArtwork(_ t: TrackInfo) {
        let key = t.artwork.map(\.url).joined(separator: "\n")
        guard key != artworkKey else { return }
        if let failed = artworkFailedAt[key], Self.now - failed < 30 { return } // back off on failures
        artworkKey = key
        artworkTask?.cancel()
        let urls = t.artwork.map(\.url)
        artworkTask = Task { [weak self, artworkLoader] in
            let result = await artworkLoader.load(urls: urls)
            guard !Task.isCancelled, let self, self.artworkKey == key else { return }
            if result == nil, !urls.isEmpty {
                self.artworkFailedAt[key] = Self.now
                self.artworkKey = nil // allow a later retry or improved candidate list
                if self.artworkFailedAt.count > 32 { self.artworkFailedAt.removeAll() }
            }
            self.artworkShownKey = result == nil ? nil : key
            withAnimation(.easeInOut(duration: 0.45)) {
                self.artwork = result?.image
                self.accent = result.map { Color(nsColor: $0.accent) } ?? Color(white: 0.35)
            }
        }
    }
}
