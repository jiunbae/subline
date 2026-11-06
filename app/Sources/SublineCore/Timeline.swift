import Foundation

/// Interpolates playback position from the last clock sample using a monotonic time base.
public struct PlaybackClock: Sendable, Equatable {
    public var t: Double
    public var rate: Double
    public var paused: Bool
    public var buffering: Bool
    public var anchor: Double // monotonic seconds when sample was received
    public var duration: Double?

    public init(t: Double, rate: Double, paused: Bool, buffering: Bool, anchor: Double, duration: Double? = nil) {
        self.t = t; self.rate = rate; self.paused = paused; self.buffering = buffering
        self.anchor = anchor; self.duration = duration
    }

    public var isAdvancing: Bool { !paused && !buffering && rate > 0 }

    public func position(at now: Double) -> Double {
        var p = isAdvancing ? t + max(0, now - anchor) * rate : t
        if let d = duration, d > 0 { p = min(p, d) }
        return max(0, p)
    }

    /// Monotonic time at which media time `mediaT` will be reached, if advancing and reachable
    /// (i.e. not beyond the media duration).
    public func wallTime(forMedia mediaT: Double) -> Double? {
        guard isAdvancing else { return nil }
        if let d = duration, d > 0, mediaT > d { return nil }
        return anchor + (mediaT - t) / rate
    }
}

/// Sorted cue list with O(log n) lookup.
public struct CueTimeline: Sendable, Equatable {
    public let cues: [Cue]
    public let synced: Bool

    public init(cues: [Cue], synced: Bool) {
        self.cues = cues.sorted { $0.s < $1.s }
        self.synced = synced
    }

    public static let empty = CueTimeline(cues: [], synced: false)

    /// Index of the last cue with s <= t, or nil.
    func lastStarted(at t: Double) -> Int? {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].s <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Active cue at time t. A cue with an end time is inactive after it ends;
    /// a cue without an end time stays active until the next cue starts.
    public func activeIndex(at t: Double) -> Int? {
        guard synced, let i = lastStarted(at: t) else { return nil }
        if let e = cues[i].e, t >= e { return nil }
        return i
    }

    /// The first cue that has not started yet at time t (the "next line" preview), or nil.
    public func upcomingIndex(at t: Double) -> Int? {
        guard synced else { return nil }
        let n = (lastStarted(at: t) ?? -1) + 1
        return n < cues.count ? n : nil
    }

    /// Next media time at which `activeIndex` may change.
    public func nextBoundary(after t: Double) -> Double? {
        guard synced, !cues.isEmpty else { return nil }
        var candidates: [Double] = []
        let i = lastStarted(at: t)
        let nextIdx = (i ?? -1) + 1
        if nextIdx < cues.count { candidates.append(cues[nextIdx].s) }
        if let i, let e = cues[i].e, e > t { candidates.append(e) }
        return candidates.min()
    }
}
