import Foundation

public struct TabKey: Hashable, Sendable, CustomStringConvertible {
    public let conn: Int
    public let tab: Int
    public init(conn: Int, tab: Int) { self.conn = conn; self.tab = tab }
    public var description: String { "\(conn):\(tab)" }
}

public struct TabState: Sendable, Equatable {
    public let key: TabKey
    public var track: TrackInfo?
    public var clock: PlaybackClock?
    public var cueSet: CueSet?
    public var timeline: CueTimeline = .empty
    public var liveCaption: String?
    public var lastSeq: Int = Int.min
    public var lastActivity: Double = 0
    public var startedAt: Double = 0 // last paused→playing transition

    public var isPlaying: Bool { clock.map { !$0.paused } ?? false }
}

/// Pure state machine for all known tabs across host connections.
public struct SessionStore: Sendable {
    public private(set) var tabs: [TabKey: TabState] = [:]
    public var pinned: TabKey?

    public init() {}

    /// Applies a message. Returns true when observable state changed.
    @discardableResult
    public mutating func apply(_ msg: Incoming, conn: Int, now: Double) -> Bool {
        switch msg {
        case .hello:
            // New extension session on this connection: seq restarts.
            for k in tabs.keys where k.conn == conn { tabs[k]?.lastSeq = Int.min }
            return false
        case .unknown:
            return false
        case let .gone(tab):
            let k = TabKey(conn: conn, tab: tab)
            if pinned == k { pinned = nil }
            return tabs.removeValue(forKey: k) != nil
        case let .track(tab, seq, info):
            return mutate(TabKey(conn: conn, tab: tab), seq: seq, now: now) { s in
                if s.track?.videoId != info.videoId {
                    // New video: nothing from the previous one may leak (clock, cues, captions).
                    s.cueSet = nil; s.timeline = .empty; s.liveCaption = nil
                    s.clock = nil; s.startedAt = 0
                }
                s.track = info
                if let d = info.duration { s.clock?.duration = d }
            }
        case let .clock(tab, seq, c):
            return mutate(TabKey(conn: conn, tab: tab), seq: seq, now: now, videoId: c.videoId) { s in
                let wasPlaying = s.isPlaying
                s.clock = PlaybackClock(t: c.t, rate: c.rate, paused: c.paused,
                                        buffering: c.buffering ?? false, anchor: now,
                                        duration: s.track?.duration)
                if !c.paused && !wasPlaying { s.startedAt = now }
            }
        case let .cues(tab, seq, set):
            return mutate(TabKey(conn: conn, tab: tab), seq: seq, now: now, videoId: set.videoId) { s in
                s.cueSet = set
                s.timeline = CueTimeline(cues: set.cues, synced: set.synced)
            }
        case let .liveCaption(tab, seq, lc):
            return mutate(TabKey(conn: conn, tab: tab), seq: seq, now: now, videoId: lc.videoId) { s in
                s.liveCaption = lc.text.isEmpty ? nil : lc.text
            }
        }
    }

    /// Applies `f` if `seq` is fresh and, for per-video messages, `videoId` matches the current track.
    private mutating func mutate(_ k: TabKey, seq: Int?, now: Double, videoId: String? = nil,
                                 _ f: (inout TabState) -> Void) -> Bool {
        var s = tabs[k] ?? TabState(key: k)
        if let videoId, let current = s.track?.videoId, current != videoId { return false }
        if let seq {
            guard seq > s.lastSeq else { return false }
            s.lastSeq = seq
        }
        let before = s
        f(&s)
        s.lastActivity = now
        tabs[k] = s
        // Clock-only ticks always "change" (anchor moves); callers can diff further.
        return s != before
    }

    public mutating func removeConnection(_ conn: Int) {
        tabs = tabs.filter { $0.key.conn != conn }
        if pinned?.conn == conn { pinned = nil }
    }

    /// Pinned tab, else most recently started playing tab, else most recently active tab.
    public var activeKey: TabKey? {
        if let p = pinned, tabs[p] != nil { return p }
        let withTrack = tabs.values.filter { $0.track != nil }
        if let playing = withTrack.filter(\.isPlaying).max(by: { $0.startedAt < $1.startedAt }) {
            return playing.key
        }
        return withTrack.max(by: { $0.lastActivity < $1.lastActivity })?.key
    }

    public var active: TabState? { activeKey.flatMap { tabs[$0] } }
}
