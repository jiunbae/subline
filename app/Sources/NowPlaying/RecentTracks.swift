import AppKit
import NowPlayingCore

/// A recently played video, kept so an idle overlay can offer to pick up where you left off.
struct RecentTrack: Codable, Identifiable, Equatable {
    let videoId: String
    let site: String
    let title: String
    let artist: String
    var at: Date
    var id: String { videoId }

    var url: URL? {
        let base = site == "ytm" ? "https://music.youtube.com/watch?v=" : "https://www.youtube.com/watch?v="
        return URL(string: base + videoId)
    }

    var ago: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = L10n.locale
        return Date().timeIntervalSince(at) < 60 ? L10n.string("just now") : f.localizedString(for: at, relativeTo: Date())
    }
}

/// Persistence: the list in user defaults, small JPEG thumbnails in Application Support.
/// Only titles, artists, video IDs and thumbnails of the last few videos are kept, on this Mac only.
enum RecentStore {
    static let limit = 5
    private static let key = "recents"
    static var thumbDir: URL { NPPaths.supportDir.appendingPathComponent("recents", isDirectory: true) }

    static func load() -> [RecentTrack] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentTrack].self, from: d) else { return [] }
        return Array(list.prefix(limit))
    }

    static func save(_ list: [RecentTrack]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
        // Drop thumbnails that fell off the list.
        let keep = Set(list.map { "\($0.videoId).jpg" })
        for f in (try? FileManager.default.contentsOfDirectory(atPath: thumbDir.path)) ?? [] where !keep.contains(f) {
            try? FileManager.default.removeItem(at: thumbDir.appendingPathComponent(f))
        }
    }

    static func thumb(_ id: String) -> NSImage? {
        NSImage(contentsOf: thumbDir.appendingPathComponent("\(id).jpg"))
    }

    /// Stores a 200 px JPEG of `image` for `id` (no network: reuses the artwork already shown).
    static func saveThumb(_ image: NSImage, for id: String) -> NSImage? {
        let side: CGFloat = 200
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let s = min(w, h) // center square crop
        guard let crop = cg.cropping(to: CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)),
              let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: small)
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        try? jpg.write(to: thumbDir.appendingPathComponent("\(id).jpg"), options: .atomic)
        return NSImage(cgImage: small, size: NSSize(width: side, height: side))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: thumbDir)
    }
}
