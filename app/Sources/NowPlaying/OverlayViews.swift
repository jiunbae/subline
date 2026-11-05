import SwiftUI
import AppKit
import NowPlayingCore

private let corner: CGFloat = 18
/// Breathing room around floating pieces (glass/clear) so their SwiftUI shadows aren't clipped by the window.
private let floatInset: CGFloat = 6

// MARK: - Style environment

private struct OverlayStyleKey: EnvironmentKey { static let defaultValue: OverlayStyle = .tinted }
private struct OverlayPreviewKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var overlayStyle: OverlayStyle {
        get { self[OverlayStyleKey.self] }
        set { self[OverlayStyleKey.self] = newValue }
    }
    /// True inside the appearance gallery: blur what is in the window, not what is behind it.
    var overlayPreview: Bool {
        get { self[OverlayPreviewKey.self] }
        set { self[OverlayPreviewKey.self] = newValue }
    }
}

/// Contrast backing for text in the transparent styles: Liquid Glass on macOS 26+, a HUD material
/// before that, or just a soft shadow for `.clear`. No-op for `.tinted` (the panel is the backing).
struct TextBacking<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.overlayStyle) private var style
    @Environment(\.overlayPreview) private var preview

    func body(content: Content) -> some View {
        switch style {
        case .tinted:
            content
        case .clear:
            content.shadow(color: .black.opacity(0.6), radius: 2.5, y: 1)
        case .glass:
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(.black.opacity(0.22)), in: shape)
            } else {
                content
                    .background { VisualEffect(withinWindow: preview).clipShape(shape) }
                    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            }
        }
    }
}

extension View {
    func textBacking<S: InsettableShape>(_ shape: S) -> some View { modifier(TextBacking(shape: shape)) }
}

struct OverlayRoot: View {
    @Bindable var model: PlayerModel
    let controller: PanelController

    var body: some View {
        GeometryReader { geo in
            OverlayContent(model: model, layout: model.layout, size: geo.size, controller: controller)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { _ in controller.dragChanged() }
                        .onEnded { _ in controller.dragEnded() }
                )
                .onTapGesture(count: 2) { model.command("toggle") }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.overlayStyle, model.style)
    }
}

/// Everything drawn for one layout at one size. Shared by the live overlay and the appearance previews
/// (`controller == nil`: no hover chrome).
struct OverlayContent: View {
    let model: PlayerModel
    let layout: OverlayLayout
    let size: CGSize
    let controller: PanelController?
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: layout == .mini ? size.height / 2 : corner, style: .continuous)
        let tinted = style == .tinted
        let inner = CGSize(width: size.width - (tinted ? 0 : floatInset * 2), height: size.height - (tinted ? 0 : floatInset * 2))
        ZStack {
            if tinted { Background(accent: model.accent) }
            // Paused: the same content, dimmed and desaturated, so it reads as "stopped" at a glance.
            let paused = model.hasTrack && !model.isPlaying
            content(size: tinted && layout != .cover ? CGSize(width: inner.width - 20, height: inner.height - 20) : inner)
                .padding(tinted && layout != .cover ? 10 : 0)
                .padding(tinted ? 0 : floatInset)
                // Constant modifiers (not an if/else) keep the subtree's identity, so pausing doesn't
                // rebuild the lyrics list or lose its scroll position; neutral values cost ~nothing (measured).
                .saturation(paused ? 0.45 : 1)
                .opacity(paused ? 0.72 : 1)
                .animation(.easeOut(duration: 0.3), value: paused)
            if paused && !model.hovering && layout == .cover {
                Image(systemName: "pause.fill")
                    .font(.system(size: max(18, size.width / 9), weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: max(40, size.width / 4.5), height: max(40, size.width / 4.5))
                    .background(.black.opacity(0.35), in: Circle())
                    .transition(.opacity)
            }
            if let controller, model.hovering, model.hasTrack {
                HoverChrome(model: model, controller: controller, layout: layout, size: size)
                    .padding(tinted ? 0 : floatInset)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .modifier(TintedFrame(enabled: tinted, shape: shape))
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if !model.hasTrack {
            // Recent cover/mini cards are artwork-first: no extra inset, cover draws its own art edge,
            // mini sits on a capsule.
            let bare = !model.recents.isEmpty && model.connectionCount > 0 && (layout == .cover || layout == .mini)
            let inset: CGFloat = style == .tinted || bare ? 0 : 12
            let card = EmptyStateView(model: model, layout: layout,
                                      size: CGSize(width: size.width - inset * 2, height: size.height - inset * 2))
                .padding(inset)
                .frame(width: size.width, height: size.height)
            if bare && layout == .cover {
                card
            } else if layout == .mini {
                card.textBacking(Capsule())
            } else {
                card.textBacking(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
        } else {
            switch layout {
            case .cover: CoverLayout(model: model, size: size)
            case .coverLine: CoverLineLayout(model: model, size: size)
            case .lyrics: LyricsLayout(model: model, size: size)
            case .mini: MiniLayout(model: model, size: size)
            }
        }
    }
}

private struct TintedFrame<S: InsettableShape>: ViewModifier {
    let enabled: Bool
    let shape: S
    func body(content: Content) -> some View {
        if enabled {
            content.clipShape(shape).overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        } else {
            content
        }
    }
}

// MARK: - Background

struct VisualEffect: NSViewRepresentable {
    var withinWindow = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = withinWindow ? .withinWindow : .behindWindow
        v.state = .active
        // Always dark so white text stays legible over bright desktops.
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.blendingMode = withinWindow ? .withinWindow : .behindWindow
    }
}

struct Background: View {
    let accent: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.overlayPreview) private var preview

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(white: 0.1)
            } else {
                VisualEffect(withinWindow: preview)
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
    @Environment(\.overlayStyle) private var style

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
                        Color.black // opaque base: the glass/clear styles have nothing behind the artwork
                        LinearGradient(colors: [accent, accent.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(style == .tinted ? 0 : 0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(style == .tinted ? 0.25 : 0.4), radius: style == .tinted ? 6 : 5, y: 2)
    }
}

/// The current caption/lyric line with a vertical slide transition between lines, optionally followed
/// by the next line dimmed ("karaoke" preview). The whole cue list is known up front, so the preview
/// needs no extra fetching; it is absent only for unsynced text and live DOM captions.
struct CurrentLine: View {
    let model: PlayerModel
    let fontSize: CGFloat
    var lineLimit = 2
    var alignment: TextAlignment = .leading
    var showNext = false
    @Environment(\.overlayStyle) private var style

    private var frameAlignment: Alignment { alignment == .center ? .center : .leading }
    private var stackAlignment: HorizontalAlignment { alignment == .center ? .center : .leading }

    var body: some View {
        let sub = model.secondaryLine
        // The secondary track takes the preview's place: one extra line at most.
        let next = showNext && sub == nil && model.secondaryCues.isEmpty ? model.nextLine : nil
        // Instrumental gap (or before the first line): a quiet note instead of an empty slot.
        let line = model.currentLine ?? (next != nil ? "♪" : nil)
        VStack(alignment: stackAlignment, spacing: fontSize * 0.22) {
            ZStack(alignment: frameAlignment) {
                if let line {
                    Text(line)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(alignment)
                        .lineLimit(lineLimit)
                        .minimumScaleFactor(0.7)
                        .id("\(model.activeIndex ?? -1)|\(line)")
                        // Outgoing line clears quickly; incoming line rises in just after (from where the
                        // preview was), so they never overlap legibly. Short fixed curves, no text shadow:
                        // this runs every few seconds for the whole song. Fast captions swap instantly.
                        .transition(model.fastLines ? .identity : .asymmetric(
                            insertion: AnyTransition.offset(y: fontSize * 0.45).combined(with: .opacity)
                                .animation(.easeOut(duration: 0.26).delay(0.08)),
                            removal: AnyTransition.opacity.animation(.easeIn(duration: 0.1))))
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            if let sub {
                Text(sub)
                    .font(.system(size: fontSize * 0.72, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(style == .clear ? 0.85 : 0.72))
                    .multilineTextAlignment(alignment)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .id("sub|\(model.secondaryActiveIndex ?? -1)")
                    .transition(model.fastLines ? .identity : .asymmetric(
                        insertion: AnyTransition.opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
                        removal: AnyTransition.opacity.animation(.easeIn(duration: 0.08))))
            }
            if let next, next != line {
                Text(next)
                    .font(.system(size: fontSize * 0.7, weight: .semibold, design: .rounded))
                    // Clear has no backing, so the preview needs more ink to survive bright wallpapers.
                    .foregroundStyle(.white.opacity(style == .clear ? 0.62 : 0.4))
                    .multilineTextAlignment(alignment)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    // Stable identity, no transition: the preview just swaps text (its own fade cost
                    // ~0.45% CPU at lyric pace); the current line's transition carries the motion.
            }
        }
    }
}

/// Small status under the title when there is no timed text to show.
struct TextStatusChip: View {
    let model: PlayerModel
    var size: CGFloat = 11

    var body: some View {
        switch model.textStatus {
        case .loading:
            chip { HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Loading captions…") } }
        case .available:
            Button { model.connectCaptions() } label: { chip { Label("Load captions", systemImage: "captions.bubble") } }
                .buttonStyle(.plain)
        case .unsynced:
            Button { model.requestLayout?(.lyrics) } label: { chip { Label("Show lyrics", systemImage: "text.quote") } }
                .buttonStyle(.plain)
        case .none, .timed:
            EmptyView()
        }
    }

    private func chip<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.12), in: Capsule())
            .transition(.opacity)
    }
}

struct TitleBlock: View {
    let model: PlayerModel
    var titleSize: CGFloat = 13
    var lines = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if model.hasTrack && !model.isPlaying && !model.isAd {
                    Image(systemName: "pause.fill").font(.system(size: titleSize * 0.7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if model.isAd {
                    Text("AD").font(.system(size: titleSize * 0.7, weight: .heavy))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.black)
                }
                Text(model.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(lines)
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
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let tinted = style == .tinted
        ZStack(alignment: .bottom) {
            ArtworkView(image: model.artwork, accent: model.accent, radius: tinted ? 0 : corner)
                .frame(width: size.width, height: size.height)
            if tinted, model.currentLine != nil || model.hovering {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            if model.textStatus != .timed && model.textStatus != .none && !model.hovering {
                TextStatusChip(model: model, size: max(10, size.width / 22)).padding(10)
            }
            if model.currentLine != nil || model.hovering || (model.nextLine != nil && size.height >= 200) {
                VStack(alignment: .center, spacing: 6) {
                    if model.hovering { TitleBlock(model: model, titleSize: max(11, size.width / 20)) }
                    CurrentLine(model: model, fontSize: max(12, size.width / 15), lineLimit: 3, alignment: .center,
                                showNext: size.height >= 200)
                }
                .padding(.horizontal, 12).padding(.vertical, tinted ? 0 : 9)
                .textBacking(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(tinted ? 12 : 8)
            }
        }
    }
}

struct CoverLineLayout: View {
    let model: PlayerModel
    let size: CGSize
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let tinted = style == .tinted
        let art = size.height
        HStack(spacing: tinted ? 12 : 8) {
            ArtworkView(image: model.artwork, accent: model.accent, radius: tinted ? 10 : 14)
                .frame(width: art, height: art)
            VStack(alignment: .leading, spacing: 4) {
                if model.textStatus == .timed {
                    TitleBlock(model: model, titleSize: max(11, min(15, size.height / 8)))
                    Spacer(minLength: 0)
                    // Room for a preview line from ~100pt tall; the current line drops to one line when tight.
                    CurrentLine(model: model, fontSize: max(13, min(28, size.height / 4.6)),
                                lineLimit: size.height >= 130 ? 2 : 1, showNext: size.height >= 84)
                    Spacer(minLength: 0)
                } else {
                    // No timed text: let the title carry the card instead of an empty lyric slot.
                    Spacer(minLength: 0)
                    TitleBlock(model: model, titleSize: max(13, min(22, size.height / 5.5)), lines: 2)
                    TextStatusChip(model: model).padding(.top, 4)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, tinted ? 0 : 14).padding(.vertical, tinted ? 0 : 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .textBacking(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct MiniLayout: View {
    let model: PlayerModel
    let size: CGSize
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let tinted = style == .tinted
        let art = size.height - (tinted ? 0 : 12)
        HStack(spacing: 10) {
            ArtworkView(image: model.artwork, accent: model.accent, radius: art / 2)
                .frame(width: art, height: art)
            if model.currentLine != nil {
                CurrentLine(model: model, fontSize: max(12, min(20, size.height / 2.6)), lineLimit: 1)
            } else {
                Text("\(model.title) · \(model.artist)")
                    .font(.system(size: max(11, min(16, size.height / 3)), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, tinted ? -2 : 6)
        .padding(.trailing, tinted ? 8 : 16)
        .frame(width: size.width, height: size.height)
        .textBacking(Capsule())
    }
}

struct LyricsLayout: View {
    let model: PlayerModel
    let size: CGSize
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let tinted = style == .tinted
        let fs = max(14, min(30, size.width / 14))
        VStack(alignment: .leading, spacing: tinted ? 10 : 8) {
            HStack(spacing: 10) {
                ArtworkView(image: model.artwork, accent: model.accent, radius: 8)
                    .frame(width: 48, height: 48)
                TitleBlock(model: model, titleSize: 13)
                Spacer(minLength: 0)
            }
            .padding(tinted ? 0 : 8)
            .textBacking(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Group {
                if !model.cues.isEmpty {
                    LyricsList(model: model, fontSize: fs)
                } else if model.liveCaption != nil {
                    VStack {
                        Spacer(minLength: 0)
                        CurrentLine(model: model, fontSize: fs, lineLimit: 4)
                        Spacer(minLength: 0)
                    }
                } else {
                    NoTextView(model: model)
                }
            }
            .padding(.horizontal, tinted ? 0 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .textBacking(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(tinted ? 4 : 0)
    }
}

struct LyricsList: View {
    let model: PlayerModel
    let fontSize: CGFloat
    /// Last time the user scrolled the list themselves; auto-follow pauses briefly after that.
    @State private var userScrolledAt: Date = .distantPast
    @State private var lastLineChange: Date = .distantPast

    private static let anchor = UnitPoint(x: 0, y: 0.45)

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: fontSize * 0.55) {
                        // Half-viewport padding lets the first and last lines reach the center too.
                        Color.clear.frame(height: geo.size.height * 0.45)
                        // Rows are Equatable value views: a line change re-renders only the two rows whose
                        // `active` flips, not the whole list.
                        let cues = model.cues, synced = model.synced, activeIndex = model.activeIndex
                        let subs = model.secondaryByRow
                        ForEach(cues.indices, id: \.self) { i in
                            LyricRow(text: cues[i].text, sub: i < subs.count ? subs[i] : nil,
                                     active: synced && i == activeIndex, synced: synced, fontSize: fontSize)
                                .equatable()
                                .id(i)
                                .onTapGesture { if synced { model.command("seek", t: cues[i].s) } }
                        }
                        Color.clear.frame(height: geo.size.height * 0.55)
                    }
                }
                .scrollIndicators(.hidden)
                .modifier(UserScrollTracker(userScrolledAt: $userScrolledAt))
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: model.activeIndex) { _, idx in
                    let now = Date()
                    defer { lastLineChange = now }
                    guard let idx, now.timeIntervalSince(userScrolledAt) > 3 else { return }
                    // Glide for lyrics-paced text; jump when lines change faster than every 2 s
                    // (auto-generated captions), where the animation would run most of the time.
                    if !model.fastLines && now.timeIntervalSince(lastLineChange) >= 2 {
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(idx, anchor: Self.anchor) }
                    } else {
                        proxy.scrollTo(idx, anchor: Self.anchor)
                    }
                }
                // Re-center after a resize (no animation: the frame is already moving).
                .onChange(of: geo.size.height) { _, _ in
                    if let i = model.activeIndex { proxy.scrollTo(i, anchor: Self.anchor) }
                }
                .onAppear { if let i = model.activeIndex { proxy.scrollTo(i, anchor: Self.anchor) } }
            }
        }
    }
}

/// Records when the user scrolls (wheel/trackpad), so programmatic follow doesn't fight them.
private struct UserScrollTracker: ViewModifier {
    @Binding var userScrolledAt: Date
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { userScrolledAt = Date() }
            }
        } else {
            content
        }
    }
}

struct LyricRow: View, Equatable {
    let text: String
    var sub: String? = nil
    let active: Bool
    let synced: Bool
    let fontSize: CGFloat

    var body: some View {
        // Opacity only: per-line blur/scale forced an offscreen pass for every visible line
        // on every animation frame (≈14% CPU while playing).
        VStack(alignment: .leading, spacing: fontSize * 0.12) {
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
            if let sub, sub != text {
                Text(sub)
                    .font(.system(size: fontSize * 0.68, weight: .semibold, design: .rounded))
                    .opacity(0.8)
            }
        }
        // No implicit animation on `active`: it animated every visible row on each line change and
        // was ~90% of the Lyrics layout's CPU with fast captions (11% → 0.9% with it removed).
        .foregroundStyle(.white.opacity(!synced ? 0.85 : (active ? 1 : 0.32)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoTextView: View {
    let model: PlayerModel
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: model.textStatus == .loading ? "captions.bubble" : "text.badge.xmark")
                .font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
            Text(model.textStatus == .loading ? "Loading captions…"
                 : (model.site == "ytm" ? "No lyrics for this song" : "No captions for this video"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            if model.textStatus == .available || model.textStatus == .loading { TextStatusChip(model: model) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shown when nothing is playing (the overlay only appears like this when opened by hand):
/// pick up the last video, reopen a recent one, or get started.
struct EmptyStateView: View {
    let model: PlayerModel
    let layout: OverlayLayout
    let size: CGSize

    var body: some View {
        Group {
            if model.connectionCount == 0 {
                setupPrompt
            } else if let last = model.recents.first {
                switch layout {
                case .cover: RecentCover(model: model, last: last, size: size)
                case .mini: RecentMini(model: model, last: last, size: size)
                case .lyrics: RecentList(model: model)
                case .coverLine: RecentCard(model: model, last: last, size: size)
                }
            } else {
                startPrompt
            }
        }
        .onAppear { model.loadRecentThumbs() }
    }

    private var setupPrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: size.height < 90 ? 18 : 26))
                .foregroundStyle(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 3) {
                Text("Extension not connected").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                LinkChip(title: "Set Up…", systemImage: "gearshape") { model.openSetup?() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startPrompt: some View {
        VStack(spacing: 8) {
            Text("Nothing playing").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            if size.height >= 80 {
                HStack(spacing: 6) {
                    LinkChip(title: "YouTube Music", systemImage: "music.note") { NSWorkspace.shared.open(URL(string: "https://music.youtube.com")!) }
                    LinkChip(title: "YouTube", systemImage: "play.rectangle") { NSWorkspace.shared.open(URL(string: "https://www.youtube.com")!) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small capsule button used in idle/status views.
struct LinkChip: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.white.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct RecentThumb: View {
    let model: PlayerModel
    let track: RecentTrack
    var radius: CGFloat = 8
    var body: some View {
        ArtworkView(image: model.recentThumbs[track.videoId], accent: Color(white: 0.3), radius: radius)
    }
}

private struct PlayCircle: View {
    var size: CGFloat = 30
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .offset(x: size * 0.04)
                .frame(width: size, height: size)
                .background(.white.opacity(0.9), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Resume")
    }
}

/// Cover + Line: the last video with resume, and a row of older ones when there is room.
private struct RecentCard: View {
    let model: PlayerModel
    let last: RecentTrack
    let size: CGSize

    var body: some View {
        let more = Array(model.recents.dropFirst().prefix(3))
        let showMore = !more.isEmpty && size.height >= 120
        let art = showMore ? size.height * 0.52 : size.height * 0.78
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RecentThumb(model: model, track: last, radius: 10)
                    .frame(width: art, height: art)
                    .saturation(0.7).opacity(0.85)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENTLY PLAYED").font(.system(size: 9.5, weight: .bold)).kerning(0.6).foregroundStyle(.white.opacity(0.45))
                    Text(last.title).font(.system(size: max(12, min(16, size.height / 8)), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Text("\(last.artist) · \(last.ago)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 4)
                PlayCircle(size: max(26, min(34, size.height / 4))) { model.resume(last) }
            }
            if showMore {
                HStack(spacing: 6) {
                    ForEach(more) { r in
                        Button { model.resume(r) } label: {
                            HStack(spacing: 5) {
                                RecentThumb(model: model, track: r, radius: 4).frame(width: 18, height: 18)
                                Text(r.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                            }
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.trailing, 7).padding(3)
                            .background(.white.opacity(0.1), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(r.title) — \(r.artist)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Cover: the last artwork, dimmed, with a big resume button.
private struct RecentCover: View {
    let model: PlayerModel
    let last: RecentTrack
    let size: CGSize
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RecentThumb(model: model, track: last, radius: corner).saturation(0.6).opacity(0.7)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            PlayCircle(size: max(34, size.width / 5)) { model.resume(last) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                Text(last.title).font(.system(size: max(11, size.width / 18), weight: .semibold)).lineLimit(1)
                Text(last.ago).font(.system(size: max(9, size.width / 24))).opacity(0.65)
            }
            .foregroundStyle(.white).padding(12)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Mini: one tappable "resume" line.
private struct RecentMini: View {
    let model: PlayerModel
    let last: RecentTrack
    let size: CGSize
    var body: some View {
        Button { model.resume(last) } label: {
            HStack(spacing: 10) {
                RecentThumb(model: model, track: last, radius: (size.height - 12) / 2)
                    .frame(width: size.height - 12, height: size.height - 12).opacity(0.85)
                Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                Text(last.title).font(.system(size: max(11, min(15, size.height / 3.2)), weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.leading, 6).padding(.trailing, 14)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Resume \(last.title)")
    }
}

/// Lyrics: the recent list.
private struct RecentList: View {
    let model: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENTLY PLAYED").font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundStyle(.white.opacity(0.45))
            ForEach(model.recents) { r in
                Button { model.resume(r) } label: {
                    HStack(spacing: 10) {
                        RecentThumb(model: model, track: r, radius: 6).frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(r.artist) · \(r.ago)").font(.system(size: 11)).opacity(0.55).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "play.fill").font(.system(size: 11)).opacity(0.6)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Hover chrome (controls, progress, resize grip)

struct HoverChrome: View {
    let model: PlayerModel
    let controller: PanelController
    let layout: OverlayLayout
    let size: CGSize

    var body: some View {
        ZStack {
            VStack {
                HStack(spacing: 6) {
                    Spacer()
                    if model.captionTracks.count > 1 || !model.translations.isEmpty {
                        CaptionPill(model: model, compact: layout == .mini || size.height < 100)
                    }
                    Controls(model: model, compact: layout == .mini || size.height < 100)
                }
                Spacer()
            }
            .padding(8)
            if layout != .mini, let d = model.duration, d > 0 {
                VStack {
                    Spacer()
                    ProgressLine(model: model, duration: d)
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
        .modifier(ControlsBacking())
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

/// Current caption language; click to choose another track.
struct CaptionPill: View {
    let model: PlayerModel
    let compact: Bool
    var body: some View {
        Button { model.showCaptionMenu?() } label: {
            HStack(spacing: 3) {
                Image(systemName: "captions.bubble.fill")
                Text(([model.captionTrackID ?? "CC"] + (model.secondaryTrackID.map { [$0] } ?? []))
                    .map { $0.replacingOccurrences(of: ":asr", with: "·A").replacingOccurrences(of: "x-", with: "→").uppercased() }
                    .joined(separator: "+"))
            }
            .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
            .padding(.horizontal, 8).frame(height: compact ? 24 : 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .modifier(ControlsBacking())
        .help("Caption language")
    }
}

private struct ControlsBacking: ViewModifier {
    @Environment(\.overlayStyle) private var style
    func body(content: Content) -> some View {
        if style == .glass, #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
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
