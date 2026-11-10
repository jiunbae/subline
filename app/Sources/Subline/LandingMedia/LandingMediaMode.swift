// Film staging code: renders the landing page's media. Never runs in the live app.
import AppKit
import SublineCore
import SwiftUI

/// `Subline landing-media <dir> [film|loop|preview|probe]` records the landing page's videos and
/// stills (site/shots) from the real overlay views.
///
/// Regenerate after a release that changes the overlay's look (see store/SUBMISSION.md):
///
///     scripts/render-landing-media.sh            # film + loop
///     scripts/render-landing-media.sh preview    # contact-sheet stills only
///
/// What is real and what is staged:
/// - Real: `OverlayContent` (Cover + Line, Mini), `LyricRow`/`TitleBlock`/`ArtworkView` of the
///   Lyrics layout and `NotchView`. Their text comes from made-up LRC files parsed by
///   `Lyrics.parseLRC`, timed by `CueTimeline` and romanized by `DerivedLines.romanized`, all fed
///   through `PlayerModel.stageFilm`.
/// - Staged: the songs and artwork (invented), the desktop, the menu bar chrome, the browser window,
///   the pointer, the glass (offscreen drawing has no vibrancy, so it is redrawn as a tinted panel),
///   and everything in the cut (background, captions, transitions).
///
/// Frames are a pure function of time. Encoded with ffmpeg (H.264 MP4 + VP9 WebM + JPEG poster).
/// The script runs this with a throwaway home folder so no preference of yours is read or written.
@MainActor
enum LandingMediaMode {
    static func run(outputDir: String, only: Set<String>) -> Int32 {
        guard let ffmpeg = findFFmpeg() else {
            FileHandle.standardError.write(Data("landing-media needs ffmpeg (brew install ffmpeg)\n".utf8))
            return 2
        }
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let all = only.isEmpty
        var ok = true
        let film = LandingFilm()
        if only.contains("probe") { ok = film.probe(to: dir) && ok }
        if only.contains("preview") { ok = film.preview(to: dir) && ok }
        if all || only.contains("film") { ok = film.recordFilm(to: dir, ffmpeg: ffmpeg) && ok }
        if all || only.contains("loop") { ok = film.recordLoop(to: dir, ffmpeg: ffmpeg) && ok }
        return ok ? 0 : 1
    }

    static func findFFmpeg() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Rasterizes a SwiftUI view laid out at `size` points into `scale`× pixels.
    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat) -> CGImage? {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        r.scale = scale
        r.isOpaque = false
        return r.cgImage
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.86) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return false }
        do { try data.write(to: url) } catch { return false }
        print("wrote \(url.path)")
        return true
    }
}

/// Streams frames to ffmpeg as raw RGBA and writes an MP4 and a WebM (bt709, tuned for UI).
final class LandingEncoder {
    private let process = Process()
    private let input = Pipe()
    private let size: CGSize
    private let context: CGContext
    let outputs: [URL]

    init?(ffmpeg: String, size: CGSize, fps: Int, mp4: URL, webm: URL, crf: (mp4: Int, webm: Int)) {
        self.size = size
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        self.context = context
        let color = ["-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
                     "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        let head = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba",
                    "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-"]
        let h264 = ["-c:v", "libx264", "-preset", "slow", "-crf", "\(crf.mp4)", "-tune", "animation",
                    "-movflags", "+faststart", mp4.path]
        let vp9 = ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "\(crf.webm)", "-row-mt", "1",
                   "-deadline", "good", "-cpu-used", "2", webm.path]
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = head + color + h264 + color + vp9
        outputs = [mp4, webm]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
    }

    func append(_ image: CGImage) {
        let rect = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let data = context.data else { return }
        input.fileHandleForWriting.write(Data(bytes: data, count: Int(size.width * size.height * 4)))
    }

    func finish() -> Bool {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        for url in outputs where process.terminationStatus == 0 { print("wrote \(url.path)") }
        return process.terminationStatus == 0
    }
}
