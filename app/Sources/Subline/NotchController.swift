import AppKit
import SwiftUI
import Observation

/// The current line in a black "island" hanging from the MacBook notch (or from the top center of
/// a screen without one). Independent of the main overlay; clicks pass through it.
@MainActor
final class NotchController {
    private let model: PlayerModel
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var fadingOut = false

    var enabled: Bool = UserDefaults.standard.bool(forKey: "notchLine") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "notchLine")
            model.setLineMirror("notch", on: enabled)
            update()
        }
    }

    init(model: PlayerModel) {
        self.model = model
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } })
        model.setLineMirror("notch", on: enabled)
        track()
    }

    /// Re-evaluates whenever the model's track or line changes.
    private func track() {
        withObservationTracking {
            _ = model.hasTrack; _ = model.currentLine; _ = model.isPlaying
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.update(); self?.track() }
        }
        update()
    }

    private var wanted: Bool { enabled && model.hasTrack && !model.isAd }

    private func update() {
        guard wanted else {
            if let p = panel, p.isVisible, !fadingOut {
                fadingOut = true
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.fadingOut = false
                        // Wanted again during the fade: stay up.
                        if self.wanted { self.update() } else { p.orderOut(nil) }
                    }
                }
            }
            return
        }
        let p = panel ?? makePanel()
        if !p.isVisible { place(); p.alphaValue = 0; p.orderFrontRegardless() }
        if p.alphaValue < 1, !fadingOut {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar + 1 // above the menu bar, like the notch itself
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.title = L10n.string("Subline Notch")
        let host = NSHostingView(rootView: NotchView(model: model, notchHeight: 0, hasNotch: false))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    /// The built-in display if it has a notch, else the main screen.
    static var targetScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    static func notchHeight(_ s: NSScreen) -> CGFloat { max(0, s.safeAreaInsets.top) }
    static func notchWidth(_ s: NSScreen) -> CGFloat {
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea { return max(0, r.minX - l.maxX) }
        return 0
    }

    private func place() {
        guard let p = panel else { return }
        let s = Self.targetScreen
        let top = Self.notchHeight(s)
        let hasNotch = top > 0
        // With a notch: hang from it (the top part sits behind the notch). Without: a pill just
        // below the menu bar, leaving the menu bar itself alone.
        let width = hasNotch ? max(Self.notchWidth(s) + 140, 380) : 520
        let height = top + 30
        let maxY = hasNotch ? s.frame.maxY : s.visibleFrame.maxY - 6
        p.setFrame(NSRect(x: s.frame.midX - width / 2, y: maxY - height, width: width, height: height), display: true)
        (p.contentView as? NSHostingView<NotchView>)?.rootView = NotchView(model: model, notchHeight: top, hasNotch: hasNotch)
    }
}

struct NotchView: View {
    let model: PlayerModel
    let notchHeight: CGFloat
    let hasNotch: Bool

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight) // behind the notch / menu bar
            HStack(spacing: 8) {
                if let art = model.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(model.currentLine?.isEmpty == false ? model.currentLine! : model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.isPlaying ? 1 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(model.currentLine) // swap, no animation (cheap at caption pace)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if hasNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16).fill(.black)
            } else {
                Capsule().fill(.black.opacity(0.88)).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.currentLine ?? model.title)
    }
}
