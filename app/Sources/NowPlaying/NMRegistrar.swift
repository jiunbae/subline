import Foundation
import NowPlayingCore

/// Registers the app with Chromium-family browsers:
/// - the Native Messaging host manifest (so the extension can reach np-host), and
/// - once a Chrome Web Store ID is configured, an "external extension" preference file so Chrome
///   offers to enable the extension on its next launch (Chrome only honors Web Store IDs here).
enum NMRegistrar {
    static let browserDirs = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary",
        "Chromium", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data",
    ]
    /// Browsers that read `External Extensions/<id>.json` and install from the Chrome Web Store.
    static let externalExtensionDirs = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary", "Chromium"]

    static var hostExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/np-host")
    }
    private static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    static func registerAll() {
        registerHost()
        if let id = NPPaths.storeExtensionID { requestExternalInstall(id) }
    }

    static func registerHost() {
        let exe = hostExecutable
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            NSLog("NowPlaying: np-host missing at %@ (running outside the .app bundle?)", exe.path)
            return
        }
        let manifest: [String: Any] = [
            "name": NPPaths.hostName,
            "description": "Now Playing overlay bridge",
            "path": exe.path,
            "type": "stdio",
            "allowed_origins": NPPaths.allowedExtensionIDs.map { "chrome-extension://\($0)/" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        for dir in browserDirs {
            let browser = appSupport.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: browser.path) else { continue }
            let hosts = browser.appendingPathComponent("NativeMessagingHosts")
            try? FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            let file = hosts.appendingPathComponent("\(NPPaths.hostName).json")
            if (try? Data(contentsOf: file)) != data { try? data.write(to: file, options: .atomic) }
        }
    }

    /// Written once per browser. If the user later removes the extension, Chrome remembers that and
    /// does not reinstall it, so this never fights the user.
    static func requestExternalInstall(_ id: String) {
        let body = Data(#"{"external_update_url": "https://clients2.google.com/service/update2/crx"}"#.utf8)
        for dir in externalExtensionDirs {
            let browser = appSupport.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: browser.path) else { continue }
            let ext = browser.appendingPathComponent("External Extensions")
            let file = ext.appendingPathComponent("\(id).json")
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            try? FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
            try? body.write(to: file, options: .atomic)
        }
    }

    /// Copies the extension bundled in the app to a stable folder for "Load unpacked".
    @discardableResult
    static func installUnpackedCopy() -> URL? {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("extension", isDirectory: true),
              FileManager.default.fileExists(atPath: src.appendingPathComponent("manifest.json").path) else { return nil }
        let dst = NPPaths.unpackedExtensionDir
        let fm = FileManager.default
        let srcManifest = try? Data(contentsOf: src.appendingPathComponent("manifest.json"))
        let dstManifest = try? Data(contentsOf: dst.appendingPathComponent("manifest.json"))
        if srcManifest == dstManifest, !changed(src, dst) { return dst }
        try? fm.removeItem(at: dst)
        do { try fm.copyItem(at: src, to: dst) } catch { return nil }
        return dst
    }

    private static func changed(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        let names = (fm.enumerator(atPath: a.path)?.allObjects as? [String]) ?? []
        if names.count != ((fm.enumerator(atPath: b.path)?.allObjects as? [String]) ?? []).count { return true }
        return names.contains { (try? Data(contentsOf: a.appendingPathComponent($0))) != (try? Data(contentsOf: b.appendingPathComponent($0))) }
    }
}
