import AppKit
import SublineCore

/// Spotify and Apple Music as extra "tabs": their playback notifications drive the same session
/// store as the browser extension, AppleScript supplies the position and artwork and carries the
/// controls. Nothing runs unless one of the apps is open; the apps are never launched by us.
@MainActor
final class NativePlayers {
    /// Pseudo connection id for these sources in `SessionStore` (real host connections are ≥ 1).
    static let conn = -100
    nonisolated static var artworkDir: URL { SublinePaths.supportDir.appendingPathComponent("native-art", isDirectory: true) }

    enum App: Int, CaseIterable {
        case spotify = 1, music = 2
        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var site: String { self == .spotify ? "spotify" : "music" }
        var notification: String { self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    var onMessage: ((Incoming) -> Void)?
    var enabled: Bool = UserDefaults.standard.object(forKey: "nativePlayers") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "nativePlayers")
            if enabled { App.allCases.forEach(query) } else { App.allCases.forEach(clear) }
        }
    }
    /// The user declined Automation access for an app: we still follow its notifications.
    private(set) var denied: Set<App> = []

    private struct Snapshot: Equatable {
        var id: String, title: String, artist: String, album: String?, duration: Double?, artwork: String?
        var position: Double, playing: Bool
    }
    private var shown: [App: Snapshot] = [:]
    private var seq = 0
    private var poll: Timer?
    private let scripts = ScriptRunner()

    func start() {
        let dnc = DistributedNotificationCenter.default()
        for app in App.allCases {
            dnc.addObserver(forName: .init(app.notification), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.notified(app, info) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let app = App.allCases.first(where: { $0.bundleID == bid }) else { return }
                self.clear(app)
            }
        }
        // Already playing when we launched.
        if enabled { App.allCases.filter(\.isRunning).forEach(query) }
    }

    // MARK: Commands (from the overlay, menus and shortcuts)

    func handle(_ msg: Outgoing) {
        guard case let .cmd(tab, action, t) = msg, let app = App(rawValue: tab), app.isRunning else { return }
        let verb: String
        switch action {
        case "toggle": verb = "playpause"
        case "play": verb = "play"
        case "pause": verb = "pause"
        case "next": verb = "next track"
        case "prev": verb = "previous track"
        case "seek": guard let t else { return }; verb = "set player position to \(String(format: "%.2f", t))"
        default: return
        }
        scripts.run("tell application id \"\(app.bundleID)\" to \(verb)") { [weak self] _, err in
            if let err { NSLog("Subline: %@ command failed (%d)", app.site, err) }
            // Position changes don't always post a notification: read the state back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.query(app) }
        }
    }

    // MARK: State

    private func notified(_ app: App, _ info: [AnyHashable: Any]) {
        guard enabled else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        if state == "stopped" { clear(app); return }
        // The notification carries most fields; AppleScript adds position (Music) and artwork.
        if denied.contains(app) {
            let ms = (info["Duration"] as? Double) ?? (info["Total Time"] as? Double)
            let id = (info["Track ID"] as? String) ?? (info["PersistentID"].map { "\($0)" }) ?? (info["Name"] as? String ?? "")
            let snap = Snapshot(id: id, title: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
                                album: info["Album"] as? String, duration: ms.map { $0 / 1000 }, artwork: shown[app]?.id == id ? shown[app]?.artwork : nil,
                                position: (info["Playback Position"] as? Double) ?? 0, playing: state == "playing")
            publish(app, snap)
        } else {
            query(app)
        }
    }

    private func query(_ app: App) {
        guard enabled, app.isRunning else { return }
        let src: String
        switch app {
        case .spotify:
            src = """
            tell application id "com.spotify.client"
              set s to player state as string
              if s is "stopped" then return {s}
              set t to current track
              return {s, player position, id of t, name of t, artist of t, album of t, (duration of t) / 1000, artwork url of t}
            end tell
            """
        case .music:
            src = """
            tell application id "com.apple.Music"
              set s to player state as string
              if s is "stopped" then return {s}
              set t to current track
              return {s, player position, persistent ID of t, name of t, artist of t, album of t, duration of t, ""}
            end tell
            """
        }
        scripts.run(src) { [weak self] d, err in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let err {
                    if err == -1743 { self.denied.insert(app) } // Automation access declined
                    return
                }
                guard let d else { return }
                let s = (d.atIndex(1)?.stringValue ?? "").lowercased()
                guard s != "stopped", d.numberOfItems >= 8 else { self.clear(app); return }
                let id = d.atIndex(3)?.stringValue ?? ""
                let prev = self.shown[app]
                let art = d.atIndex(8)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let snap = Snapshot(id: id, title: d.atIndex(4)?.stringValue ?? "", artist: d.atIndex(5)?.stringValue ?? "",
                                    album: d.atIndex(6)?.stringValue, duration: d.atIndex(7)?.doubleValue,
                                    artwork: art ?? (prev?.id == id ? prev?.artwork : nil),
                                    position: d.atIndex(2)?.doubleValue ?? 0, playing: s == "playing")
                self.publish(app, snap)
                if app == .music, prev?.id != id { self.loadMusicArtwork(id) }
            }
        }
    }

    /// Apple Music has no artwork URL: the image data is saved once per track and loaded from disk.
    private func loadMusicArtwork(_ id: String) {
        let safe = id.filter { $0.isLetter || $0.isNumber }
        guard !safe.isEmpty else { return }
        let file = Self.artworkDir.appendingPathComponent(safe + ".img")
        if FileManager.default.fileExists(atPath: file.path) { setArtwork(.music, id: id, url: file.absoluteString); return }
        scripts.run("tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track") { [weak self] d, _ in
            guard let data = d?.data, data.count > 64, data.count < 8_000_000 else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: Self.artworkDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Keep the folder small: the last 20 covers.
            if let files = try? fm.contentsOfDirectory(at: Self.artworkDir, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 20 {
                let old = files.sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                    < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
                old.prefix(files.count - 20).forEach { try? fm.removeItem(at: $0) }
            }
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
            MainActor.assumeIsolated { self?.setArtwork(.music, id: id, url: file.absoluteString) }
        }
    }

    private func setArtwork(_ app: App, id: String, url: String) {
        guard var snap = shown[app], snap.id == id, snap.artwork != url else { return }
        snap.artwork = url
        publish(app, snap, force: true)
    }

    private func publish(_ app: App, _ snap: Snapshot, force: Bool = false) {
        let prev = shown[app]
        shown[app] = snap
        let trackChanged = force || prev?.id != snap.id || prev?.title != snap.title || prev?.artwork != snap.artwork || prev?.duration != snap.duration
        if trackChanged {
            let info = TrackInfo(site: app.site, videoId: snap.id, title: snap.title, artist: snap.artist, album: snap.album,
                                 duration: snap.duration, artwork: snap.artwork.map { [Artwork(url: $0)] } ?? [],
                                 isAd: snap.id.hasPrefix("spotify:ad:") ? true : nil)
            seq += 1
            onMessage?(.track(tab: app.rawValue, seq: seq, info))
        }
        seq += 1
        onMessage?(.clock(tab: app.rawValue, seq: seq, ClockInfo(videoId: snap.id, t: snap.position, rate: 1, paused: !snap.playing, buffering: nil)))
        updatePolling()
    }

    private func clear(_ app: App) {
        guard shown.removeValue(forKey: app) != nil else { return }
        onMessage?(.gone(tab: app.rawValue))
        updatePolling()
    }

    /// Drift correction while something plays (the overlay interpolates in between).
    private func updatePolling() {
        let playing = shown.values.contains(where: \.playing)
        if playing, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (app, s) in self.shown where s.playing && !self.denied.contains(app) { self.query(app) }
                }
            }
            poll?.tolerance = 1
        } else if !playing {
            poll?.invalidate(); poll = nil
        }
    }
}

/// Runs AppleScript off the main thread (a first-use Automation prompt would otherwise block the UI).
final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "subline.applescript", qos: .utility)
    private var compiled: [String: NSAppleScript] = [:]

    func run(_ source: String, completion: @escaping @Sendable (NSAppleEventDescriptor?, Int?) -> Void) {
        queue.async { [self] in
            let script = compiled[source] ?? {
                let s = NSAppleScript(source: source)!
                if compiled.count > 32 { compiled.removeAll() }
                compiled[source] = s
                return s
            }()
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            let code = (error?[NSAppleScript.errorNumber] as? Int)
            DispatchQueue.main.async { completion(error == nil ? result : nil, code) }
        }
    }
}
