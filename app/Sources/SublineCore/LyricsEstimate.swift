import Foundation

/// Where untimed lyrics probably are, from the playback position alone.
///
/// Works per stanza, not per line: a line-level guess is wrong often enough to distract, a stanza
/// guess is usually right. Stanzas are the blank-line separated blocks; a long block without blank
/// lines is cut into chunks of four. Each line weighs by its length, each stanza break adds a pause,
/// and the song's first and last few seconds are left to the intro and outro.
public struct LyricsEstimate: Sendable, Equatable {
    /// Cue index ranges of the stanzas (blank lines excluded), in order.
    public let stanzas: [Range<Int>]
    /// Estimated media time at which each stanza starts.
    public let starts: [Double]

    static let chunk = 4, longBlock = 8
    static let pauseWeight = 1.0

    /// nil when there is nothing to place: no duration, a very short track, or a single stanza.
    public init?(lines: [String], duration: Double) {
        guard duration >= 30 else { return nil }
        var blocks: [Range<Int>] = []
        var start: Int?
        for (i, line) in lines.enumerated() {
            let blank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank, let s = start { blocks.append(s..<i); start = nil }
            if !blank, start == nil { start = i }
        }
        if let s = start { blocks.append(s..<lines.count) }

        var stanzas: [Range<Int>] = []
        for b in blocks {
            guard b.count > Self.longBlock else { stanzas.append(b); continue }
            var lo = b.lowerBound
            while lo < b.upperBound {
                var hi = min(lo + Self.chunk, b.upperBound)
                if b.upperBound - hi < 2 { hi = b.upperBound } // no one-line tail chunk
                stanzas.append(lo..<hi)
                lo = hi
            }
        }
        guard stanzas.count >= 2 else { return nil }

        func weight(_ line: String) -> Double {
            1 + Double(min(line.filter { !$0.isWhitespace }.count, 60)) / 15
        }
        let weights = stanzas.map { r in r.reduce(0.0) { $0 + weight(lines[$1]) } }
        let total = weights.reduce(0, +) + Self.pauseWeight * Double(stanzas.count - 1)
        let edge = min(20, duration * 0.08)
        let span = duration - 2 * edge
        var acc = 0.0, starts: [Double] = []
        for (k, w) in weights.enumerated() {
            starts.append(edge + span * acc / total)
            acc += w + (k < weights.count - 1 ? Self.pauseWeight : 0)
        }
        self.stanzas = stanzas
        self.starts = starts
    }

    /// The stanza probably being sung at media time t; nil during the intro.
    public func stanza(at t: Double) -> Int? {
        guard let first = starts.first, t >= first else { return nil }
        return (starts.lastIndex { $0 <= t })
    }

    /// Next media time at which `stanza(at:)` changes.
    public func nextBoundary(after t: Double) -> Double? {
        starts.first { $0 > t }
    }
}
