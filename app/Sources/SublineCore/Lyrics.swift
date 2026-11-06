import Foundation

/// What we know about a song when looking up lyrics.
public struct LyricsQuery: Hashable, Codable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: Double
    public init(title: String, artist: String, album: String?, duration: Double) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
    }

    /// Stable key for caches and remembered choices (duration rounded: players disagree by a second).
    public var cacheKey: String {
        [Lyrics.normalize(title), Lyrics.normalize(artist), String(Int(duration.rounded()))].joined(separator: "|")
    }

    /// The query and, when different, one with localized/decorative suffixes removed, e.g.
    /// "The Chainsmokers(체인스모커스)", "Song (Official Audio)", "Artist - Topic".
    public var attempts: [LyricsQuery] {
        let cleaned = LyricsQuery(title: Lyrics.clean(title).isEmpty ? title : Lyrics.clean(title),
                                  artist: Lyrics.clean(artist).isEmpty ? artist : Lyrics.clean(artist),
                                  album: album, duration: duration)
        return cleaned == self ? [self] : [self, cleaned]
    }
}

/// One LRCLIB entry offered as a lyrics version.
public struct LyricsCandidate: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var duration: Double
    public init(id: Int, trackName: String, artistName: String, albumName: String?, duration: Double) {
        self.id = id; self.trackName = trackName; self.artistName = artistName; self.albumName = albumName; self.duration = duration
    }
}

/// An LRCLIB record as returned by /api/get and /api/search.
public struct LRCLIBRecord: Codable, Sendable, Equatable {
    public var id: Int
    public var trackName: String?
    public var artistName: String?
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool?
    public var syncedLyrics: String?

    public var candidate: LyricsCandidate {
        LyricsCandidate(id: id, trackName: trackName ?? "", artistName: artistName ?? "", albumName: albumName, duration: duration ?? 0)
    }
    public var hasSynced: Bool { !(instrumental ?? false) && !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum Lyrics {
    /// Lowercased letters and digits only, for loose comparisons.
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }

    /// Drops bracketed decorations and the YouTube "- Topic" artist suffix.
    public static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*[(\[（【][^)\]）】]*[)\]）】]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+-\s+Topic$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Parses LRC ("[mm:ss.xx] line", several tags per line allowed, optional [offset:±ms]).
    /// Lines are sorted, blank lines kept as instrumental gaps, and each cue ends where the next begins.
    public static func parseLRC(_ text: String, duration: Double?) -> [Cue] {
        var offset = 0.0
        if let r = text.range(of: #"\[offset:\s*([+-]?\d+)\]"#, options: [.regularExpression, .caseInsensitive]) {
            let digits = text[r].filter { $0.isNumber || $0 == "-" || $0 == "+" }
            offset = (Double(digits) ?? 0) / 1000
        }
        let tag = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        let anyTag = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
        var cues: [Cue] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let lyric = anyTag.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                guard sec < 60 else { continue }
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                // [offset:+n] means the lyrics come n ms sooner.
                cues.append(Cue(s: max(0, min * 60 + sec + frac - offset), text: lyric))
            }
        }
        cues.sort { $0.s < $1.s }
        // Drop exact duplicates (same time and text) and leading blank lines.
        var out: [Cue] = []
        for c in cues {
            if let last = out.last, last.s == c.s, last.text == c.text { continue }
            if out.isEmpty && c.text.isEmpty { continue }
            out.append(c)
        }
        for i in out.indices {
            let end = i + 1 < out.count ? out[i + 1].s : duration
            if let end, end > out[i].s { out[i].e = end }
        }
        return out
    }

    /// Search results worth offering: synced, same song by identity (artist compatible, title equal
    /// or containing the other), within ±10 s; best first (exact title, then closest length).
    public static func rankCandidates(_ records: [LRCLIBRecord], for q: LyricsQuery, limit: Int = 8) -> [LRCLIBRecord] {
        let t = normalize(clean(q.title).isEmpty ? q.title : clean(q.title)), a = normalize(clean(q.artist).isEmpty ? q.artist : clean(q.artist))
        func compatible(_ x: String, _ y: String) -> Bool { !x.isEmpty && !y.isEmpty && (x == y || x.contains(y) || y.contains(x)) }
        func score(_ r: LRCLIBRecord) -> Double {
            (normalize(r.trackName ?? "") == t ? 4 : 0) - abs((r.duration ?? 0) - q.duration) / 3
        }
        return records.filter { r in
            r.hasSynced && (r.syncedLyrics?.count ?? 0) < 500_000 && abs((r.duration ?? .infinity) - q.duration) <= 10
                && compatible(normalize(r.artistName ?? ""), a) && compatible(normalize(r.trackName ?? ""), t)
        }
        .sorted { score($0) > score($1) }
        .prefix(limit).map { $0 }
    }

    /// The record to show automatically: the exact match, else the best search result within ±3 s.
    public static func autoPick(exact: LRCLIBRecord?, ranked: [LRCLIBRecord], for q: LyricsQuery) -> LRCLIBRecord? {
        if let e = exact, e.hasSynced, abs((e.duration ?? .infinity) - q.duration) <= 3 { return e }
        return ranked.first { abs(($0.duration ?? .infinity) - q.duration) <= 3 }
    }
}
