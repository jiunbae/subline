import Foundation

public struct Artwork: Codable, Sendable, Equatable {
    public var url: String
    public var w: Int?
    public var h: Int?
    public init(url: String, w: Int? = nil, h: Int? = nil) { self.url = url; self.w = w; self.h = h }
}

public struct Cue: Codable, Sendable, Equatable {
    public var s: Double
    public var e: Double?
    public var text: String
    public init(s: Double, e: Double? = nil, text: String) { self.s = s; self.e = e; self.text = text }
}

public struct TrackInfo: Codable, Sendable, Equatable {
    public var site: String
    public var videoId: String
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: Double?
    public var artwork: [Artwork]
    public var isAd: Bool?
}

public struct ClockInfo: Codable, Sendable, Equatable {
    public var videoId: String
    public var t: Double
    public var rate: Double
    public var paused: Bool
    public var buffering: Bool?
}

public struct CueSet: Codable, Sendable, Equatable {
    public var videoId: String
    public var source: String
    public var lang: String?
    public var kind: String
    public var synced: Bool
    public var cues: [Cue]
    /// 2 for the secondary ("sub") caption track; nil/1 for the main text.
    public var slot: Int?
    public init(videoId: String, source: String, lang: String?, kind: String, synced: Bool, cues: [Cue], slot: Int? = nil) {
        self.videoId = videoId; self.source = source; self.lang = lang; self.kind = kind
        self.synced = synced; self.cues = cues; self.slot = slot
    }
    public var isSecondary: Bool { slot == 2 }
}

/// One caption track the YouTube player offers for the current video.
public struct CaptionTrack: Codable, Sendable, Equatable, Identifiable {
    /// `lang` plus ":asr" for auto-generated tracks, e.g. "en", "en:asr".
    public var id: String
    public var lang: String
    public var name: String
    public var kind: String? // "asr" for auto-generated
    public init(id: String, lang: String, name: String, kind: String? = nil) {
        self.id = id; self.lang = lang; self.name = name; self.kind = kind
    }
    public var isAuto: Bool { kind == "asr" }

    /// Best track for a remembered choice: exact id, else the same language (then the same base
    /// language, e.g. "en" for "en-GB"), preferring manual tracks over auto-generated ones.
    public static func best(for preferred: String?, in tracks: [CaptionTrack]) -> CaptionTrack? {
        guard let preferred, !tracks.isEmpty else { return nil }
        if let exact = tracks.first(where: { $0.id == preferred }) { return exact }
        let lang = preferred.replacingOccurrences(of: ":asr", with: "")
        let base = lang.split(separator: "-").first.map(String.init) ?? lang
        let sameLang = tracks.filter { $0.lang == lang }
        let sameBase = tracks.filter { $0.lang != lang && ($0.lang == base || $0.lang.hasPrefix(base + "-")) }
        let candidates = sameLang + sameBase
        return candidates.first(where: { !$0.isAuto }) ?? candidates.first
    }
}

public struct CaptionTrackList: Codable, Sendable, Equatable {
    public var videoId: String
    public var tracks: [CaptionTrack]
}

extension CueSet {
    /// Caption track id of this set (matches `CaptionTrack.id`), nil for lyrics.
    public var trackID: String? {
        guard source == "yt-captions", let lang, !lang.isEmpty else { return nil }
        return kind == "asr" ? "\(lang):asr" : lang
    }
}

public struct LiveCaption: Codable, Sendable, Equatable {
    public var videoId: String
    public var text: String
}

public enum Incoming: Sendable, Equatable {
    case hello(ext: String?)
    case track(tab: Int, seq: Int?, TrackInfo)
    case clock(tab: Int, seq: Int?, ClockInfo)
    case cues(tab: Int, seq: Int?, CueSet)
    case liveCaption(tab: Int, seq: Int?, LiveCaption)
    case captionTracks(tab: Int, seq: Int?, CaptionTrackList)
    case gone(tab: Int)
    case unknown(String)

    private struct Envelope: Decodable {
        var v: Int?
        var type: String
        var tabId: Int?
        var seq: Int?
        var ext: String?
    }

    public enum ParseError: Error { case missingTab, unsupportedVersion(Int) }

    public static func parse(_ data: Data) throws -> Incoming {
        let dec = JSONDecoder()
        let env = try dec.decode(Envelope.self, from: data)
        if let v = env.v, v != 1 { throw ParseError.unsupportedVersion(v) }
        func tab() throws -> Int {
            guard let t = env.tabId else { throw ParseError.missingTab }
            return t
        }
        switch env.type {
        case "hello": return .hello(ext: env.ext)
        case "track": return .track(tab: try tab(), seq: env.seq, try dec.decode(TrackInfo.self, from: data))
        case "clock": return .clock(tab: try tab(), seq: env.seq, try dec.decode(ClockInfo.self, from: data))
        case "cues": return .cues(tab: try tab(), seq: env.seq, try dec.decode(CueSet.self, from: data))
        case "liveCaption": return .liveCaption(tab: try tab(), seq: env.seq, try dec.decode(LiveCaption.self, from: data))
        case "captionTracks": return .captionTracks(tab: try tab(), seq: env.seq, try dec.decode(CaptionTrackList.self, from: data))
        case "gone": return .gone(tab: try tab())
        default: return .unknown(env.type)
        }
    }
}

public enum Outgoing: Sendable, Equatable {
    case cmd(tab: Int, action: String, t: Double? = nil)
    case visibility(Bool)
    case requestSnapshot
    case connectCaptions(tab: Int)
    /// slot 1 = main text, 2 = secondary; an empty trackID with slot 2 turns the secondary off.
    case selectCaptions(tab: Int, trackID: String, slot: Int = 1)

    public func json() -> Data {
        var obj: [String: Any] = ["v": 1]
        switch self {
        case let .cmd(tab, action, t):
            obj["type"] = "cmd"; obj["tabId"] = tab; obj["action"] = action
            if let t { obj["t"] = t }
        case let .visibility(v):
            obj["type"] = "visibility"; obj["visible"] = v
        case .requestSnapshot:
            obj["type"] = "requestSnapshot"
        case let .connectCaptions(tab):
            obj["type"] = "connectCaptions"; obj["tabId"] = tab
        case let .selectCaptions(tab, trackID, slot):
            obj["type"] = "selectCaptions"; obj["tabId"] = tab; obj["trackId"] = trackID; obj["slot"] = slot
        }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}
