import SwiftUI
import AppKit
import NowPlayingCore

private let corner: CGFloat = 18

struct OverlayRoot: View {
    @Bindable var model: PlayerModel
    let controller: PanelController

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Background(accent: model.accent)
                content(size: geo.size)
                    .padding(model.layout == .cover ? 0 : 10)
                if model.hovering && model.hasTrack {
                    HoverChrome(model: model, controller: controller, size: geo.size)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: model.layout == .mini ? geo.size.height / 2 : corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: model.layout == .mini ? geo.size.height / 2 : corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in controller.dragChanged() }
                    .onEnded { _ in controller.dragEnded() }
            )
            .onTapGesture(count: 2) { model.command("toggle") }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if !model.hasTrack {
            EmptyStateView(model: model, size: size)
        } else {
            switch model.layout {
            case .cover: CoverLayout(model: model, size: size)
            case .coverLine: CoverLineLayout(model: model, size: size)
            case .lyrics: LyricsLayout(model: model, size: size)
            case .mini: MiniLayout(model: model, size: size)
            }
        }
    }
}

// MARK: - Background

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        // Always dark so white text stays legible over bright desktops.
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct Background: View {
    let accent: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(white: 0.1)
            } else {
                VisualEffect()
            }
            LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.15), .black.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .animation(.easeInOut(duration: 0.6), value: accent)
        }
    }
}

// MARK: - Pieces

struct ArtworkView: View {
    let image: NSImage?
    let accent: Color
    var radius: CGFloat = 10

    var body: some View {
        // Color.clear defines the layout box; the image fills (center-crops) inside it.
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                        .id(ObjectIdentifier(image))
                } else {
                    ZStack {
                        LinearGradient(colors: [accent, accent.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

/// The current caption/lyric line with a vertical slide transition between lines.
struct CurrentLine: View {
    let model: PlayerModel
    let fontSize: CGFloat
    var lineLimit = 2
    var alignment: TextAlignment = .leading

    var body: some View {
        let line = model.currentLine
        ZStack(alignment: alignment == .center ? .center : .leading) {
            if let line {
                Text(line)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(alignment)
                    .lineLimit(lineLimit)
                    .minimumScaleFactor(0.7)
                    .id("\(model.activeIndex ?? -1)|\(line)")
                    // Outgoing line clears quickly; incoming line rises in just after, so they never overlap legibly.
                    // Short, fixed-length curves (no spring tail, no text shadow) keep each line change to a few
                    // frames: this transition runs every few seconds for the whole song.
                    .transition(.asymmetric(
                        insertion: AnyTransition.offset(y: fontSize * 0.45).combined(with: .opacity)
                            .animation(.easeOut(duration: 0.26).delay(0.08)),
                        removal: AnyTransition.opacity.animation(.easeIn(duration: 0.1))))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

struct TitleBlock: View {
    let model: PlayerModel
    var titleSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if model.isAd {
                    Text("AD").font(.system(size: titleSize * 0.7, weight: .heavy))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.black)
                }
                Text(model.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            Text(model.artist)
                .font(.system(size: titleSize * 0.85, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }
}

// MARK: - Layouts

struct CoverLayout: View {
    let model: PlayerModel
    let size: CGSize

    var body: some View {
        ZStack(alignment: .bottom) {
            ArtworkView(image: model.artwork, accent: model.accent, radius: 0)
                .frame(width: size.width, height: size.height)
            if model.currentLine != nil || model.hovering {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 6) {
                if model.hovering { TitleBlock(model: model, titleSize: max(11, size.width / 20)) }
                CurrentLine(model: model, fontSize: max(12, size.width / 15), lineLimit: 3, alignment: .center)
            }
            .padding(12)
        }
    }
}

struct CoverLineLayout: View {
    let model: PlayerModel
    let size: CGSize

    var body: some View {
        let art = size.height - 20
        HStack(spacing: 12) {
            ArtworkView(image: model.artwork, accent: model.accent)
                .frame(width: art, height: art)
            VStack(alignment: .leading, spacing: 4) {
                TitleBlock(model: model, titleSize: max(11, min(15, size.height / 9)))
                Spacer(minLength: 0)
                CurrentLine(model: model, fontSize: max(13, min(28, size.height / 5.5)))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MiniLayout: View {
    let model: PlayerModel
    let size: CGSize

    var body: some View {
        let art = size.height - 16
        HStack(spacing: 10) {
            ArtworkView(image: model.artwork, accent: model.accent, radius: art / 2)
                .frame(width: art, height: art)
                .rotationEffect(.zero)
            if model.currentLine != nil {
                CurrentLine(model: model, fontSize: max(12, min(20, size.height / 3)), lineLimit: 1)
            } else {
                Text("\(model.title) · \(model.artist)")
                    .font(.system(size: max(11, min(16, size.height / 3.4)), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, -2)
        .padding(.trailing, 8)
    }
}

struct LyricsLayout: View {
    let model: PlayerModel
    let size: CGSize

    var body: some View {
        let fs = max(14, min(30, size.width / 14))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ArtworkView(image: model.artwork, accent: model.accent, radius: 8)
                    .frame(width: 48, height: 48)
                TitleBlock(model: model, titleSize: 13)
                Spacer(minLength: 0)
            }
            if !model.cues.isEmpty {
                LyricsList(model: model, fontSize: fs)
            } else if model.liveCaption != nil {
                Spacer(minLength: 0)
                CurrentLine(model: model, fontSize: fs, lineLimit: 4)
                Spacer(minLength: 0)
            } else {
                NoTextView(model: model)
            }
        }
        .padding(4)
    }
}

struct LyricsList: View {
    let model: PlayerModel
    let fontSize: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: fontSize * 0.55) {
                    Color.clear.frame(height: 40)
                    // Rows are Equatable value views: a line change re-renders only the two rows whose
                    // `active` flips, not the whole list.
                    let cues = model.cues, synced = model.synced, activeIndex = model.activeIndex
                    ForEach(cues.indices, id: \.self) { i in
                        LyricRow(text: cues[i].text, active: synced && i == activeIndex, synced: synced, fontSize: fontSize)
                            .equatable()
                            .id(i)
                            .onTapGesture { if synced { model.command("seek", t: cues[i].s) } }
                    }
                    Color.clear.frame(height: 80)
                }
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: model.activeIndex) { _, idx in
                guard let idx, !model.hovering else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: UnitPoint(x: 0, y: 0.35))
                }
            }
            .onAppear { if let i = model.activeIndex { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.35)) } }
        }
    }
}

struct LyricRow: View, Equatable {
    let text: String
    let active: Bool
    let synced: Bool
    let fontSize: CGFloat

    var body: some View {
        // Opacity only: per-line blur/scale forced an offscreen pass for every visible line
        // on every animation frame (≈14% CPU while playing).
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(!synced ? 0.85 : (active ? 1 : 0.32)))
            .animation(.easeOut(duration: 0.25), value: active)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoTextView: View {
    let model: PlayerModel
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "captions.bubble").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
            Text("No captions or lyrics").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            if model.site == "yt" {
                Button("Connect captions") { model.connectCaptions() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct EmptyStateView: View {
    let model: PlayerModel
    let size: CGSize
    var body: some View {
        let compact = size.height < 90
        HStack(spacing: 10) {
            Image(systemName: model.connectionCount == 0 ? "puzzlepiece.extension" : "play.circle")
                .font(.system(size: compact ? 18 : 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connectionCount == 0 ? "Waiting for Chrome" : "Nothing playing")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                if !compact {
                    Text(model.connectionCount == 0 ? "Install the Now Playing extension" : "Play something on YouTube")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hover chrome (controls, progress, resize grip)

struct HoverChrome: View {
    let model: PlayerModel
    let controller: PanelController
    let size: CGSize

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Spacer()
                    Controls(model: model, compact: model.layout == .mini || size.height < 100)
                }
                Spacer()
            }
            .padding(model.layout == .mini ? 8 : 8)

            if model.layout != .mini, let d = model.duration, d > 0 {
                VStack {
                    Spacer()
                    ProgressLine(model: model, duration: d)
                }
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ResizeGrip(controller: controller)
                }
            }
        }
    }
}

struct Controls: View {
    let model: PlayerModel
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            button("backward.fill", "prev")
            button(model.isPlaying ? "pause.fill" : "play.fill", "toggle")
            button("forward.fill", "next")
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    private func button(_ symbol: String, _ action: String) -> some View {
        Button { model.command(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .frame(width: compact ? 20 : 24, height: compact ? 18 : 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
    }
}

/// Only rendered while hovering, so the 2 Hz timeline never runs otherwise.
struct ProgressLine: View {
    let model: PlayerModel
    let duration: Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            GeometryReader { g in
                let frac = min(1, max(0, model.position() / duration))
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.15))
                    Rectangle().fill(.white.opacity(0.75)).frame(width: g.size.width * frac)
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in model.command("seek", t: duration * Double(loc.x / g.size.width)) }
            }
            .frame(height: 3)
        }
    }
}

struct ResizeGrip: View {
    let controller: PanelController
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in controller.resizeChanged() }
                    .onEnded { _ in controller.resizeEnded() }
            )
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
    }
}
