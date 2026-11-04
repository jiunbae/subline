import AppKit
import SwiftUI

/// Borderless, non-activating floating panel that never steals focus.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false // we move it ourselves to support snapping
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts first click without activation and tracks hover in any state.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
}

@MainActor
final class PanelController {
    let panel = OverlayPanel()
    let model: PlayerModel
    private var hosting: OverlayHostingView<AnyView>!
    private var dragStart: (origin: NSPoint, mouse: NSPoint)?
    private var resizeStart: (frame: NSRect, mouse: NSPoint)?
    private var observers: [NSObjectProtocol] = []

    static let margin: CGFloat = 14
    static let snapDistance: CGFloat = 48

    var isVisible: Bool { panel.isVisible }

    init(model: PlayerModel) {
        self.model = model
        let root = OverlayRoot(model: model, controller: self)
        hosting = OverlayHostingView(rootView: AnyView(root))
        hosting.onHover = { [weak model] h in
            withAnimation(.easeOut(duration: 0.18)) { model?.hovering = h }
        }
        // The panel frame is owned by PanelController; don't let SwiftUI recompute window size
        // constraints on every view update (measurable per-frame cost during line transitions).
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        panel.alphaValue = model.opacity
        panel.setFrame(savedFrame(for: model.layout), display: false)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampToScreen(animate: true) }
        })
    }

    // MARK: Visibility

    func show() {
        panel.orderFrontRegardless()
        clampToScreen(animate: false)
        model.setVisible(true)
        UserDefaults.standard.set(true, forKey: "visible")
    }

    func hide() {
        panel.orderOut(nil)
        model.setVisible(false)
        UserDefaults.standard.set(false, forKey: "visible")
    }

    func toggle() { isVisible ? hide() : show() }

    func setClickThrough(_ on: Bool) {
        model.clickThrough = on
        panel.ignoresMouseEvents = on
        if on { model.hovering = false }
    }

    func setOpacity(_ v: Double) {
        model.opacity = v
        panel.animator().alphaValue = v
    }

    func setLayout(_ layout: OverlayLayout) {
        saveFrame()
        model.layout = layout
        let target = savedFrame(for: layout, anchoredTo: panel.frame)
        panel.setFrame(target, display: true, animate: panel.isVisible)
        clampToScreen(animate: false)
        panel.invalidateShadow()
    }

    // MARK: Move / resize (driven by SwiftUI gestures using screen coordinates)

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (panel.frame.origin, mouse) }
        guard let s = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
    }

    func dragEnded() {
        dragStart = nil
        snap()
    }

    func resizeChanged() {
        let mouse = NSEvent.mouseLocation
        if resizeStart == nil { resizeStart = (panel.frame, mouse) }
        guard let s = resizeStart else { return }
        let lay = model.layout
        var w = s.frame.width + (mouse.x - s.mouse.x)
        var h = s.frame.height - (mouse.y - s.mouse.y)
        w = min(max(w, lay.minSize.width), lay.maxSize.width)
        h = min(max(h, lay.minSize.height), lay.maxSize.height)
        if lay == .cover { let side = max(w, h); w = side; h = side } // keep the cover square
        // Anchor the top-left corner.
        let f = NSRect(x: s.frame.minX, y: s.frame.maxY - h, width: w, height: h)
        panel.setFrame(f, display: true)
    }

    func resizeEnded() {
        resizeStart = nil
        panel.invalidateShadow()
        snap()
    }

    // MARK: Snapping & persistence

    private var screen: NSScreen {
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func snap() {
        let vf = screen.visibleFrame.insetBy(dx: Self.margin, dy: Self.margin)
        var f = panel.frame
        let d = Self.snapDistance
        if abs(f.minX - vf.minX) < d { f.origin.x = vf.minX }
        if abs(f.maxX - vf.maxX) < d { f.origin.x = vf.maxX - f.width }
        if abs(f.minY - vf.minY) < d { f.origin.y = vf.minY }
        if abs(f.maxY - vf.maxY) < d { f.origin.y = vf.maxY - f.height }
        // Horizontal center snap for top/bottom placements.
        if abs(f.midX - vf.midX) < d / 2 { f.origin.x = vf.midX - f.width / 2 }
        f = clamp(f, to: screen.visibleFrame)
        if f != panel.frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                panel.animator().setFrame(f, display: true)
            }
        }
        saveFrame(f)
    }

    private func clamp(_ f: NSRect, to vf: NSRect) -> NSRect {
        var r = f
        r.size.width = min(r.width, vf.width)
        r.size.height = min(r.height, vf.height)
        r.origin.x = min(max(r.minX, vf.minX), vf.maxX - r.width)
        r.origin.y = min(max(r.minY, vf.minY), vf.maxY - r.height)
        return r
    }

    private func clampToScreen(animate: Bool) {
        let vf = (NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let f = clamp(panel.frame, to: vf)
        if f != panel.frame { panel.setFrame(f, display: true, animate: animate) }
    }

    private func saveFrame(_ f: NSRect? = nil) {
        UserDefaults.standard.set(NSStringFromRect(f ?? panel.frame), forKey: "frame.\(model.layout.rawValue)")
    }

    /// Restores the layout's saved size. When `anchoredTo` is given, keeps that frame's nearest corner.
    private func savedFrame(for layout: OverlayLayout, anchoredTo current: NSRect? = nil) -> NSRect {
        var size = layout.defaultSize
        var saved: NSRect?
        if let s = UserDefaults.standard.string(forKey: "frame.\(layout.rawValue)") {
            let r = NSRectFromString(s)
            if r.width >= layout.minSize.width, r.height >= layout.minSize.height { saved = r; size = r.size }
        }
        guard let cur = current else {
            if let saved { return saved }
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            return NSRect(x: vf.maxX - size.width - Self.margin, y: vf.minY + Self.margin, width: size.width, height: size.height)
        }
        let vf = screen.visibleFrame
        let right = cur.midX > vf.midX
        let top = cur.midY > vf.midY
        let x = right ? cur.maxX - size.width : cur.minX
        let y = top ? cur.maxY - size.height : cur.minY
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
