import AppKit
import NowPlayingCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: PlayerModel
    private let panel: PanelController
    private let menu = NSMenu()
    private var building: NSMenu!   // menu being populated (status menu or a context menu)

    init(model: PlayerModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        super.init()
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Now Playing")
        item.button?.image?.isTemplate = true
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        panel.contextMenuProvider = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        model.showCaptionMenu = { [weak self] in
            guard let self else { return }
            let m = NSMenu(); m.autoenablesItems = false
            self.addCaptionLanguages(to: m)
            m.addItem(.separator())
            self.addSecondaryLanguages(to: m)
            m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    /// Right-click menu on the overlay: the same items as the menu bar.
    func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        populate(m)
        return m
    }

    private func populate(_ menu: NSMenu) {
        building = menu
        menu.removeAllItems()

        let full = model.hasTrack ? L10n.format("%@ — %@", model.title, model.artist) : L10n.string("Nothing playing")
        let header = NSMenuItem(title: Self.fit(full), action: nil, keyEquivalent: "")
        header.toolTip = full
        header.isEnabled = false
        menu.addItem(header)
        if model.connectionCount > 0 {
            let status = NSMenuItem(title: L10n.string("● Connected to Chrome"), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            if let old = model.extensionOutdated {
                // Unpacked extensions keep running old code until reloaded in the browser.
                let warn = NSMenuItem(title: L10n.format("⚠︎ Extension %@ outdated (%@ available)", old.running, old.bundled),
                                      action: nil, keyEquivalent: "")
                warn.isEnabled = false
                menu.addItem(warn)
                let how = NSMenuItem(title: L10n.string("    Reload it in the browser's Extensions page"),
                                     action: nil, keyEquivalent: "")
                how.isEnabled = false
                menu.addItem(how)
            }
        } else {
            add("Set Up Chrome Extension…", #selector(openSetup))
        }
        menu.addItem(.separator())

        if model.hasTrack {
            add(model.isPlaying ? "Pause" : "Play", #selector(togglePlay))
            add("Next", #selector(next))
            add("Previous", #selector(prev))
            menu.addItem(.separator())
        }

        add(panel.isVisible ? "Hide Overlay" : "Show Overlay", #selector(toggleOverlay), key: "o", mods: [.control, .option, .command])
        let autoShow = add("Show Automatically While Playing", #selector(toggleAutoPresence))
        autoShow.state = panel.autoPresence ? .on : .off
        let ct = add("Click-Through", #selector(toggleClickThrough), key: "l", mods: [.control, .option, .command])
        ct.state = model.clickThrough ? .on : .off

        let layout = NSMenuItem(title: L10n.string("Layout"), action: nil, keyEquivalent: "")
        let lm = NSMenu()
        for l in OverlayLayout.allCases {
            let i = NSMenuItem(title: l.title, action: #selector(pickLayout(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = l.rawValue
            i.state = model.layout == l ? .on : .off
            lm.addItem(i)
        }
        layout.submenu = lm
        menu.addItem(layout)

        let style = NSMenuItem(title: L10n.string("Style"), action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for st in OverlayStyle.allCases {
            let i = NSMenuItem(title: st.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = st.rawValue
            i.state = model.style == st ? .on : .off
            sm.addItem(i)
        }
        style.submenu = sm
        menu.addItem(style)
        add("Appearance…", #selector(openAppearance), key: ",")

        let op = NSMenuItem(title: L10n.string("Opacity"), action: nil, keyEquivalent: "")
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
        let cap = NSMenuItem(title: L10n.string("Captions"), action: nil, keyEquivalent: "")
        let cm = NSMenu()
        if !model.captionTracks.isEmpty {
            let lang = NSMenuItem(title: L10n.string("Language"), action: nil, keyEquivalent: "")
            let lm = NSMenu(); lm.autoenablesItems = false
            addCaptionLanguages(to: lm)
            lang.submenu = lm
            cm.addItem(lang)
            let second = NSMenuItem(title: L10n.string("Second Language"), action: nil, keyEquivalent: "")
            let sm2 = NSMenu(); sm2.autoenablesItems = false
            addSecondaryLanguages(to: sm2)
            second.submenu = sm2
            cm.addItem(second)
            cm.addItem(.separator())
        }
        let source = L10n.string(model.cueSource ?? (model.liveCaption != nil ? "on-screen" : "none"))
        let src = NSMenuItem(title: L10n.format("Source: %@", source),
                             action: nil, keyEquivalent: "")
        src.isEnabled = false
        cm.addItem(src)
        let off = NSMenuItem(title: L10n.format("Delay: %+.1fs", model.captionOffset), action: nil, keyEquivalent: "")
        off.isEnabled = false
        cm.addItem(off)
        for (title, delta) in [("Earlier (−0.5s)", -0.5), ("Later (+0.5s)", 0.5)] {
            let i = NSMenuItem(title: L10n.string(title), action: #selector(nudge(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = delta
            cm.addItem(i)
        }
        let reset = NSMenuItem(title: L10n.string("Reset Offset"), action: #selector(resetOffset), keyEquivalent: "")
        reset.target = self
        cm.addItem(reset)
        cm.addItem(.separator())
        let conn = NSMenuItem(title: L10n.string("Connect Captions on Current Video"), action: #selector(connectCaptions), keyEquivalent: "")
        conn.target = self
        conn.isEnabled = model.hasTrack
        cm.addItem(conn)
        let autoCap = NSMenuItem(title: L10n.string("Auto-Connect Captions"), action: #selector(toggleAutoCaptions), keyEquivalent: "")
        autoCap.target = self
        autoCap.state = model.autoCaptions ? .on : .off
        cm.addItem(autoCap)
        let nextLine = NSMenuItem(title: L10n.string("Show Next Line"), action: #selector(toggleNextLine), keyEquivalent: "")
        nextLine.target = self
        nextLine.state = model.showNextLine ? .on : .off
        cm.addItem(nextLine)
        cap.submenu = cm
        menu.addItem(cap)

        // Tab selection
        let tabs = model.tabs.filter { $0.track != nil }
        if tabs.count > 1 || model.pinned != nil {
            let follow = NSMenuItem(title: L10n.string("Follow"), action: nil, keyEquivalent: "")
            let fm = NSMenu()
            let auto = NSMenuItem(title: L10n.string("Automatic (last played)"), action: #selector(pickTab(_:)), keyEquivalent: "")
            auto.target = self; auto.state = model.pinned == nil ? .on : .off
            fm.addItem(auto)
            fm.addItem(.separator())
            for t in tabs {
                let title = (t.isPlaying ? "▶︎ " : "") + (t.track?.title ?? L10n.format("Tab %d", t.key.tab))
                let i = NSMenuItem(title: Self.fit(title), action: #selector(pickTab(_:)), keyEquivalent: "")
                i.toolTip = title
                i.target = self; i.representedObject = "\(t.key.conn):\(t.key.tab)"
                i.state = model.pinned == t.key ? .on : .off
                fm.addItem(i)
            }
            follow.submenu = fm
            menu.addItem(follow)
        }

        if !model.recents.isEmpty {
            let rec = NSMenuItem(title: L10n.string("Recently Played"), action: nil, keyEquivalent: "")
            let rm = NSMenu(); rm.autoenablesItems = false
            for r in model.recents {
                let i = NSMenuItem(title: Self.fit(L10n.format("%@ — %@", r.title, r.artist)), action: #selector(resumeRecent(_:)), keyEquivalent: "")
                i.toolTip = L10n.format("%@ — %@ · %@", r.title, r.artist, r.ago)
                i.target = self; i.representedObject = r.videoId
                rm.addItem(i)
            }
            rm.addItem(.separator())
            let clear = NSMenuItem(title: L10n.string("Clear Recently Played"), action: #selector(clearRecents), keyEquivalent: "")
            clear.target = self
            rm.addItem(clear)
            rec.submenu = rm
            menu.addItem(rec)
        }
        menu.addItem(.separator())
        if model.connectionCount > 0 { add("Setup…", #selector(openSetup)) }
        add("Quit Now Playing", #selector(quit), key: "q")
    }

    /// Caption tracks of the current video; the shown one is checked.
    private func addCaptionLanguages(to m: NSMenu) {
        let header = NSMenuItem(title: L10n.string("Caption Language"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        for t in model.captionTracks {
            let i = NSMenuItem(title: Self.fit(t.name), action: #selector(pickCaption(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = t.id
            i.state = model.captionTrackID == t.id ? .on : .off
            m.addItem(i)
        }
        addTranslations(to: m, current: model.captionTrackID, action: #selector(pickCaption(_:)))
    }

    /// "Auto-translate ▸" submenu: the user's system languages first, then everything YouTube offers.
    private func addTranslations(to m: NSMenu, current: String?, action: Selector, excluding: String? = nil) {
        let translations = model.translations.filter { $0.id != excluding }
        guard !translations.isEmpty else { return }
        let item = NSMenuItem(title: L10n.string("Auto-translate"), action: nil, keyEquivalent: "")
        let sub = NSMenu(); sub.autoenablesItems = false
        let preferred = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        let top = preferred.compactMap { code in translations.first { $0.lang == code || $0.lang.hasPrefix(code + "-") } }
        func add(_ t: CaptionTrack) {
            let i = NSMenuItem(title: Self.fit(t.name), action: action, keyEquivalent: "")
            i.target = self; i.representedObject = t.id
            i.state = current == t.id ? .on : .off
            sub.addItem(i)
        }
        var seen = Set<String>()
        for t in top where seen.insert(t.id).inserted { add(t) }
        if !seen.isEmpty { sub.addItem(.separator()) }
        for t in translations where !seen.contains(t.id) { add(t) }
        item.submenu = sub
        if current?.hasPrefix("x-") == true { item.state = .on }
        m.addItem(item)
    }

    /// Second caption track shown under the main one; the main track itself is not offered.
    private func addSecondaryLanguages(to m: NSMenu) {
        let header = NSMenuItem(title: L10n.string("Second Language"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        let off = NSMenuItem(title: L10n.string("None"), action: #selector(pickSecondary(_:)), keyEquivalent: "")
        off.target = self; off.representedObject = ""
        off.state = model.secondaryTrackID == nil ? .on : .off
        m.addItem(off)
        for t in model.captionTracks where t.id != model.captionTrackID {
            let i = NSMenuItem(title: Self.fit(t.name), action: #selector(pickSecondary(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = t.id
            i.state = model.secondaryTrackID == t.id ? .on : .off
            m.addItem(i)
        }
        addTranslations(to: m, current: model.secondaryTrackID, action: #selector(pickSecondary(_:)),
                        excluding: model.captionTrackID)
    }

    @objc private func resumeRecent(_ s: NSMenuItem) {
        if let id = s.representedObject as? String, let r = model.recents.first(where: { $0.videoId == id }) { model.resume(r) }
    }
    @objc private func clearRecents() { model.clearRecents() }

    @objc private func pickSecondary(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        model.selectSecondary(id.isEmpty ? nil : id)
    }

    @objc private func pickCaption(_ s: NSMenuItem) {
        if let id = s.representedObject as? String { model.selectCaptions(id) }
    }

    /// Menus grow to their widest item; long video titles are cut to `maxWidth` points (menu font)
    /// with a trailing ellipsis. The full text goes in the item's tooltip.
    static func fit(_ s: String, maxWidth: CGFloat = 240) -> String {
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
        guard width(s) > maxWidth else { return s }
        let chars = Array(s)
        var lo = 0, hi = chars.count
        while lo < hi { // longest prefix that fits with the ellipsis
            let mid = (lo + hi + 1) / 2
            if width(String(chars[..<mid]).trimmingCharacters(in: .whitespaces) + "…") <= maxWidth { lo = mid } else { hi = mid - 1 }
        }
        return String(chars[..<lo]).trimmingCharacters(in: .whitespaces) + "…"
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: L10n.string(title), action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        building.addItem(i)
        return i
    }

    @objc private func togglePlay() { model.command("toggle") }
    @objc private func next() { model.command("next") }
    @objc private func prev() { model.command("prev") }
    @objc func toggleOverlay() { panel.toggle() }
    @objc private func toggleAutoPresence() { panel.autoPresence.toggle() }
    @objc private func openSetup() { model.openSetup?() }
    @objc func toggleClickThrough() { panel.setClickThrough(!model.clickThrough) }
    @objc private func pickLayout(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let l = OverlayLayout(rawValue: r) { panel.setLayout(l) }
    }
    @objc private func pickStyle(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let st = OverlayStyle(rawValue: r) { panel.setStyle(st) }
    }
    @objc private func openAppearance() { model.openAppearance?() }
    @objc private func pickOpacity(_ s: NSMenuItem) {
        if let v = s.representedObject as? Double { panel.setOpacity(v) }
    }
    @objc private func nudge(_ s: NSMenuItem) {
        if let d = s.representedObject as? Double { model.captionOffset += d }
    }
    @objc private func resetOffset() { model.captionOffset = 0 }
    @objc private func connectCaptions() { model.connectCaptions() }
    @objc private func toggleAutoCaptions() { model.autoCaptions.toggle() }
    @objc private func toggleNextLine() { model.showNextLine.toggle() }
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
