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
        title = L10n.string("Now Playing Overlay") // never drawn (borderless); names the window for accessibility/automation
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Which window edges a resize drag moves.
struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1), right = ResizeEdges(rawValue: 2)
    static let bottom = ResizeEdges(rawValue: 4), top = ResizeEdges(rawValue: 8)
}

/// Hosting view that accepts first click without activation, tracks hover in any state, resizes
/// from every edge and corner, and shows the overlay's context menu.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    var onResize: ((ResizeEdges, NSPoint) -> Void)?      // (edges, mouse in screen coords) while dragging
    var onResizeBegan: ((ResizeEdges, NSPoint) -> Void)?
    var onResizeEnded: ((ResizeEdges) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private var area: NSTrackingArea?
    private var cursorEdges: ResizeEdges = []
    private var resizing = false

    /// Grab band along each edge. Wider for the transparent styles, whose visible card is inset
    /// from the window edge (see `floatInset`).
    var edgeThickness: CGFloat = 8
    static var cornerSize: CGFloat { 18 }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
        // The hover controls fade in right after entering and SwiftUI resets the cursor while they
        // appear; re-apply ours once they're in (entering straight onto an edge is the common case).
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.resizing else { return }
                let e = self.edgesUnderMouse()
                self.cursorEdges = []      // force: the system cursor may no longer be ours
                self.applyCursor(e)
            }
        }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !resizing { applyCursor([]) }
        onHover?(false)
    }

    /// Edges under `p` (view coordinates). NSHostingView is flipped (y grows downward), so "top" is
    /// measured from minY there; computing it in unflipped terms keeps top and bottom the right way up.
    func edges(at p: NSPoint) -> ResizeEdges {
        let b = bounds, t = edgeThickness, c = Self.cornerSize
        guard b.contains(p) else { return [] }
        let fromLeft = p.x - b.minX, fromRight = b.maxX - p.x
        let fromBottom = isFlipped ? b.maxY - p.y : p.y - b.minY
        let fromTop = isFlipped ? p.y - b.minY : b.maxY - p.y
        let nearL = fromLeft < t, nearR = fromRight < t, nearB = fromBottom < t, nearT = fromTop < t
        // Corners get a larger target along both edges.
        let cornerL = fromLeft < c, cornerR = fromRight < c, cornerB = fromBottom < c, cornerT = fromTop < c
        var e: ResizeEdges = []
        if nearL || ((nearB || nearT) && cornerL) { e.insert(.left) }
        if nearR || ((nearB || nearT) && cornerR) { e.insert(.right) }
        if nearB || ((nearL || nearR) && cornerB) { e.insert(.bottom) }
        if nearT || ((nearL || nearR) && cornerT) { e.insert(.top) }
        if e.contains(.left) && e.contains(.right) { e.remove(fromLeft < fromRight ? .right : .left) }   // tiny windows
        if e.contains(.top) && e.contains(.bottom) { e.remove(fromTop < fromBottom ? .bottom : .top) }
        return e
    }

    private func edgesUnderMouse() -> ResizeEdges {
        guard let window else { return [] }
        return edges(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    // SwiftUI resets the cursor from its own tracking areas, so re-apply ours on every move and
    // cursor update instead of caching the last one.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if !resizing { applyCursor(edges(at: convert(event.locationInWindow, from: nil))) }
    }
    override func cursorUpdate(with event: NSEvent) {
        let e = resizing ? cursorEdges : edgesUnderMouse()
        if e.isEmpty { super.cursorUpdate(with: event) } else { applyCursor(e) }
    }

    private func applyCursor(_ e: ResizeEdges) {
        let changed = e != cursorEdges
        cursorEdges = e
        if e.isEmpty { if changed { NSCursor.arrow.set() }; return }
        Self.cursor(for: e).set()
    }

    static func cursor(for e: ResizeEdges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let pos: NSCursor.FrameResizePosition
            switch (e.contains(.left), e.contains(.right), e.contains(.top), e.contains(.bottom)) {
            case (true, _, true, _): pos = .topLeft
            case (_, true, true, _): pos = .topRight
            case (true, _, _, true): pos = .bottomLeft
            case (_, true, _, true): pos = .bottomRight
            case (true, _, _, _): pos = .left
            case (_, true, _, _): pos = .right
            case (_, _, true, _): pos = .top
            default: pos = .bottom
            }
            return NSCursor.frameResize(position: pos, directions: .all)
        }
        if e == [.left] || e == [.right] { return .resizeLeftRight }
        if e == [.top] || e == [.bottom] { return .resizeUpDown }
        return .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        let e = edges(at: convert(event.locationInWindow, from: nil))
        guard !e.isEmpty, let window else { super.mouseDown(with: event); return }
        // Own tracking loop: SwiftUI never sees this drag, so it can't also start a move.
        resizing = true
        applyCursor(e)
        onResizeBegan?(e, window.convertPoint(toScreen: event.locationInWindow))
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            // The event's own position (not the global pointer): also correct for synthesized input.
            onResize?(e, window.convertPoint(toScreen: next.locationInWindow))
            Self.cursor(for: e).set() // keep the resize cursor even when the pointer outruns the window
        }
        resizing = false
        onResizeEnded?(e)
        applyCursor(edgesUnderMouse())
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() ?? super.menu(for: event) }
}

@MainActor
final class PanelController {
    let panel = OverlayPanel()
    let model: PlayerModel
    private var hosting: OverlayHostingView<AnyView>!
    private var dragStart: (origin: NSPoint, mouse: NSPoint)?
    private var observers: [NSObjectProtocol] = []

    static let margin: CGFloat = 14
    /// Transparent styles inset their card by 6 pt, so the band reaches ~6 pt into the visible card.
    static func edgeThickness(for style: OverlayStyle) -> CGFloat { style == .tinted ? 8 : 12 }
    static let snapDistance: CGFloat = 48

    var isVisible: Bool { panel.isVisible }
    /// Builds the right-click menu (provided by the status menu controller).
    var contextMenuProvider: (() -> NSMenu)?

    func setStyle(_ style: OverlayStyle) {
        model.style = style
        hosting.edgeThickness = Self.edgeThickness(for: style)
        // Transparent styles draw their own shadows per piece; a window shadow would outline the empty frame.
        panel.hasShadow = style == .tinted
        panel.invalidateShadow()
    }

    init(model: PlayerModel) {
        self.model = model
        let root = OverlayRoot(model: model, controller: self)
        hosting = OverlayHostingView(rootView: AnyView(root))
        hosting.onHover = { [weak model] h in
            withAnimation(.easeOut(duration: 0.18)) { model?.hovering = h }
        }
        hosting.onResizeBegan = { [weak self] _, mouse in self?.beginResize(at: mouse) }
        hosting.onResize = { [weak self] edges, mouse in self?.resize(edges, to: mouse) }
        hosting.onResizeEnded = { [weak self] edges in self?.endResize(edges) }
        hosting.contextMenu = { [weak self] in self?.contextMenuProvider?() }
        model.requestLayout = { [weak self] l in self?.setLayout(l) }
        // The panel frame is owned by PanelController; don't let SwiftUI recompute window size
        // constraints on every view update (measurable per-frame cost during line transitions).
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        panel.alphaValue = model.opacity
        // Capture clicks over the whole frame (incl. transparent gaps in the glass styles) so every
        // edge stays resizable and draggable.
        panel.ignoresMouseEvents = false
        panel.hasShadow = model.style == .tinted
        hosting.edgeThickness = Self.edgeThickness(for: model.style)
        panel.setFrame(savedFrame(for: model.layout), display: false)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampToScreen(animate: true) }
        })
    }

    // MARK: Visibility
    //
    // Auto mode (default): the overlay appears when playback starts and fades out when the tab goes
    // away (after a short grace) or stays paused for a while. A manual hide snoozes it for the current
    // video; a manual show keeps it up until playback next starts.

    var autoPresence: Bool = UserDefaults.standard.object(forKey: "autoPresence") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoPresence, forKey: "autoPresence")
            snoozedVideo = nil; manualShown = false
            presence(hasTrack: model.hasTrack, playing: model.isPlaying, videoId: lastVideo)
        }
    }
    static let pausedHideDelay: TimeInterval = 300
    static let goneHideDelay: TimeInterval = 2.5

    private var snoozedVideo: String?
    private var manualShown = false
    private var lastVideo: String?
    private var hideWork: DispatchWorkItem?
    private var hideDeadline: Date?
    private var fadeGeneration = 0
    private var fadingOut = false

    /// Initial visibility at launch.
    func start() {
        if autoPresence { return } // shown once something plays
        if UserDefaults.standard.object(forKey: "visible") as? Bool ?? true { show(animated: false) }
    }

    func presence(hasTrack: Bool, playing: Bool, videoId: String?) {
        if videoId != nil, videoId != lastVideo {
            lastVideo = videoId
            if snoozedVideo != nil, snoozedVideo != videoId { snoozedVideo = nil }
        }
        guard autoPresence, snoozedVideo == nil else { return }
        if hasTrack && playing {
            manualShown = false
            cancelHide()
            // Show only when hidden or fading out. Re-showing during the fade-in restarted the animation
            // and re-broadcast visibility on every incoming message: an app↔extension loop measured at
            // ~1,500 messages/s and ~90% CPU for tens of seconds after playback started.
            if !isVisible || fadingOut { show(animated: true) }
        } else if manualShown {
            return
        } else if isVisible {
            scheduleHide(after: hasTrack ? Self.pausedHideDelay : Self.goneHideDelay)
        }
    }

    /// Menu / hotkey.
    func toggle() {
        if isVisible {
            snoozedVideo = lastVideo ?? ""
            manualShown = false
            hide(animated: true)
        } else {
            snoozedVideo = nil
            manualShown = true
            show(animated: true)
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        let deadline = Date().addingTimeInterval(delay)
        if let d = hideDeadline, d <= deadline { return } // an earlier hide is already pending
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil; self.hideDeadline = nil
            self.hide(animated: true)
        }
        hideWork = work; hideDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel(); hideWork = nil; hideDeadline = nil
    }

    func show(animated: Bool = false) {
        cancelHide()
        fadeGeneration += 1
        fadingOut = false
        let target = CGFloat(model.opacity)
        if !panel.isVisible {
            clampToScreen(animate: false)
            panel.alphaValue = animated ? 0 : target
            panel.orderFrontRegardless()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                panel.animator().alphaValue = target
            }
        } else {
            panel.alphaValue = target
        }
        model.setVisible(true)
        UserDefaults.standard.set(true, forKey: "visible")
    }

    func hide(animated: Bool = false) {
        cancelHide()
        fadeGeneration += 1
        let gen = fadeGeneration
        model.setVisible(false)
        UserDefaults.standard.set(false, forKey: "visible")
        guard animated, panel.isVisible else { panel.orderOut(nil); return }
        fadingOut = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == gen else { return } // re-shown meanwhile
                self.fadingOut = false
                self.panel.orderOut(nil)
                self.panel.alphaValue = CGFloat(self.model.opacity)
            }
        })
    }

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

    private var resizeFrom: (frame: NSRect, mouse: NSPoint)?

    func beginResize(at mouse: NSPoint) { resizeFrom = (panel.frame, mouse) }

    /// Moves only the dragged edges; the opposite edges stay put. Cover stays square.
    func resize(_ edges: ResizeEdges, to mouse: NSPoint) {
        guard let s = resizeFrom else { return }
        let lay = model.layout
        let dx = mouse.x - s.mouse.x, dy = mouse.y - s.mouse.y
        var w = s.frame.width, h = s.frame.height
        if edges.contains(.right) { w += dx }
        if edges.contains(.left) { w -= dx }
        if edges.contains(.top) { h += dy }
        if edges.contains(.bottom) { h -= dy }
        if lay == .cover {
            let horizontal = edges.contains(.left) || edges.contains(.right)
            let vertical = edges.contains(.top) || edges.contains(.bottom)
            let side = horizontal && vertical ? max(w, h) : (horizontal ? w : h)
            w = side; h = side
        }
        // Dragged edges stop at the screen edge, so nothing needs to be pushed back on release
        // (pushing back moved the whole window and made the opposite edge jump).
        let mf = Self.movableFrame(screenFor(s.frame))
        if edges.contains(.right) { w = min(w, mf.maxX - s.frame.minX) }
        if edges.contains(.left) { w = min(w, s.frame.maxX - mf.minX) }
        if edges.contains(.top) { h = min(h, mf.maxY - s.frame.minY) }
        if edges.contains(.bottom) { h = min(h, s.frame.maxY - mf.minY) }
        if lay == .cover { let side = min(w, h); w = side; h = side }
        w = min(max(w, lay.minSize.width), lay.maxSize.width)
        h = min(max(h, lay.minSize.height), lay.maxSize.height)
        let x = edges.contains(.left) ? s.frame.maxX - w : s.frame.minX
        let y = edges.contains(.bottom) ? s.frame.maxY - h : s.frame.minY
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    /// Snaps only the edges that were dragged; the window never jumps as a whole after a resize.
    func endResize(_ edges: ResizeEdges) {
        resizeFrom = nil
        let vf = screen.visibleFrame.insetBy(dx: Self.margin, dy: Self.margin)
        let lay = model.layout
        var f = panel.frame
        let d = Self.snapDistance / 2
        if edges.contains(.left), abs(f.minX - vf.minX) < d { f.size.width += f.minX - vf.minX; f.origin.x = vf.minX }
        if edges.contains(.right), abs(f.maxX - vf.maxX) < d { f.size.width = vf.maxX - f.minX }
        if edges.contains(.bottom), abs(f.minY - vf.minY) < d { f.size.height += f.minY - vf.minY; f.origin.y = vf.minY }
        if edges.contains(.top), abs(f.maxY - vf.maxY) < d { f.size.height = vf.maxY - f.minY }
        if lay == .cover || f.width < lay.minSize.width || f.height < lay.minSize.height || f.width > lay.maxSize.width || f.height > lay.maxSize.height {
            f = panel.frame // keep the cover square and the size limits exact
        }
        f = clamp(f, to: Self.movableFrame(screen))
        // Instant, not animated: during an animated frame change the tracking areas are in flux, and a
        // pointer that immediately re-grabs an edge could miss it (start a move) or keep a stale cursor.
        if f != panel.frame { panel.setFrame(f, display: true, animate: false) }
        panel.invalidateShadow()
        saveFrame(f)
    }

    // MARK: Snapping & persistence

    /// The screen containing the frame's center, else the nearest one: a window dragged past the
    /// outer edge of a display stays on that display instead of jumping to the main screen.
    private func screenFor(_ f: NSRect) -> NSScreen {
        let c = NSPoint(x: f.midX, y: f.midY)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(c) }) { return s }
        func distance(_ r: NSRect) -> CGFloat {
            let dx = max(r.minX - c.x, 0, c.x - r.maxX), dy = max(r.minY - c.y, 0, c.y - r.maxY)
            return dx * dx + dy * dy
        }
        return NSScreen.screens.min { distance($0.frame) < distance($1.frame) } ?? NSScreen.screens[0]
    }

    private var screen: NSScreen { screenFor(panel.frame) }

    /// Where the overlay may sit: the whole screen below the menu bar. Unlike `visibleFrame` this
    /// includes the Dock area, so a PiP can be parked over (or below the level of) the Dock.
    static func movableFrame(_ s: NSScreen) -> NSRect {
        var f = s.frame
        f.size.height = s.visibleFrame.maxY - f.minY
        return f
    }

    /// Snaps to the nearest of: just inside the Dock/visible area, or the true screen edge.
    private func snap() {
        let scr = screen
        let vis = scr.visibleFrame.insetBy(dx: Self.margin, dy: Self.margin)
        let full = Self.movableFrame(scr).insetBy(dx: Self.margin, dy: Self.margin)
        // Clamp first: a window dragged past the screen edge should still snap to the margin.
        var f = clamp(panel.frame, to: Self.movableFrame(scr))
        let d = Self.snapDistance
        func nearest(_ value: CGFloat, _ targets: [CGFloat]) -> CGFloat? {
            targets.map { ($0, abs(value - $0)) }.filter { $0.1 < d }.min { $0.1 < $1.1 }?.0
        }
        if let x = nearest(f.minX, [vis.minX, full.minX]) { f.origin.x = x }
        else if let x = nearest(f.maxX, [vis.maxX, full.maxX]) { f.origin.x = x - f.width }
        if let y = nearest(f.minY, [vis.minY, full.minY]) { f.origin.y = y }
        else if let y = nearest(f.maxY, [vis.maxY]) { f.origin.y = y - f.height }
        // Horizontal center snap for top/bottom placements.
        if abs(f.midX - vis.midX) < d / 2 { f.origin.x = vis.midX - f.width / 2 }
        f = clamp(f, to: Self.movableFrame(scr))
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
        let f = clamp(panel.frame, to: Self.movableFrame(screenFor(panel.frame)))
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
