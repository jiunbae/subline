import AppKit
import NowPlayingCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: PlayerModel
    private let panel: PanelController
    private let menu = NSMenu()

    init(model: PlayerModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        super.init()
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Now Playing")
        item.button?.image?.isTemplate = true
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: model.hasTrack ? "\(model.title) — \(model.artist)" : "Nothing playing",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let status = NSMenuItem(title: model.connectionCount > 0 ? "● Connected to Chrome" : "○ Waiting for extension",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if model.hasTrack {
            add(model.isPlaying ? "Pause" : "Play", #selector(togglePlay))
            add("Next", #selector(next))
            add("Previous", #selector(prev))
            menu.addItem(.separator())
        }

        add(panel.isVisible ? "Hide Overlay" : "Show Overlay", #selector(toggleOverlay), key: "o", mods: [.control, .option, .command])
        let ct = add("Click-Through", #selector(toggleClickThrough), key: "l", mods: [.control, .option, .command])
        ct.state = model.clickThrough ? .on : .off

        let layout = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let lm = NSMenu()
        for l in OverlayLayout.allCases {
            let i = NSMenuItem(title: l.title, action: #selector(pickLayout(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = l.rawValue
            i.state = model.layout == l ? .on : .off
            lm.addItem(i)
        }
        layout.submenu = lm
        menu.addItem(layout)

        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let om = NSMenu()
        for v in [1.0, 0.85, 0.7, 0.5] {
            let i = NSMenuItem(title: "\(Int(v * 100))%", action: #selector(pickOpacity(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = v
            i.state = abs(model.opacity - v) < 0.01 ? .on : .off
            om.addItem(i)
        }
        op.submenu = om
        menu.addItem(op)

        // Captions
        let cap = NSMenuItem(title: "Captions", action: nil, keyEquivalent: "")
        let cm = NSMenu()
        let src = NSMenuItem(title: "Source: \(model.cueSource ?? (model.liveCaption != nil ? "on-screen" : "none"))",
                             action: nil, keyEquivalent: "")
        src.isEnabled = false
        cm.addItem(src)
        let off = NSMenuItem(title: String(format: "Delay: %+.1fs", model.captionOffset), action: nil, keyEquivalent: "")
        off.isEnabled = false
        cm.addItem(off)
        for (title, delta) in [("Earlier (−0.5s)", -0.5), ("Later (+0.5s)", 0.5)] {
            let i = NSMenuItem(title: title, action: #selector(nudge(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = delta
            cm.addItem(i)
        }
        let reset = NSMenuItem(title: "Reset Offset", action: #selector(resetOffset), keyEquivalent: "")
        reset.target = self
        cm.addItem(reset)
        cm.addItem(.separator())
        let conn = NSMenuItem(title: "Connect Captions on Current Video", action: #selector(connectCaptions), keyEquivalent: "")
        conn.target = self
        conn.isEnabled = model.hasTrack
        cm.addItem(conn)
        let autoCap = NSMenuItem(title: "Auto-Connect Captions", action: #selector(toggleAutoCaptions), keyEquivalent: "")
        autoCap.target = self
        autoCap.state = model.autoCaptions ? .on : .off
        cm.addItem(autoCap)
        cap.submenu = cm
        menu.addItem(cap)

        // Tab selection
        let tabs = model.tabs.filter { $0.track != nil }
        if tabs.count > 1 || model.pinned != nil {
            let follow = NSMenuItem(title: "Follow", action: nil, keyEquivalent: "")
            let fm = NSMenu()
            let auto = NSMenuItem(title: "Automatic (last played)", action: #selector(pickTab(_:)), keyEquivalent: "")
            auto.target = self; auto.state = model.pinned == nil ? .on : .off
            fm.addItem(auto)
            fm.addItem(.separator())
            for t in tabs {
                let title = (t.isPlaying ? "▶︎ " : "") + (t.track?.title ?? "Tab \(t.key.tab)")
                let i = NSMenuItem(title: title, action: #selector(pickTab(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = "\(t.key.conn):\(t.key.tab)"
                i.state = model.pinned == t.key ? .on : .off
                fm.addItem(i)
            }
            follow.submenu = fm
            menu.addItem(follow)
        }

        menu.addItem(.separator())
        add("Quit Now Playing", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        menu.addItem(i)
        return i
    }

    @objc private func togglePlay() { model.command("toggle") }
    @objc private func next() { model.command("next") }
    @objc private func prev() { model.command("prev") }
    @objc func toggleOverlay() { panel.toggle() }
    @objc func toggleClickThrough() { panel.setClickThrough(!model.clickThrough) }
    @objc private func pickLayout(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let l = OverlayLayout(rawValue: r) { panel.setLayout(l) }
    }
    @objc private func pickOpacity(_ s: NSMenuItem) {
        if let v = s.representedObject as? Double { panel.setOpacity(v) }
    }
    @objc private func nudge(_ s: NSMenuItem) {
        if let d = s.representedObject as? Double { model.captionOffset += d }
    }
    @objc private func resetOffset() { model.captionOffset = 0 }
    @objc private func connectCaptions() { model.connectCaptions() }
    @objc private func toggleAutoCaptions() { model.autoCaptions.toggle() }
    @objc private func pickTab(_ s: NSMenuItem) {
        guard let r = s.representedObject as? String else { model.pin(nil); return }
        let parts = r.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { model.pin(TabKey(conn: parts[0], tab: parts[1])) }
    }
    @objc private func quit() {
        // Tell np-host not to relaunch us until the user opens the app again.
        try? Data().write(to: NPPaths.disabledMarker)
        NSApp.terminate(nil)
    }
}
