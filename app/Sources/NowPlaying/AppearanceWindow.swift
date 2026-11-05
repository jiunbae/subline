import AppKit
import SwiftUI
import ImageIO
import NowPlayingCore

/// Appearance gallery: pick a style and a layout from cards that render the real overlay views
/// (with the current song when one is playing) over the user's own wallpaper.
@MainActor
final class AppearanceWindowController: NSObject, NSWindowDelegate {
    private let model: PlayerModel
    private let panel: PanelController
    private var window: NSWindow?

    init(model: PlayerModel, panel: PanelController) {
        self.model = model
        self.panel = panel
    }

    func show() {
        if window == nil {
            let preview = PlayerModel()
            preview.loadPreview(from: model)
            let view = AppearanceView(live: model, preview: preview, panel: panel, wallpaper: Self.wallpaper())
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = L10n.string("Appearance")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil // drop previews and the wallpaper thumbnail
        window = nil
    }

    /// Downscaled current desktop picture, so glass previews refract what the user actually sees.
    static func wallpaper() -> NSImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1400,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

private struct AppearanceView: View {
    @Bindable var live: PlayerModel
    let preview: PlayerModel
    let panel: PanelController
    let wallpaper: NSImage?
    @State private var autoShow: Bool

    init(live: PlayerModel, preview: PlayerModel, panel: PanelController, wallpaper: NSImage?) {
        self.live = live; self.preview = preview; self.panel = panel; self.wallpaper = wallpaper
        _autoShow = State(initialValue: panel.autoPresence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Large preview of the current combination.
            Backdrop(wallpaper: wallpaper) {
                PreviewTile(model: preview, style: live.style, layout: live.layout, box: CGSize(width: 600, height: 230))
                    .opacity(live.opacity)
            }
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))

            section("Style") {
                ForEach(OverlayStyle.allCases) { st in
                    Card(title: st.title, subtitle: subtitle(st), selected: live.style == st, wallpaper: wallpaper) {
                        PreviewTile(model: preview, style: st, layout: live.layout, box: CGSize(width: 180, height: 92))
                    }
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { panel.setStyle(st) } }
                }
            }

            section("Layout") {
                ForEach(OverlayLayout.allCases) { l in
                    Card(title: l.title, subtitle: nil, selected: live.layout == l, wallpaper: wallpaper) {
                        PreviewTile(model: preview, style: live.style, layout: l, box: CGSize(width: 132, height: 92))
                    }
                    .onTapGesture { panel.setLayout(l) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Opacity").frame(width: 70, alignment: .leading)
                    Slider(value: Binding(get: { live.opacity }, set: { panel.setOpacity($0) }), in: 0.35...1)
                        .frame(maxWidth: 260)
                    Text("\(Int(live.opacity * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("Show the next line under the current one", isOn: $live.showNextLine)
                Toggle("Show automatically while playing", isOn: Binding(
                    get: { autoShow }, set: { autoShow = $0; panel.autoPresence = $0 }))
                Toggle("Connect YouTube captions automatically", isOn: $live.autoCaptions)
            }
            .font(.system(size: 12.5))

            Text("Tip: right-click the overlay for these options; drag any edge or corner to resize.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 20)
        .frame(width: 680)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitle(_ s: OverlayStyle) -> String {
        switch s {
        case .glass: L10n.string("Transparent, text on Liquid Glass")
        case .tinted: L10n.string("Blurred panel tinted by the artwork")
        case .clear: L10n.string("No background, shadowed text")
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string(title)).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) { content() }
        }
    }
}

/// Wallpaper (or a neutral gradient) behind previews.
private struct Backdrop<Content: View>: View {
    let wallpaper: NSImage?
    @ViewBuilder let content: Content
    var body: some View {
        // Color.clear owns the size; the wallpaper fills (center-crops) behind without proposing its own.
        Color.clear
            .frame(maxWidth: .infinity)
            .background {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.86, green: 0.62, blue: 0.52)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay { content }
            .clipped()
    }
}

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let wallpaper: NSImage?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Backdrop(wallpaper: wallpaper) { content }
                .frame(height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// The real overlay content for `layout` at its default size, scaled to fit `box`.
private struct PreviewTile: View {
    let model: PlayerModel
    let style: OverlayStyle
    let layout: OverlayLayout
    let box: CGSize

    var body: some View {
        let size = layout.defaultSize
        let scale = min(box.width / size.width, box.height / size.height, 1)
        OverlayContent(model: model, layout: layout, size: size, controller: nil)
            .environment(\.overlayStyle, style)
            .environment(\.overlayPreview, true)
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
            .allowsHitTesting(false)
    }
}
