import AppKit
import SwiftUI
import Observation
import NowPlayingCore

enum OverlayLayout: String, CaseIterable, Identifiable {
    case cover, coverLine, lyrics, mini
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cover: "Cover"
        case .coverLine: "Cover + Line"
        case .lyrics: "Lyrics"
        case .mini: "Mini"
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
    private(set) var liveCaption: String?

    // Environment
    private(set) var connectionCount = 0
    var hovering = false
    var clickThrough = false
    var layout: OverlayLayout = OverlayLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .coverLine {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "layout") }
    }
    var opacity: Double = UserDefaults.standard.object(forKey: "opacity") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(opacity, forKey: "opacity") }
    }
    /// When a YouTube video has no captions yet, briefly toggle CC so the player fetches them.
    var autoCaptions: Bool = UserDefaults.standard.object(forKey: "autoCaptions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCaptions, forKey: "autoCaptions"); refresh() }
    }
    /// Caption delay in seconds: positive shows text later, negative earlier.
    var captionOffset: Double = 0 { didSet { reschedule() } }

    @ObservationIgnored private(set) var store = SessionStore()
    @ObservationIgnored var send: ((Outgoing, Int?) -> Void)?
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var panelVisible = true
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var artworkFailedAt: [String: Double] = [:]
    @ObservationIgnored private var currentVideo: String?
    @ObservationIgnored private var autoCaptionTried: [String: Int] = [:]
    @ObservationIgnored private var autoCaptionWork: DispatchWorkItem?
    @ObservationIgnored private let artworkLoader = ArtworkLoader()
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

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
        refresh()
    }

    func handle(conn: Int, _ msg: Incoming) {
        if store.apply(msg, conn: conn, now: Self.now) { refresh() }
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

    func connectCaptions() {
        guard let k = store.activeKey else { return }
        send?(.connectCaptions(tab: k.tab), k.conn)
    }

    func setVisible(_ visible: Bool) {
        panelVisible = visible
        send?(.visibility(visible), nil)
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
            assign(\.liveCaption, nil)
            timer?.cancel()
            return
        }
        if currentVideo != t.videoId {
            currentVideo = t.videoId
            if captionOffset != 0 { captionOffset = 0 }
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
        assign(\.synced, cueSet?.synced ?? false)
        assign(\.cueSource, cueSet?.source)
        assign(\.liveCaption, (t.isAd ?? false) ? nil : s.liveCaption)
        loadArtwork(t)
        reschedule()
        scheduleAutoCaptions(s, t)
        if Self.debugDump { dumpState() }
    }

    // MARK: Auto captions

    /// Up to two attempts per video (2 s and 8 s after playback starts), only while nothing is shown.
    private func scheduleAutoCaptions(_ s: TabState, _ t: TrackInfo) {
        let needs = autoCaptions && t.site == "yt" && !(t.isAd ?? false) && s.isPlaying
            && cues.isEmpty && liveCaption == nil
        let tries = autoCaptionTried[t.videoId] ?? 0
        guard needs, tries < 2 else { autoCaptionWork?.cancel(); autoCaptionWork = nil; return }
        guard autoCaptionWork == nil else { return }
        let key = s.key, vid = t.videoId
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoCaptionWork = nil
            guard self.autoCaptions, let a = self.store.active, a.key == key, a.track?.videoId == vid,
                  a.isPlaying, !(a.track?.isAd ?? false), self.cues.isEmpty, self.liveCaption == nil else { return }
            self.autoCaptionTried[vid, default: 0] += 1
            if self.autoCaptionTried.count > 64 { self.autoCaptionTried = [vid: self.autoCaptionTried[vid]!] }
            self.send?(.connectCaptions(tab: key.tab), key.conn)
            // Re-arm for the second attempt if the first one yields nothing.
            if let a = self.store.active, let t = a.track { self.scheduleAutoCaptions(a, t) }
        }
        autoCaptionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 2 : 6), execute: work)
    }

    // MARK: Debug (defaults write com.nowplaying.app debugDump -bool true)

    @ObservationIgnored private static let debugDump = UserDefaults.standard.bool(forKey: "debugDump")

    private func dumpState() {
        let s = store.active
        let obj: [String: Any] = [
            "title": title, "artist": artist, "site": site ?? "", "isAd": isAd, "isPlaying": isPlaying,
            "artwork": artwork != nil, "artworkURL": s?.track?.artwork.first?.url ?? "",
            "cueSource": cueSource ?? "", "cueCount": cues.count, "synced": synced,
            "position": position(), "currentLine": currentLine ?? "", "tabs": store.tabs.count,
            "connections": connectionCount,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: NPPaths.supportDir.appendingPathComponent("debug-state.json"), options: .atomic)
        }
    }

    /// Updates the active cue and arms a single timer for the next cue boundary.
    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard let s = store.active, let clock = s.clock, !isAd else {
            assign(\.activeIndex, nil)
            return
        }
        guard panelVisible else { return } // nothing to draw; resume on show
        let now = Self.now
        let position = clock.position(at: now)
        let mediaT = position - captionOffset
        assign(\.activeIndex, s.timeline.activeIndex(at: mediaT))
        // Stop at the end of media; never re-arm for a deadline that already passed.
        if let d = clock.duration, d > 0, position >= d { return }
        guard let boundary = s.timeline.nextBoundary(after: mediaT),
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
            withAnimation(.easeInOut(duration: 0.45)) {
                self.artwork = result?.image
                self.accent = result.map { Color(nsColor: $0.accent) } ?? Color(white: 0.35)
            }
        }
    }
}
