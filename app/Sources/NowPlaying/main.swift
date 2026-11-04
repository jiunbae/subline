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

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? NPPaths.ensureSupportDir()
        // Single instance: the flock is authoritative; only its holder may unlink/bind the socket.
        if !NPPaths.acquireInstanceLock() {
            NSLog("NowPlaying: another instance is running")
            exit(0)
        }
        try? FileManager.default.removeItem(at: NPPaths.disabledMarker)
        NMRegistrar.registerAll()

        server.onConnect = { [weak self] id in
            guard let self else { return }
            self.model.connected(id)
            self.server.send(.visibility(self.panel.isVisible), to: id)
            self.server.send(.requestSnapshot, to: id)
        }
        server.onDisconnect = { [weak self] id in self?.model.disconnected(id) }
        server.onMessage = { [weak self] id, msg in self?.model.handle(conn: id, msg) }
        model.send = { [weak self] msg, conn in self?.server.send(msg, to: conn) }
        do { try server.start() } catch { NSLog("NowPlaying: socket failed: %@", "\(error)") }

        panel = PanelController(model: model)
        menu = StatusMenuController(model: model, panel: panel)
        if UserDefaults.standard.object(forKey: "visible") as? Bool ?? true { panel.show() }

        hotkeys = HotKeys()
        hotkeys.register(keyCode: kVK_ANSI_O) { [weak self] in self?.panel.toggle() }
        hotkeys.register(keyCode: kVK_ANSI_L) { [weak self] in
            guard let self else { return }
            self.panel.setClickThrough(!self.model.clickThrough)
        }
        hotkeys.register(keyCode: kVK_Space) { [weak self] in self?.model.command("toggle") }
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
