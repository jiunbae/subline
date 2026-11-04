import AppKit
import ImageIO

/// Downloads artwork, downsamples it once to display size, and extracts an accent color.
actor ArtworkLoader {
    struct Result: @unchecked Sendable {
        let image: NSImage
        let accent: NSColor
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 0)
        cfg.timeoutIntervalForRequest = 10
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg, delegate: RedirectGuard(), delegateQueue: nil)
    }()
    private static let maxBytes = 8 * 1024 * 1024

    /// Re-validates every redirect hop against the host allowlist.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(ArtworkLoader.isAllowed) == true ? request : nil)
        }
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Streams the body, enforcing a byte cap and an image MIME type.
    private func fetch(_ url: URL) async -> Data? {
        guard let (bytes, resp) = try? await session.bytes(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") ?? false,
              http.expectedContentLength <= Self.maxBytes else { return nil }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await chunk in bytes {
                data.append(chunk)
                if data.count > Self.maxBytes { bytes.task.cancel(); return nil }
            }
        } catch { return nil }
        return data
    }

    private var cache: [String: Result] = [:]
    private var order: [String] = []
    private let capacity = 6
    private let maxPixel = 720

    private static let allowedHosts = ["i.ytimg.com", "i9.ytimg.com", "yt3.ggpht.com", "yt3.googleusercontent.com", "lh3.googleusercontent.com"]

    func load(urls: [String]) async -> Result? {
        for s in urls {
            if let hit = cache[s] { return hit }
            guard let url = URL(string: s), Self.isAllowed(url) else { continue }
            guard let data = await fetch(url), let r = decode(data) else { continue }
            insert(s, r)
            return r
        }
        return nil
    }

    private func insert(_ key: String, _ r: Result) {
        cache[key] = r
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
    }

    private func decode(_ data: Data) -> Result? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int,
              pw > 0, ph > 0, pw * ph <= 40_000_000 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        cg = Self.trimLetterbox(cg) ?? cg
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return Result(image: img, accent: Self.accent(of: cg))
    }

    /// Crops near-black letterbox/pillarbox bands (common in YouTube thumbnails).
    private static func trimLetterbox(_ cg: CGImage) -> CGImage? {
        let w = 64, h = max(1, Int(64.0 * Double(cg.height) / Double(cg.width)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        func luma(_ x: Int, _ y: Int) -> Int {
            let i = (y * w + x) * 4
            return (Int(px[i]) * 3 + Int(px[i + 1]) * 6 + Int(px[i + 2])) / 10
        }
        func colDark(_ x: Int) -> Bool { (0..<h).allSatisfy { luma(x, $0) < 24 } }
        func rowDark(_ y: Int) -> Bool { (0..<w).allSatisfy { luma($0, y) < 24 } }
        var l = 0, r = w - 1, t = 0, b = h - 1
        while l < w / 3 && colDark(l) { l += 1 }
        while r > w * 2 / 3 && colDark(r) { r -= 1 }
        while t < h / 3 && rowDark(t) { t += 1 }
        while b > h * 2 / 3 && rowDark(b) { b -= 1 }
        guard l > 0 || t > 0 || r < w - 1 || b < h - 1 else { return nil }
        // Bitmap memory is top-down, matching CGImage.cropping coordinates.
        let sx = Double(cg.width) / Double(w), sy = Double(cg.height) / Double(h)
        let rect = CGRect(x: Double(l + 1) * sx, y: Double(t + 1) * sy,
                          width: Double(r - l - 1) * sx, height: Double(b - t - 1) * sy).integral
        guard rect.width > 32, rect.height > 32 else { return nil }
        return cg.cropping(to: rect)
    }

    private static func average(_ cg: CGImage, size: Int) -> (r: Double, g: Double, b: Double) {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard ok else { return (0.3, 0.3, 0.3) }
        var r = 0.0, g = 0.0, b = 0.0
        let n = Double(size * size)
        for i in stride(from: 0, to: px.count, by: 4) {
            r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2])
        }
        return (r / n / 255, g / n / 255, b / n / 255)
    }

    /// A saturated, mid-brightness accent derived from the most colorful region.
    private static func accent(of cg: CGImage) -> NSColor {
        let size = 6
        var px = [UInt8](repeating: 0, count: size * size * 4)
        px.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                   bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
        }
        var best = NSColor(white: 0.35, alpha: 1)
        var bestScore = -1.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = NSColor(srgbRed: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255,
                            blue: CGFloat(px[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let score = Double(s) * (1 - abs(Double(v) - 0.6))
            if score > bestScore {
                bestScore = score
                best = NSColor(hue: h, saturation: min(s, 0.75), brightness: min(max(v, 0.35), 0.7), alpha: 1)
            }
        }
        return best
    }
}
