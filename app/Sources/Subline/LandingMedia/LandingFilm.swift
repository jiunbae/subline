// Film staging code: the landing film's cut (tone "trailer"). Never runs in the live app.
import AppKit
import SublineCore
import SwiftUI

// MARK: - Look

enum FilmLook {
    static let ink = Color(red: 0.10, green: 0.08, blue: 0.19)          // #1a1530
    static let sticker = Color(red: 1.0, green: 0.95, blue: 0.42)       // #fff36b
    static let rainbow: [Color] = [
        Color(red: 1.00, green: 0.70, blue: 0.42), Color(red: 1.00, green: 0.48, blue: 0.66),
        Color(red: 0.61, green: 0.55, blue: 1.00), Color(red: 0.44, green: 0.83, blue: 1.00),
        Color(red: 1.00, green: 0.89, blue: 0.42), Color(red: 1.00, green: 0.70, blue: 0.42),
    ]
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
}

func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
/// Overshooting entrance (0 → 1, peaking a little above 1), for the stickers.
func spring(_ x: Double) -> Double {
    let x = clamp01(x)
    return 1 - exp(-6 * x) * cos(x * 9)
}

/// A white-bordered "sticker" plate with a hard shadow, the trailer's frame for every screen.
struct StickerPlate<Content: View>: View {
    var radius: CGFloat = 22
    var border: CGFloat = 8
    var shadow: CGFloat = 16
    @ViewBuilder let content: Content
    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius - border / 2, style: .continuous))
            .padding(border)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white))
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(FilmLook.ink.opacity(0.88))
                .offset(x: shadow, y: shadow))
    }
}

/// The glass the live overlay gets from the system, redrawn: offscreen drawing has no vibrancy.
struct FilmGlass<S: InsettableShape>: View {
    let shape: S
    var accent: Color = Color(red: 0.55, green: 0.25, blue: 0.65)
    var body: some View {
        shape.fill(Color(red: 0.16, green: 0.12, blue: 0.22).opacity(0.70))
            .overlay(shape.fill(LinearGradient(colors: [accent.opacity(0.35), .clear, .black.opacity(0.2)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

/// A made-up desktop: a generated wallpaper, never a photo.
struct FilmWallpaper: View {
    var drift: Double = 0
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.22), Color(red: 0.20, green: 0.11, blue: 0.30)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 0.98, green: 0.47, blue: 0.40)).frame(width: 560)
                .offset(x: 330 + drift * 20, y: 230).blur(radius: 120)
            Circle().fill(Color(red: 0.50, green: 0.26, blue: 0.85)).frame(width: 620)
                .offset(x: -380, y: -180 - drift * 16).blur(radius: 130)
            Circle().fill(Color(red: 0.17, green: 0.65, blue: 0.80)).frame(width: 380)
                .offset(x: 120 - drift * 18, y: -260).blur(radius: 110)
        }
        .drawingGroup()
    }
}

/// The pointer, drawn (no real input device is involved).
struct FilmCursor: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 0, y: 26)); p.addLine(to: CGPoint(x: 7, y: 20))
            p.addLine(to: CGPoint(x: 12, y: 31)); p.addLine(to: CGPoint(x: 16, y: 29)); p.addLine(to: CGPoint(x: 11, y: 18))
            p.addLine(to: CGPoint(x: 19, y: 18)); p.closeSubpath()
        }
        .fill(.white)
        .overlay(Path { p in
            p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 0, y: 26)); p.addLine(to: CGPoint(x: 7, y: 20))
            p.addLine(to: CGPoint(x: 12, y: 31)); p.addLine(to: CGPoint(x: 16, y: 29)); p.addLine(to: CGPoint(x: 11, y: 18))
            p.addLine(to: CGPoint(x: 19, y: 18)); p.closeSubpath()
        }.stroke(.black, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)))
        .frame(width: 20, height: 32)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
    }
}

/// The caption sticker: yellow, tilted, springing in.
struct CaptionSticker: View {
    let text: String
    let size: CGFloat
    var body: some View {
        Text(text)
            .font(FilmLook.display(size))
            .foregroundStyle(FilmLook.ink)
            .padding(.horizontal, size * 0.6).padding(.vertical, size * 0.32)
            .background(RoundedRectangle(cornerRadius: size * 0.42, style: .continuous).fill(FilmLook.sticker))
            .background(RoundedRectangle(cornerRadius: size * 0.42, style: .continuous).fill(FilmLook.ink)
                .offset(x: size * 0.15, y: size * 0.15))
            .fixedSize()
    }
}

// MARK: - The cut

struct FilmCaption {
    let text: String
    let from: Double   // fraction of the scene
    let to: Double
}

struct FilmScene {
    let duration: Double
    var captions: [FilmCaption] = []
    let draw: (_ p: Double, _ lt: Double, _ stage: CGSize, _ model: PlayerModel) -> AnyView
}

@MainActor
final class LandingFilm {
    static let filmPoints = CGSize(width: 1280, height: 720)
    static let loopPoints = CGSize(width: 960, height: 600)
    static let scale: CGFloat = 1.5
    static let fps = 30
    static let transition = 0.3

    /// Two models: during a transition the outgoing and incoming scenes show different moments.
    private let models = [PlayerModel(), PlayerModel()]
    private let scenes: LandingScenes
    private let filmCut: [FilmScene]
    private let loopCut: [FilmScene]

    init() {
        scenes = LandingScenes()
        filmCut = scenes.film
        loopCut = scenes.loop
    }

    // MARK: Timeline

    private struct Placed { let scene: FilmScene; let start: Double; let index: Int }

    private func place(_ cut: [FilmScene]) -> (placed: [Placed], total: Double) {
        var at = 0.0
        var out: [Placed] = []
        for (i, s) in cut.enumerated() {
            out.append(Placed(scene: s, start: at, index: i))
            at += s.duration - Self.transition
        }
        return (out, at + Self.transition)
    }

    func duration(loop: Bool) -> Double {
        let (_, total) = place(loop ? loopCut : filmCut)
        return loop ? total - Self.transition : total
    }

    /// The whole frame at time `t` as one view, laid out at `stage` points.
    func frameView(at t: Double, loop: Bool) -> AnyView {
        let cut = loop ? loopCut : filmCut
        let stage = loop ? Self.loopPoints : Self.filmPoints
        let (placed, total) = place(cut)
        let period = total - Self.transition
        let tr = Self.transition
        var layers: [AnyView] = []
        var captions: [AnyView] = []
        // In the loop the last scene's tail is still leaving while the first one comes back in.
        var visible: [(Placed, Double)] = placed.map { ($0, t - $0.start) }
        if loop, let last = placed.last { visible.insert((last, t + period - last.start), at: 0) }
        for (q, lt) in visible where lt >= 0 && lt < q.scene.duration {
            let d = q.scene.duration
            let p = clamp01(lt / d)
            let isLast = q.index == placed.count - 1 && !loop
            let fin = (q.index == 0 && !loop) ? 1 : clamp01(lt / tr)
            let fout = isLast ? 1 : clamp01((d - lt) / tr)
            let o = min(fin, fout)
            let scale = fin < 1 ? 1.16 - 0.16 * ease(fin) : 1 - (1 - fout) * 0.1
            let model = models[q.index % 2]
            layers.append(AnyView(
                q.scene.draw(p, lt, stage, model)
                    .frame(width: stage.width, height: stage.height)
                    .scaleEffect(scale)
                    .blur(radius: (1 - o) * 8)
                    .opacity(o)))
            for c in q.scene.captions where !loop {
                let span = (c.to - c.from) * d
                let lc = (p - c.from) / (c.to - c.from)
                guard lc >= 0, lc <= 1 else { continue }
                let cin = clamp01(lc * span / 0.5), cout = clamp01((1 - lc) * span / 0.28)
                let s = 0.55 + 0.45 * spring(cin)
                captions.append(AnyView(
                    CaptionSticker(text: c.text, size: stage.width * 0.031)
                        .scaleEffect(s * (0.9 + 0.1 * cout), anchor: .leading)
                        .rotationEffect(.degrees(-3 + (1 - clamp01(cin * 1.4)) * -5), anchor: .leading)
                        .opacity(min(clamp01(cin * 3), cout))
                        .padding(.leading, stage.width * 0.045).padding(.top, stage.height * 0.07)
                        .frame(width: stage.width, height: stage.height, alignment: .topLeading)))
            }
        }
        let bgT = loop ? t.truncatingRemainder(dividingBy: max(period, 0.001)) * (360 / period) / 24 : t
        return AnyView(
            ZStack(alignment: .topLeading) {
                FilmBackground(angle: bgT * 24, size: stage)
                ForEach(layers.indices, id: \.self) { layers[$0] }
                ForEach(captions.indices, id: \.self) { captions[$0] }
            }
            .frame(width: stage.width, height: stage.height)
            .clipped())
    }

    func image(at t: Double, loop: Bool) -> CGImage? {
        let stage = loop ? Self.loopPoints : Self.filmPoints
        return LandingMediaMode.render(frameView(at: t, loop: loop), size: stage, scale: Self.scale)
    }

    // MARK: Outputs

    func recordFilm(to dir: URL, ffmpeg: String) -> Bool {
        record(to: dir, ffmpeg: ffmpeg, name: "film", loop: false, crf: (21, 38), poster: 5.0)
    }

    func recordLoop(to dir: URL, ffmpeg: String) -> Bool {
        record(to: dir, ffmpeg: ffmpeg, name: "loop", loop: true, crf: (20, 36), poster: 2.6)
    }

    private func record(to dir: URL, ffmpeg: String, name: String, loop: Bool, crf: (Int, Int), poster: Double) -> Bool {
        let stage = loop ? Self.loopPoints : Self.filmPoints
        let px = CGSize(width: stage.width * Self.scale, height: stage.height * Self.scale)
        guard let enc = LandingEncoder(ffmpeg: ffmpeg, size: px, fps: Self.fps,
                                       mp4: dir.appendingPathComponent("\(name).mp4"),
                                       webm: dir.appendingPathComponent("\(name).webm"), crf: crf) else { return false }
        let total = duration(loop: loop)
        let frames = Int((total * Double(Self.fps)).rounded())
        let started = Date()
        for i in 0..<frames {
            autoreleasepool {
                if let img = image(at: Double(i) / Double(Self.fps), loop: loop) { enc.append(img) }
            }
        }
        let ok = enc.finish()
        print(String(format: "%@: %d frames, %.1f s, rendered in %.0f s", name, frames, total, Date().timeIntervalSince(started)))
        if let img = image(at: poster, loop: loop) {
            _ = LandingMediaMode.writeJPEG(img, to: dir.appendingPathComponent("\(name).jpg"))
        }
        return ok
    }

    /// Stills for the contact sheet: inside each scene and in the middle of each transition.
    func preview(to dir: URL) -> Bool {
        let (placed, total) = place(filmCut)
        var times: [Double] = []
        for q in placed {
            times += [q.start + q.scene.duration * 0.3, q.start + q.scene.duration * 0.75]
            if q.index > 0 { times.append(q.start + Self.transition / 2) }
        }
        times.append(total - 0.1)
        var ok = true
        for (i, t) in times.sorted().enumerated() {
            guard let img = image(at: t, loop: false) else { ok = false; continue }
            ok = LandingMediaMode.writeJPEG(img, to: dir.appendingPathComponent(String(format: "film-%02d-%05.2f.jpg", i, t))) && ok
        }
        for (i, t) in [0.5, 2.0, 4.0, 6.5, 8.5, duration(loop: true) - 0.15].enumerated() {
            guard let img = image(at: t, loop: true) else { ok = false; continue }
            ok = LandingMediaMode.writeJPEG(img, to: dir.appendingPathComponent(String(format: "loop-%02d-%05.2f.jpg", i, t))) && ok
        }
        return ok
    }

    /// One still per overlay style, to see what offscreen drawing keeps.
    func probe(to dir: URL) -> Bool {
        let m = models[0]
        LandingSong.sunset.stage(m, at: 4)
        let v = HStack(spacing: 30) {
            ForEach(OverlayStyle.allCases) { st in
                OverlayContent(model: m, layout: .coverLine, size: CGSize(width: 380, height: 120), controller: nil)
                    .environment(\.overlayStyle, st).environment(\.overlayPreview, true)
                    .frame(width: 380, height: 120)
            }
        }
        .padding(40)
        .background(FilmWallpaper())
        guard let img = LandingMediaMode.render(v, size: CGSize(width: 1320, height: 200), scale: 2) else { return false }
        return LandingMediaMode.writeJPEG(img, to: dir.appendingPathComponent("probe.jpg"))
    }
}

/// The rotating rainbow behind everything: a conic gradient drawn tiny and scaled up, which blurs it
/// for free.
struct FilmBackground: View {
    let angle: Double
    let size: CGSize
    var body: some View {
        let small = CGSize(width: 48, height: 27)
        let img: CGImage? = {
            let r = ImageRenderer(content:
                AngularGradient(colors: FilmLook.rainbow, center: .center, angle: .degrees(angle))
                    .frame(width: small.width * 2.2, height: small.height * 2.2)
                    .frame(width: small.width, height: small.height)
                    .clipped())
            r.scale = 1
            return r.cgImage
        }()
        if let img {
            Image(decorative: img, scale: 1).resizable().interpolation(.high)
                .frame(width: size.width, height: size.height)
                .overlay(Color.white.opacity(0.12))
        }
    }
}
