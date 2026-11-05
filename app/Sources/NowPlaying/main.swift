import AppKit
import Carbon.HIToolbox
import NowPlayingCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()
    let server = HostServer()
    var panel: PanelController!
    var menu: StatusMenuController!
    var hotkeys: HotKeys!
    var setup: SetupWindowController!
    var appearance: AppearanceWindowController!
    let launchedAt = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Marketing-asset mode: no lock, socket or menu; just one window to capture.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--store-shot"), i + 1 < args.count {
            StoreShots.show(args[i + 1])
            return
        }
        try? NPPaths.ensureSupportDir()
        // Single instance: the flock is authoritative; only its holder may unlink/bind the socket.
        if !NPPaths.acquireInstanceLock() {
            NSLog("NowPlaying: another instance is running")
            exit(0)
        }
        try? FileManager.default.removeItem(at: NPPaths.disabledMarker)
        BackgroundCursor.enable()
        NMRegistrar.registerAll()
        // Keep a previously loaded unpacked copy in sync with this app version.
        if FileManager.default.fileExists(atPath: NPPaths.unpackedExtensionDir.path) { NMRegistrar.installUnpackedCopy() }
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
        model.send = { [weak self] msg, conn in self?.server.send(msg, to: conn) }
        do { try server.start() } catch { NSLog("NowPlaying: socket failed: %@", "\(error)") }

        panel = PanelController(model: model)
        menu = StatusMenuController(model: model, panel: panel)
        appearance = AppearanceWindowController(model: model, panel: panel)
        model.openAppearance = { [weak self] in self?.appearance.show() }
        model.onPresence = { [weak self] hasTrack, playing, videoId in
            self?.panel.presence(hasTrack: hasTrack, playing: playing, videoId: videoId)
        }
        panel.start()
        if CommandLine.arguments.contains("--appearance") { appearance.show() }
        // First run (no extension has ever connected): show the setup checklist instead of an empty overlay.
        if !UserDefaults.standard.bool(forKey: "everConnected") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.model.connectionCount == 0 else { return }
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
        // np-host launches us with `open -g`; when several browsers race, the later ones arrive as a
        // reopen right after launch. Only treat it as the user opening the app after that window.
        guard ProcessInfo.processInfo.systemUptime - launchedAt > 5 else { return false }
        setup.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
