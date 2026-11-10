// Film staging code: the landing film's scenes. Never runs in the live app.
import AppKit
import SublineCore
import SwiftUI

/// Each scene draws one thing the film proves, as a function of its progress `p` (0…1) and local time
/// `lt` (seconds). Overlay pieces are the app's real views fed through `LandingSong.stage`.
@MainActor
final class LandingScenes {
    static let desk = CGSize(width: 1000, height: 560)
    private let icon: NSImage? = {
        if let path = ProcessInfo.processInfo.environment["LANDING_ICON"], let img = NSImage(contentsOfFile: path) { return img }
        return nil
    }()

    // MARK: Cuts

    var film: [FilmScene] {
        [
            FilmScene(duration: 1.9) { p, lt, s, _ in AnyView(self.title(lt: lt, stage: s)) },
            FilmScene(duration: 2.7, captions: [FilmCaption(text: "Now it floats.", from: 0.08, to: 1)]) { p, lt, s, m in
                AnyView(self.floats(p: p, lt: lt, stage: s, model: m)) },
            FilmScene(duration: 4.8, captions: [FilmCaption(text: "Every line, on time.", from: 0.04, to: 0.55),
                                                FilmCaption(text: "Tap to jump.", from: 0.57, to: 1)]) { p, lt, s, m in
                AnyView(self.lyrics(p: p, lt: lt, stage: s, model: m)) },
            FilmScene(duration: 3.4, captions: [FilmCaption(text: "Two languages at once.", from: 0.06, to: 1)]) { p, lt, s, m in
                AnyView(self.twoLines(p: p, lt: lt, stage: s, model: m)) },
            FilmScene(duration: 3.2, captions: [FilmCaption(text: "Any player you use.", from: 0.06, to: 1)]) { p, _, s, _ in
                AnyView(self.players(p: p, stage: s)) },
            FilmScene(duration: 3.5, captions: [FilmCaption(text: "Made for your desktop.", from: 0.06, to: 1)]) { p, lt, s, m in
                AnyView(self.desktop(p: p, lt: lt, stage: s, model: m)) },
            FilmScene(duration: 3.3, captions: [FilmCaption(text: "Playback stays in your browser.", from: 0.06, to: 1)]) { p, _, s, _ in
                AnyView(self.privacy(p: p, stage: s)) },
            FilmScene(duration: 4.3) { p, lt, s, _ in AnyView(self.endCard(p: p, lt: lt, stage: s)) },
        ]
    }

    var loop: [FilmScene] {
        [
            FilmScene(duration: 3.4) { p, lt, s, m in AnyView(self.floats(p: p, lt: lt, stage: s, model: m)) },
            FilmScene(duration: 6.9) { p, lt, s, m in AnyView(self.lyrics(p: p, lt: lt * 4.8 / 6.9, stage: s, model: m)) },
        ]
    }

    // MARK: Frames

    /// The made-up desktop as a sticker plate, scaled to the stage.
    /// `camera` zooms into the desktop inside the plate (towards `focus`); `zoom` scales the plate.
    private func deskPlate<C: View>(stage: CGSize, zoom: Double = 1, camera: Double = 1, focus: UnitPoint = .center,
                                    drift: Double = 0, @ViewBuilder _ content: () -> C) -> some View {
        let k = min((stage.width - 140) / Self.desk.width, (stage.height - 150) / Self.desk.height)
        return StickerPlate {
            ZStack { FilmWallpaper(drift: drift); content() }
                .frame(width: Self.desk.width, height: Self.desk.height)
                .scaleEffect(camera, anchor: focus)
                .frame(width: Self.desk.width, height: Self.desk.height)
                .clipped()
        }
        .scaleEffect(k * zoom)
        .frame(width: stage.width, height: stage.height)
        .offset(y: stage.height * 0.045)
    }

    // MARK: 1. Title

    private func title(lt: Double, stage: CGSize) -> some View {
        let words = ["Lyrics", "stuck", "in", "a", "tab?"]
        let size = stage.width * 0.066
        return HStack(spacing: size * 0.24) {
            ForEach(words.indices, id: \.self) { i in
                let k = prog(lt, 0.05 + Double(i) * 0.13, 0.27 + Double(i) * 0.13)
                Group {
                    if i == 0 {
                        Text(words[i]).font(FilmLook.display(size)).foregroundStyle(FilmLook.ink)
                            .padding(.horizontal, size * 0.22)
                            .background(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(.white))
                            .background(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(FilmLook.ink)
                                .offset(x: size * 0.08, y: size * 0.08))
                            .rotationEffect(.degrees(-2))
                    } else {
                        Text(words[i]).font(FilmLook.display(size)).foregroundStyle(FilmLook.ink)
                    }
                }
                .scaleEffect(1.6 - 0.6 * ease(k))
                .opacity(clamp01(k * 2.5))
            }
        }
        .frame(width: stage.width, height: stage.height)
    }

    // MARK: 2. It floats

    private func floats(p: Double, lt: Double, stage: CGSize, model: PlayerModel) -> some View {
        LandingSong.sunset.stage(model, at: 3.4 + lt * 0.9)
        let k = ease(prog(p, 0.12, 0.55))
        return deskPlate(stage: stage, camera: 1 + 0.22 * k, drift: p) {
            BrowserMock(song: LandingSong.sunset)
                .scaleEffect(1 - k * 0.1)
                .offset(y: k * 36)
                .blur(radius: k * 5)
                .brightness(-k * 0.12)
            CoverLineCard(model: model, size: CGSize(width: 600, height: 182))
                .scaleEffect(0.9 + 0.1 * k)
                .offset(y: (1 - k) * 90)
                .opacity(k)
        }
    }

    // MARK: 3. Every line on time / tap to jump

    private lazy var sheet = LyricsSheet(song: LandingSong.sunset, size: CGSize(width: 400, height: 420))

    private func lyrics(p: Double, lt: Double, stage: CGSize, model: PlayerModel) -> some View {
        let d = 4.8
        let clickAt = 0.84 * d
        // Media time runs fast (a time-lapse) until the tap, then from the tapped line at normal speed.
        let target = 5
        let media: (Double) -> Double = { t in
            t < clickAt ? 1.0 + t * 2.6 : LandingSong.sunset.main.cues[target].s + (t - clickAt)
        }
        LandingSong.sunset.stage(model, at: media(lt))
        let scroll = sheet.scrollIndex(at: lt, media: media)
        let cp = ease(prog(p, 0.58, 0.82))
        let targetPoint = sheet.rowCenter(target, scroll: scroll)
        let from = CGPoint(x: 440, y: 470)
        let to = CGPoint(x: targetPoint.x + 20, y: targetPoint.y + 4)
        let cursor = CGPoint(x: from.x + (to.x - from.x) * cp,
                             y: from.y + (to.y - from.y) * cp - sin(cp * .pi) * 40)
        let press = p > 0.82 && p < 0.865
        let camera = 1.32 + ease(prog(p, 0.52, 0.72)) * 0.12 - ease(prog(p, 0.9, 1)) * 0.08
        return deskPlate(stage: stage, camera: camera, drift: p) {
            ZStack(alignment: .topLeading) {
                sheet.view(model: model, scroll: scroll)
                FilmCursor()
                    .scaleEffect(press ? 0.8 : 1, anchor: .topLeading)
                    .scaleEffect(1.3, anchor: .topLeading)
                    .offset(x: cursor.x, y: cursor.y)
                    .opacity(clamp01((p - 0.5) * 12))
            }
            .frame(width: sheet.size.width, height: sheet.size.height, alignment: .topLeading)
        }
    }

    // MARK: 4. Two languages

    private func twoLines(p: Double, lt: Double, stage: CGSize, model: PlayerModel) -> some View {
        LandingSong.dawn.stage(model, at: 2.2 + lt * 1.4)
        let z = 1.5 - 0.14 * ease(prog(p, 0, 0.6))
        return deskPlate(stage: stage, camera: z, drift: p) {
            CoverLineCard(model: model, size: CGSize(width: 600, height: 190))
        }
    }

    // MARK: 5. Any player

    private func players(p: Double, stage: CGSize) -> some View {
        let rows = [["YouTube", "YouTube Music"], ["Spotify", "Apple Music"]]
        let size = stage.width * 0.036
        return VStack(spacing: size * 0.7) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: size * 0.7) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        let i = r * 2 + c
                        let k = prog(p, 0.08 + Double(i) * 0.1, 0.36 + Double(i) * 0.1)
                        Text(rows[r][c])
                            .font(FilmLook.display(size)).foregroundStyle(FilmLook.ink)
                            .padding(.horizontal, size * 0.8).padding(.vertical, size * 0.45)
                            .background(Capsule().fill(.white))
                            .background(Capsule().fill(FilmLook.ink).offset(x: size * 0.14, y: size * 0.14))
                            .rotationEffect(.degrees([-3, 2, 2.5, -2][i]))
                            .scaleEffect(0.5 + 0.5 * spring(k))
                            .opacity(clamp01(k * 3))
                    }
                }
            }
        }
        .frame(width: stage.width, height: stage.height)
        .offset(y: stage.height * 0.05)
    }

    // MARK: 6. Desktop: menu bar, notch, mini

    private func desktop(p: Double, lt: Double, stage: CGSize, model: PlayerModel) -> some View {
        LandingSong.sunset.stage(model, at: 6.8 + lt * 0.2)
        let m = ease(prog(p, 0.04, 0.22)), n = ease(prog(p, 0.2, 0.38)), q = ease(prog(p, 0.6, 0.8))
        // Starts on the top edge (menu bar, notch), then pulls back to the whole desktop.
        let camera = 1.6 - 0.6 * ease(prog(p, 0.46, 0.72))
        return deskPlate(stage: stage, camera: camera, focus: UnitPoint(x: 0.62, y: 0), drift: p) {
            ZStack(alignment: .topLeading) {
                MenuBarMock(line: model.currentLine ?? "", highlight: m)
                NotchView(model: model, notchHeight: 30, hasNotch: true)
                    .frame(width: 340, height: 62)
                    .offset(x: (Self.desk.width - 340) / 2, y: -62 * (1 - n))
                MiniCard(model: model, size: CGSize(width: 420, height: 64))
                    .offset(x: 70, y: 420 + (1 - q) * 30)
                    .opacity(q)
            }
            .frame(width: Self.desk.width, height: Self.desk.height, alignment: .topLeading)
        }
    }

    // MARK: 7. Privacy

    private func privacy(p: Double, stage: CGSize) -> some View {
        let u = stage.width / 1280
        let wires = ["title & artwork", "playback clock", "lyric lines"]
        return HStack(spacing: 34 * u) {
            FlowNode(title: "Your browser", note: "music keeps playing here", u: u)
            VStack(alignment: .leading, spacing: 12 * u) {
                ForEach(wires.indices, id: \.self) { i in
                    let k = ease(prog(p, 0.14 + Double(i) * 0.13, 0.32 + Double(i) * 0.13))
                    HStack(spacing: 8 * u) {
                        Image(systemName: "arrow.right").font(.system(size: 18 * u, weight: .black))
                        Text(wires[i]).font(.system(size: 21 * u, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(FilmLook.ink)
                    .padding(.horizontal, 16 * u).padding(.vertical, 9 * u)
                    .background(Capsule().fill(FilmLook.sticker))
                    .background(Capsule().fill(FilmLook.ink).offset(x: 4 * u, y: 4 * u))
                    .offset(x: (1 - k) * -30 * u)
                    .opacity(k)
                }
            }
            FlowNode(title: "Subline", note: "shows the lines on top", u: u)
        }
        .frame(width: stage.width, height: stage.height)
        .offset(y: stage.height * 0.06)
    }

    // MARK: 8. End card

    private func endCard(p: Double, lt: Double, stage: CGSize) -> some View {
        let u = stage.width / 1280
        let a = spring(prog(lt, 0.0, 0.5)), b = ease(prog(lt, 0.15, 0.45)), c = ease(prog(lt, 0.3, 0.6)), d = ease(prog(lt, 0.42, 0.72))
        let flash = sin(prog(lt, 0.45, 0.85) * .pi) * 0.25
        return VStack(spacing: 22 * u) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 150 * u, height: 150 * u)
                } else {
                    RoundedRectangle(cornerRadius: 34 * u, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.94), Color(red: 0.89, green: 0.42, blue: 0.42)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 150 * u, height: 150 * u)
                }
            }
            .shadow(color: FilmLook.ink.opacity(0.35), radius: 0, x: 8 * u, y: 8 * u)
            .brightness(flash)
            .scaleEffect(0.6 + 0.4 * a)
            .opacity(clamp01(a * 3))
            Text("Subline").font(FilmLook.display(96 * u)).foregroundStyle(FilmLook.ink)
                .opacity(b).offset(y: (1 - b) * 20 * u)
            Text("Download for macOS")
                .font(.system(size: 26 * u, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .padding(.horizontal, 34 * u).padding(.vertical, 16 * u)
                .background(Capsule().fill(FilmLook.ink))
                .background(Capsule().fill(.white).offset(x: 6 * u, y: 6 * u))
                .opacity(c).scaleEffect(0.9 + 0.1 * c)
            Text("subline.jiun.dev").font(.system(size: 24 * u, weight: .semibold, design: .monospaced))
                .foregroundStyle(FilmLook.ink.opacity(0.85))
                .opacity(d)
        }
        .frame(width: stage.width, height: stage.height)
    }
}

// MARK: - Pieces

/// The real Cover + Line overlay (style Clear: the views' own text shadow) over redrawn glass.
struct CoverLineCard: View {
    let model: PlayerModel
    let size: CGSize
    var body: some View {
        let inset: CGFloat = 6
        let inner = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        let art = inner.height
        ZStack(alignment: .topLeading) {
            FilmGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), accent: model.accent)
                .frame(width: inner.width - art - 8, height: inner.height)
                .offset(x: inset + art + 8, y: inset)
            OverlayContent(model: model, layout: .coverLine, size: size, controller: nil)
                .environment(\.overlayStyle, .clear).environment(\.overlayPreview, true)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The real Mini overlay over a redrawn glass capsule.
struct MiniCard: View {
    let model: PlayerModel
    let size: CGSize
    var body: some View {
        ZStack {
            FilmGlass(shape: Capsule(), accent: model.accent).padding(6)
            OverlayContent(model: model, layout: .mini, size: size, controller: nil)
                .environment(\.overlayStyle, .clear).environment(\.overlayPreview, true)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The Lyrics layout: its real header (`ArtworkView`, `TitleBlock`) and real `LyricRow`s, laid out
/// the way `LyricsList` lays them out but scrolled by the film's clock instead of an animation.
@MainActor
final class LyricsSheet {
    let song: LandingSong
    let size: CGSize
    private let fontSize: CGFloat
    private let rowWidth: CGFloat
    private var rows: [(on: CGImage, off: CGImage, height: CGFloat)] = []
    private let header: CGFloat = 64
    private let gap: CGFloat = 8
    private var listHeight: CGFloat { size.height - header - gap }

    init(song: LandingSong, size: CGSize) {
        self.song = song
        self.size = size
        fontSize = max(14, min(30, size.width / 14))
        rowWidth = size.width - 28
        for cue in song.main.cues {
            let on = Self.renderRow(LyricRow(text: cue.text, active: true, synced: true, fontSize: fontSize), width: rowWidth)
            let off = Self.renderRow(LyricRow(text: cue.text, active: false, synced: true, fontSize: fontSize), width: rowWidth)
            if let on, let off { rows.append((on, off, CGFloat(on.height) / LandingFilm.scale)) }
        }
    }

    private static func renderRow(_ row: LyricRow, width: CGFloat) -> CGImage? {
        let r = ImageRenderer(content: row.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark))
        r.scale = LandingFilm.scale
        return r.cgImage
    }

    private var spacing: CGFloat { fontSize * 0.55 }

    private func rowTop(_ i: Int) -> CGFloat {
        rows.prefix(i).reduce(0) { $0 + $1.height + spacing }
    }

    /// Content offset that puts the (fractional) row `scroll` at the list's 45% line, as `LyricsList`
    /// anchors the active row.
    private func offset(scroll: Double) -> CGFloat {
        let i = Int(scroll.rounded(.down)), f = CGFloat(scroll - Double(i))
        let a = rowTop(i) + (i < rows.count ? rows[i].height / 2 : 0)
        let j = min(i + 1, rows.count - 1)
        let b = rowTop(j) + rows[j].height / 2
        return listHeight * 0.45 - (a + (b - a) * f)
    }

    /// Row position in the sheet's coordinates (for the pointer).
    func rowCenter(_ i: Int, scroll: Double) -> CGPoint {
        CGPoint(x: 14 + min(rowWidth * 0.5, 180), y: header + gap + offset(scroll: scroll) + rowTop(i) + rows[i].height / 2)
    }

    /// The followed row at local time `lt`, gliding 0.3 s after each line change like the live list.
    func scrollIndex(at lt: Double, media: (Double) -> Double) -> Double {
        let now = song.main.activeIndex(at: media(lt)) ?? 0
        var back = 0.0
        while back < 0.3 {
            back += 1.0 / 60
            let earlier = song.main.activeIndex(at: media(max(0, lt - back))) ?? 0
            if earlier != now {
                let k = ease(clamp01((back - 1.0 / 120) / 0.3))
                return Double(earlier) + Double(now - earlier) * k
            }
            if lt - back <= 0 { break }
        }
        return Double(now)
    }

    func view(model: PlayerModel, scroll: Double) -> some View {
        let active = model.activeIndex
        let off = offset(scroll: scroll)
        let rows = self.rows
        let tops = rows.indices.map { rowTop($0) }
        return VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: 10) {
                ArtworkView(image: model.artwork, accent: model.accent, radius: 8).frame(width: 48, height: 48)
                TitleBlock(model: model, titleSize: 13)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(height: header)
            .background(FilmGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), accent: model.accent))
            ZStack(alignment: .topLeading) {
                ForEach(rows.indices, id: \.self) { i in
                    let img = i == active ? rows[i].on : rows[i].off
                    Image(decorative: img, scale: LandingFilm.scale)
                        .offset(x: 14, y: off + tops[i])
                }
            }
            .frame(width: size.width, height: listHeight, alignment: .topLeading)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .background(FilmGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), accent: model.accent))
        }
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
    }
}

/// A neutral browser window playing the song, lyrics buried in a side panel.
struct BrowserMock: View {
    let song: LandingSong
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(white: 0.78)).frame(width: 12, height: 12) }
                Text("\(song.title) – \(song.artist)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: 0.25))
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).fill(.white))
                    .padding(.leading, 14)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color(white: 0.89))
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [song.accent.opacity(0.9), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                    if let art = song.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8)).opacity(0.9)
                    }
                    Image(systemName: "play.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 370)
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.85)).frame(height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.85)).frame(width: 120, height: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(song.main.cues.prefix(5).indices, id: \.self) { i in
                            Text(song.main.cues[i].text).font(.system(size: 9.5)).foregroundStyle(Color(white: 0.55))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.93)))
                    RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.85)).frame(width: 90, height: 14)
                }
            }
            .padding(18)
            .frame(maxHeight: .infinity)
            .background(Color(white: 0.97))
        }
        .frame(width: 660, height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
    }
}

/// Neutral menu bar chrome; the Subline item shows the line the way the status item does
/// (music note + current line).
struct MenuBarMock: View {
    let line: String
    let highlight: Double
    var body: some View {
        HStack(spacing: 18) {
            ForEach(["Finder", "File", "Edit", "View", "Window"], id: \.self) { s in
                Text(s).fontWeight(s == "Finder" ? .bold : .regular)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                Text(line).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.2 * highlight)))
            .opacity(0.4 + 0.6 * highlight)
            Image(systemName: "wifi")
            Text("4:48 PM")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: LandingScenes.desk.width, height: 30)
        .background(Color.black.opacity(0.35))
    }
}

struct FlowNode: View {
    let title: String
    let note: String
    let u: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * u) {
            Text(title).font(FilmLook.display(34 * u))
            Text(note).font(.system(size: 18 * u, weight: .medium, design: .monospaced)).opacity(0.75)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28 * u).padding(.vertical, 24 * u)
        .background(RoundedRectangle(cornerRadius: 24 * u, style: .continuous).fill(FilmLook.ink))
        .background(RoundedRectangle(cornerRadius: 24 * u, style: .continuous).fill(.white).offset(x: 8 * u, y: 8 * u))
    }
}
