import AppKit
import UniformTypeIdentifiers
import Observation
import SublineCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: PlayerModel
    private let panel: PanelController
    private let menu = NSMenu()
    private var building: NSMenu!   // menu being populated (status menu or a context menu)
    var notch: NotchController?
    /// Show the current line next to the menu bar icon.
    var menuBarLine: Bool = UserDefaults.standard.bool(forKey: "menuBarLine") {
        didSet {
            UserDefaults.standard.set(menuBarLine, forKey: "menuBarLine")
            model.setLineMirror("menuBar", on: menuBarLine)
            updateTitle()
        }
    }

    init(model: PlayerModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        super.init()
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Subline")
        item.button?.image?.isTemplate = true
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        panel.contextMenuProvider = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        item.button?.imagePosition = .imageLeading
        model.setLineMirror("menuBar", on: menuBarLine)
        trackLine()
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

    /// Keeps the menu bar title in step with the current line (a no-op while the option is off).
    private func trackLine() {
        withObservationTracking {
            _ = model.currentLine; _ = model.hasTrack; _ = model.isPlaying
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateTitle(); self?.trackLine() }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = item.button else { return }
        var title = ""
        if menuBarLine, model.hasTrack, !model.isAd {
            let line = model.currentLine.flatMap { $0.isEmpty ? nil : $0 } ?? model.title
            title = Self.fit(line, maxWidth: 260)
        }
        if button.title != title {
            button.title = title.isEmpty ? "" : " " + title
            button.alphaValue = model.isPlaying || title.isEmpty ? 1 : 0.6
        }
    }

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
            add("Skip Back 10 Seconds", #selector(skipBack))
            add("Skip Forward 10 Seconds", #selector(skipForward))
            menu.addItem(.separator())
        }

        add(panel.isVisible ? "Hide Overlay" : "Show Overlay", #selector(toggleOverlay), key: "o", mods: [.control, .option, .command])
        let autoShow = add("Show Automatically While Playing", #selector(toggleAutoPresence))
        autoShow.state = panel.autoPresence ? .on : .off
        if let native = model.native {
            let n = add("Follow Spotify and Apple Music", #selector(toggleNative))
            n.state = native.enabled ? .on : .off
            if !native.denied.isEmpty {
                let warn = NSMenuItem(title: L10n.string("    Allow in System Settings › Privacy & Security › Automation"), action: #selector(openAutomationSettings), keyEquivalent: "")
                warn.target = self
                building.addItem(warn)
            }
        }
        let ct = add("Click-Through", #selector(toggleClickThrough), key: "l", mods: [.control, .option, .command])
        ct.state = model.clickThrough ? .on : .off

        let also = NSMenuItem(title: L10n.string("Also Show Current Line"), action: nil, keyEquivalent: "")
        let am = NSMenu(); am.autoenablesItems = false
        let mb = NSMenuItem(title: L10n.string("In the Menu Bar"), action: #selector(toggleMenuBarLine), keyEquivalent: "")
        mb.target = self; mb.state = menuBarLine ? .on : .off
        am.addItem(mb)
        let nt = NSMenuItem(title: L10n.string(NotchController.targetScreen.safeAreaInsets.top > 0 ? "Under the Notch" : "At the Top of the Screen"),
                            action: #selector(toggleNotch), keyEquivalent: "")
        nt.target = self; nt.state = notch?.enabled == true ? .on : .off
        am.addItem(nt)
        also.submenu = am
        menu.addItem(also)

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
        }
        if !model.captionTracks.isEmpty || (model.synced && !model.cues.isEmpty) {
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
        let off = NSMenuItem(title: L10n.format("Sync for this song: %+.1fs", model.captionOffset), action: nil, keyEquivalent: "")
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
        if model.lyricsAvailable { addLyricsMenu(to: menu) }

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
        add("Quit Subline", #selector(quit), key: "q")
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
        off.state = model.secondaryTrackID == nil && !DerivedLines.isDerived(model.preferredSecondaryID) ? .on : .off
        m.addItem(off)
        // Made on this Mac from the main text.
        let roman = NSMenuItem(title: L10n.string("Romanization"), action: #selector(pickSecondary(_:)), keyEquivalent: "")
        roman.target = self; roman.representedObject = DerivedLines.romajiID
        roman.state = model.preferredSecondaryID == DerivedLines.romajiID ? .on : .off
        roman.isEnabled = DerivedLines.canRomanize(model.cues) || roman.state == .on
        m.addItem(roman)
        if DerivedLines.translationSupported {
            let tr = NSMenuItem(title: L10n.format("Translate on This Mac (%@)", DerivedLines.targetName), action: #selector(pickSecondary(_:)), keyEquivalent: "")
            tr.target = self; tr.representedObject = DerivedLines.translateID
            tr.state = model.preferredSecondaryID == DerivedLines.translateID ? .on : .off
            m.addItem(tr)
        }
        if DerivedLines.isDerived(model.preferredSecondaryID), let note = model.derivedNote {
            let n = NSMenuItem(title: Self.fit("    " + note, maxWidth: 320), action: #selector(downloadLanguages), keyEquivalent: "")
            n.toolTip = note; n.target = self
            n.isEnabled = model.pendingDownload != nil
            m.addItem(n)
        }
        if !model.captionTracks.isEmpty { m.addItem(.separator()) }
        for t in model.captionTracks where t.id != model.captionTrackID {
            let i = NSMenuItem(title: Self.fit(t.name), action: #selector(pickSecondary(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = t.id
            i.state = model.secondaryTrackID == t.id ? .on : .off
            m.addItem(i)
        }
        addTranslations(to: m, current: model.secondaryTrackID, action: #selector(pickSecondary(_:)),
                        excluding: model.captionTrackID)
    }

    /// LRCLIB versions of the current song: pick another (remembered per song), none, or search again.
    private func addLyricsMenu(to menu: NSMenu) {
        let item = NSMenuItem(title: L10n.string("Lyrics"), action: nil, keyEquivalent: "")
        let m = NSMenu(); m.autoenablesItems = false
        let header = NSMenuItem(title: L10n.string(model.lyricsSearching ? "Looking for lyrics…" : "Lyrics Version"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        if model.lyricsCandidates.isEmpty && !model.lyricsSearching {
            let none = NSMenuItem(title: L10n.string("No synced lyrics found"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        }
        for c in model.lyricsCandidates {
            let len = String(format: "%d:%02d", Int(c.duration) / 60, Int(c.duration) % 60)
            let full = [c.trackName, c.artistName, c.albumName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — ") + " (\(len))"
            let i = NSMenuItem(title: Self.fit(full, maxWidth: 300), action: #selector(pickLyrics(_:)), keyEquivalent: "")
            i.toolTip = full
            i.target = self; i.representedObject = c.id
            i.state = model.lyricsChosenID == c.id && model.cueSource == "lrclib" ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        let importItem = NSMenuItem(title: L10n.string("Import LRC File…"), action: #selector(importLRC), keyEquivalent: "")
        importItem.target = self
        m.addItem(importItem)
        let hide = NSMenuItem(title: L10n.string("No Lyrics for This Song"), action: #selector(pickLyrics(_:)), keyEquivalent: "")
        hide.target = self; hide.representedObject = -1
        hide.isEnabled = model.cueSource == "lrclib" && !model.cues.isEmpty
        m.addItem(hide)
        let again = NSMenuItem(title: L10n.string("Search Again"), action: #selector(searchLyricsAgain), keyEquivalent: "")
        again.target = self
        m.addItem(again)
        let credit = NSMenuItem(title: L10n.string("Lyrics from LRCLIB"), action: nil, keyEquivalent: "")
        credit.isEnabled = false
        m.addItem(credit)
        item.submenu = m
        menu.addItem(item)
    }

    @objc private func pickLyrics(_ s: NSMenuItem) {
        guard let id = s.representedObject as? Int else { return }
        model.chooseLyrics(id == -1 ? nil : id) // -1 = hide; -2 = the imported file
    }
    @objc private func searchLyricsAgain() { model.searchLyricsAgain() }

    @objc private func importLRC() {
        // Capture the song now: it may change while the panel is open.
        guard let target = model.importTarget() else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.string("Import LRC File…")
        panel.message = L10n.format("Synced lyrics for “%@”", model.title)
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
        Task { @MainActor in
            if await !model.importLyrics(text, for: target) {
                let a = NSAlert()
                a.messageText = L10n.string("No timed lines in this file")
                a.informativeText = L10n.string("An LRC file has lines like “[01:23.45] lyrics”.")
                a.runModal()
            }
        }
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

    @objc private func toggleMenuBarLine() { menuBarLine.toggle() }
    @objc private func toggleNotch() { notch?.enabled.toggle() }
    @objc private func downloadLanguages() { model.downloadTranslationLanguages() }
    @objc private func toggleNative() { model.native?.enabled.toggle() }
    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }
    @objc private func togglePlay() { model.command("toggle") }
    @objc private func next() { model.command("next") }
    @objc private func prev() { model.command("prev") }
    @objc private func skipBack() { model.skip(by: -10) }
    @objc private func skipForward() { model.skip(by: 10) }
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
        // Tell subline-host not to relaunch us until the user opens the app again.
        try? Data().write(to: SublinePaths.disabledMarker)
        NSApp.terminate(nil)
    }
}
