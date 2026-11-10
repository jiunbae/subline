import AppKit
import Carbon.HIToolbox
import SublineCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()
    let server = HostServer()
    let native = NativePlayers()
    var panel: PanelController!
    var menu: StatusMenuController!
    var hotkeys: HotKeys!
    var setup: SetupWindowController!
    var appearance: AppearanceWindowController!
    var notch: NotchController!
    let launchedAt = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Marketing-asset mode: no lock, socket or menu; just one window to capture.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--store-shot"), i + 1 < args.count {
            StoreShots.show(args[i + 1])
            return
        }
        var setupError: String?
        do { try SublinePaths.ensureSupportDir() } catch { setupError = "\(SublinePaths.supportDir.path): \(error.localizedDescription)" }
        // Single instance: the flock is authoritative; only its holder may unlink/bind the socket.
        switch SublinePaths.acquireInstanceLock() {
        case .acquired: break
        case .heldByAnotherInstance:
            NSLog("Subline: another instance is running")
            exit(0)
        case let .failed(reason):
            // Not "already running": the support folder isn't usable. Say so instead of vanishing.
            let alert = NSAlert()
            alert.messageText = L10n.string("Subline can't start")
            alert.informativeText = L10n.format("Its data folder isn't writable:\n%@\n\nCheck the folder's permissions, then open the app again.", setupError ?? reason)
            alert.alertStyle = .critical
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(1)
        }
        try? FileManager.default.removeItem(at: SublinePaths.disabledMarker)
        BackgroundCursor.enable()
        NMRegistrar.registerAll()
        // Keep a previously loaded unpacked copy in sync with this app version.
        if FileManager.default.fileExists(atPath: SublinePaths.unpackedExtensionDir.path) { NMRegistrar.installUnpackedCopy() }
        setup = SetupWindowController(model: model)
        model.openSetup = { [weak self] in self?.setup.show() }

        server.onConnect = { [weak self] id in
            guard let self else { return }
            self.model.connected(id)
            UserDefaults.standard.set(true, forKey: "everConnected")
            self.server.send(.visibility(self.panel.isVisible), to: id)
            self.server.send(.requestSnapshot, to: id)
        }
        server.onDisconnect = { [weak self] id in self?.model.disconnected(id) }
        server.onMessage = { [weak self] id, msg in self?.model.handle(conn: id, msg) }
        model.send = { [weak self] msg, conn in
            if conn == NativePlayers.conn { self?.native.handle(msg) } else { self?.server.send(msg, to: conn) }
        }
        native.onMessage = { [weak self] msg in self?.model.handle(conn: NativePlayers.conn, msg) }
        model.native = native
        do { try server.start() } catch {
            NSLog("Subline: socket failed: %@", "\(error)")
            Diagnostics.shared.socketError = "\(error)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.setup.show() } // surface it
        }

        panel = PanelController(model: model)
        menu = StatusMenuController(model: model, panel: panel)
        notch = NotchController(model: model)
        menu.notch = notch
        appearance = AppearanceWindowController(model: model, panel: panel)
        model.openAppearance = { [weak self] in self?.appearance.show() }
        model.onPresence = { [weak self] hasTrack, playing, videoId in
            self?.panel.presence(hasTrack: hasTrack, playing: playing, videoId: videoId)
            if hasTrack, !UserDefaults.standard.bool(forKey: "everConnected") { UserDefaults.standard.set(true, forKey: "everConnected") }
        }
        panel.start()
        native.start()
        if CommandLine.arguments.contains("--appearance") { appearance.show() }
        if CommandLine.arguments.contains("--setup-demo") { setup.show() }
        // First run (no extension has ever connected): show the setup checklist instead of an empty overlay.
        if !UserDefaults.standard.bool(forKey: "everConnected") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Spotify/Music listeners need no extension: something already playing counts as set up.
                guard let self, self.model.connectionCount == 0, !self.model.hasTrack else { return }
                self.setup.show()
            }
        }

        hotkeys = HotKeys()
        hotkeys.register(keyCode: kVK_ANSI_O) { [weak self] in self?.panel.toggle() }
        hotkeys.register(keyCode: kVK_ANSI_L) { [weak self] in
            guard let self else { return }
            self.panel.setClickThrough(!self.model.clickThrough)
        }
        hotkeys.register(keyCode: kVK_Space) { [weak self] in self?.model.command("toggle") }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it runs shows the setup window,
    /// which doubles as the "is it working?" status page.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // subline-host launches us with `open -g`; when several browsers race, the later ones arrive as a
        // reopen right after launch. Only treat it as the user opening the app after that window.
        guard ProcessInfo.processInfo.systemUptime - launchedAt > 5 else { return false }
        setup.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }
}

// `Subline landing-media <dir> [film|loop|preview]` renders the landing page's media offscreen and
// exits (LandingMedia/LandingMediaMode.swift); no lock, socket, menu or migration.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "landing-media" {
    let code = MainActor.assumeIsolated {
        LandingMediaMode.run(outputDir: CommandLine.arguments[2], only: Set(CommandLine.arguments.dropFirst(3)))
    }
    exit(code)
}

// Before anything reads preferences (PlayerModel and friends load them when the delegate is built).
if !CommandLine.arguments.contains("--store-shot") { LegacyMigration.run() }
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
