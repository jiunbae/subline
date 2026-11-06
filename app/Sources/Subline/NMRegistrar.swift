import Foundation
import SublineCore

/// Registers the app with Chromium-family browsers:
/// - the Native Messaging host manifest (so the extension can reach subline-host), and
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
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/subline-host")
    }
    private static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// Registers with every installed browser and records the outcome in `Diagnostics`.
    /// Safe to call repeatedly (writes only when the manifest changed); the setup window calls it
    /// again, so a browser installed after launch is picked up.
    @MainActor
    static func registerAll() {
        let exe = hostExecutable
        let helperOK = FileManager.default.isExecutableFile(atPath: exe.path)
        let results = helperOK ? registerHost() : []
        if !helperOK { NSLog("Subline: subline-host missing at %@ (running outside the .app bundle?)", exe.path) }
        Diagnostics.shared.update(helperPath: exe.path, helperOK: helperOK, registrations: results)
        if let id = SublinePaths.storeExtensionID { requestExternalInstall(id) }
    }

    static func registerHost() -> [Diagnostics.Registration] {
        // An extension built before the rename still asks for the old host name; point it at this
        // helper too so it keeps working until the browser reloads the extension.
        _ = registerHost(named: LegacyMigration.oldHostName)
        return registerHost(named: SublinePaths.hostName)
    }

    private static func registerHost(named hostName: String) -> [Diagnostics.Registration] {
        let exe = hostExecutable
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Subline overlay bridge",
            "path": exe.path,
            "type": "stdio",
            "allowed_origins": SublinePaths.allowedExtensionIDs.map { "chrome-extension://\($0)/" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return [] }
        var results: [Diagnostics.Registration] = []
        for dir in browserDirs {
            let browser = appSupport.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: browser.path) else { continue }
            let hosts = browser.appendingPathComponent("NativeMessagingHosts")
            let file = hosts.appendingPathComponent("\(hostName).json")
            let name = (dir.replacingOccurrences(of: "/User Data", with: "").components(separatedBy: "/").last ?? dir)
                .replacingOccurrences(of: "-Browser", with: "")
            do {
                try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
                if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
                results.append(.init(browser: name, path: file.path, error: nil))
            } catch {
                NSLog("Subline: registering with %@ failed: %@", name, error.localizedDescription)
                results.append(.init(browser: name, path: file.path, error: error.localizedDescription))
            }
        }
        return results
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
        let dst = SublinePaths.unpackedExtensionDir
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
