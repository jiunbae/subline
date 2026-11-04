import Foundation
import NowPlayingCore

/// Writes the Native Messaging host manifest for every installed Chromium-family browser.
enum NMRegistrar {
    static let browserDirs = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary",
        "Chromium", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data",
    ]

    static var hostExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/np-host")
    }

    static func registerAll() {
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
            "allowed_origins": ["chrome-extension://\(NPPaths.extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for dir in browserDirs {
            let browser = base.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: browser.path) else { continue }
            let hosts = browser.appendingPathComponent("NativeMessagingHosts")
            try? FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            let file = hosts.appendingPathComponent("\(NPPaths.hostName).json")
            if (try? Data(contentsOf: file)) != data { try? data.write(to: file, options: .atomic) }
        }
    }
}
