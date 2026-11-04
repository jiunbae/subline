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
        }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}
