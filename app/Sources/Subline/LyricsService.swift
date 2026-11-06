import Foundation
import SublineCore

/// Time-synced lyrics from LRCLIB (lrclib.net), with an on-disk cache so songs heard before work
/// offline and a chosen version sticks. Only title, artist, album and length are sent, no cookies.
actor LyricsService {
    enum Outcome: Sendable {
        case found(cues: [Cue], chosen: Int, candidates: [LyricsCandidate])
        case notFound(candidates: [LyricsCandidate])
        /// Network or server trouble; nothing was cached, try again later.
        case transient
    }

    /// One cached song: the version shown (with its LRC, so it works offline) and the alternatives.
    private struct Entry: Codable {
        var chosen: Int?
        var lrc: String?
        var candidates: [LyricsCandidate]
        var at: Date
        /// Set when the user picked "No Lyrics" for this song.
        var hidden: Bool?
        /// The user's own .lrc for this song, kept even when another version is shown.
        var imported: String?
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 8
        c.httpAdditionalHeaders = ["User-Agent": "Subline/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") (macOS; https://github.com/jiunbae/subline)"]
        return URLSession(configuration: c)
    }()
    private var memory: [String: Entry] = [:]
    private static let negativeTTL: TimeInterval = 24 * 3600
    private static let maxFiles = 800
    private static let maxSearchBytes = 4_000_000

    private var dir: URL { SublinePaths.supportDir.appendingPathComponent("lyrics", isDirectory: true) }

    // MARK: Public

    func lookup(_ q: LyricsQuery) async -> Outcome {
        if let e = entry(q.cacheKey) {
            if e.hidden == true { return .notFound(candidates: withImported(e, q)) }
            if let lrc = e.lrc, let id = e.chosen {
                let cues = Lyrics.parseLRC(lrc, duration: q.duration)
                if !cues.isEmpty { return .found(cues: cues, chosen: id, candidates: withImported(e, q)) }
            } else if Date().timeIntervalSince(e.at) < Self.negativeTTL {
                return .notFound(candidates: withImported(e, q))
            }
        }
        var transient = false
        var exact: LRCLIBRecord?
        for attempt in q.attempts {
            switch await get(attempt) {
            case let .success(r?): exact = r
            case .success(nil): break
            case .failure: transient = true
            }
            if exact?.hasSynced == true { break }
        }
        var ranked: [LRCLIBRecord] = []
        switch await search(q) {
        case let .success(list): ranked = Lyrics.rankCandidates(list, for: q)
        case .failure: transient = true
        }
        var candidates = ranked.map(\.candidate)
        if let e = exact, e.hasSynced, !candidates.contains(where: { $0.id == e.id }) { candidates.insert(e.candidate, at: 0) }
        if let pick = Lyrics.autoPick(exact: exact, ranked: ranked, for: q), let lrc = pick.syncedLyrics {
            let cues = Lyrics.parseLRC(lrc, duration: q.duration)
            if !cues.isEmpty {
                var fresh = Entry(chosen: pick.id, lrc: lrc, candidates: candidates, at: Date())
                fresh.imported = entry(q.cacheKey)?.imported
                save(q.cacheKey, fresh)
                return .found(cues: cues, chosen: pick.id, candidates: withImported(fresh, q))
            }
        }
        if transient && candidates.isEmpty { return .transient }
        var none = Entry(chosen: nil, lrc: nil, candidates: candidates, at: Date())
        none.imported = entry(q.cacheKey)?.imported
        save(q.cacheKey, none)
        return .notFound(candidates: withImported(none, q))
    }

    /// Switches this song to another LRCLIB version (remembered). nil = show no lyrics for it.
    func choose(_ id: Int?, for q: LyricsQuery) async -> [Cue]? {
        var e = entry(q.cacheKey) ?? Entry(chosen: nil, lrc: nil, candidates: [], at: Date())
        guard let id else {
            e.hidden = true; e.at = Date(); save(q.cacheKey, e); return nil
        }
        // The version on disk (e.g. after "No Lyrics"), or the user's imported file: no network needed.
        if id == Self.importedID, let lrc = e.imported {
            let cues = Lyrics.parseLRC(lrc, duration: q.duration)
            if !cues.isEmpty { e.chosen = id; e.lrc = lrc; e.hidden = nil; e.at = Date(); save(q.cacheKey, e); return cues }
        }
        if e.chosen == id, let lrc = e.lrc {
            let cues = Lyrics.parseLRC(lrc, duration: q.duration)
            if !cues.isEmpty { e.hidden = nil; e.at = Date(); save(q.cacheKey, e); return cues }
        }
        guard case let .success(r) = await fetch(path: "/api/get/\(id)", query: []), let r, let lrc = r.syncedLyrics else { return nil }
        let cues = Lyrics.parseLRC(lrc, duration: q.duration)
        guard !cues.isEmpty else { return nil }
        e.chosen = id; e.lrc = lrc; e.hidden = nil; e.at = Date()
        if !e.candidates.contains(where: { $0.id == id }) { e.candidates.insert(r.candidate, at: 0) }
        save(q.cacheKey, e)
        return cues
    }

    /// Id used for lyrics the user imported from an .lrc file.
    static let importedID = -2

    /// Uses the user's own LRC for this song (kept in the cache like a chosen version).
    func importLRC(_ text: String, for q: LyricsQuery) -> [Cue]? {
        let cues = Lyrics.parseLRC(text, duration: q.duration)
        guard !cues.isEmpty else { return nil }
        var e = entry(q.cacheKey) ?? Entry(chosen: nil, lrc: nil, candidates: [], at: Date())
        e.chosen = Self.importedID; e.lrc = text; e.imported = text; e.hidden = nil; e.at = Date()
        save(q.cacheKey, e)
        return cues
    }

    /// Menu entry for an imported file (listed with the LRCLIB versions).
    static func importedCandidate(_ q: LyricsQuery) -> LyricsCandidate {
        LyricsCandidate(id: importedID, trackName: L10n.string("Imported LRC File"), artistName: "", albumName: nil, duration: q.duration)
    }

    private func withImported(_ e: Entry, _ q: LyricsQuery) -> [LyricsCandidate] {
        e.imported == nil ? e.candidates : [Self.importedCandidate(q)] + e.candidates.filter { $0.id != Self.importedID }
    }

    /// Forgets the cached result (and choice) so the next lookup asks LRCLIB again.
    func forget(_ q: LyricsQuery) {
        memory[q.cacheKey] = nil
        try? FileManager.default.removeItem(at: file(q.cacheKey))
    }

    // MARK: Network

    private enum NetError: Error { case transient }

    private func get(_ q: LyricsQuery) async -> Result<LRCLIBRecord?, NetError> {
        var items = [URLQueryItem(name: "track_name", value: q.title), URLQueryItem(name: "artist_name", value: q.artist),
                     URLQueryItem(name: "duration", value: String(Int(q.duration.rounded())))]
        if let a = q.album, !a.isEmpty { items.append(URLQueryItem(name: "album_name", value: String(a.prefix(1000)))) }
        return await fetch(path: "/api/get", query: items)
    }

    private func search(_ q: LyricsQuery) async -> Result<[LRCLIBRecord], NetError> {
        let c = q.attempts.last ?? q
        guard let url = Self.url("/api/search", [URLQueryItem(name: "track_name", value: c.title), URLQueryItem(name: "artist_name", value: c.artist)]) else { return .success([]) }
        do {
            // Streamed with a cap: search results carry full lyrics and can be large.
            let (bytes, resp) = try await session.bytes(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 || code >= 500 { return .failure(.transient) }
            guard code == 200 else { return .success([]) }
            var data = Data()
            for try await chunk in bytes {
                data.append(chunk)
                // Too big to be a sane result: not cached as "no lyrics" (treated like a server hiccup).
                if data.count > Self.maxSearchBytes { bytes.task.cancel(); return .failure(.transient) }
            }
            return .success(Array(((try? JSONDecoder().decode([LRCLIBRecord].self, from: data)) ?? []).prefix(30)))
        } catch { return .failure(.transient) }
    }

    private func fetch(path: String, query: [URLQueryItem]) async -> Result<LRCLIBRecord?, NetError> {
        guard let url = Self.url(path, query) else { return .success(nil) }
        do {
            let (data, resp) = try await session.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 || code >= 500 { return .failure(.transient) }
            guard code == 200, data.count < 1_000_000 else { return .success(nil) }
            return .success(try? JSONDecoder().decode(LRCLIBRecord.self, from: data))
        } catch { return .failure(.transient) }
    }

    private static func url(_ path: String, _ query: [URLQueryItem]) -> URL? {
        var c = URLComponents(string: "https://lrclib.net")
        c?.path = path
        c?.queryItems = query.isEmpty ? nil : query
        return c?.url
    }

    // MARK: Cache

    private func file(_ key: String) -> URL {
        // Hash the key into a safe file name (FNV-1a 64).
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return dir.appendingPathComponent(String(h, radix: 16) + ".json")
    }

    private func entry(_ key: String) -> Entry? {
        if let e = memory[key] { return e }
        guard let data = try? Data(contentsOf: file(key)), let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        memory[key] = e
        return e
    }

    private func save(_ key: String, _ e: Entry) {
        memory[key] = e
        if memory.count > 64 { memory.removeAll() }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: file(key), options: .atomic) }
        prune()
    }

    private var savesSincePrune = 0
    /// Keeps the cache bounded: the oldest files go first.
    private func prune() {
        savesSincePrune += 1
        guard savesSincePrune >= 50 else { return }
        savesSincePrune = 0
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > Self.maxFiles else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (f, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.maxFiles) { try? fm.removeItem(at: f) }
    }
}
