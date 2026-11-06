import Foundation
import SublineCore

/// One-time move from the app's previous name ("Now Playing", com.nowplaying.*): preferences
/// and the data folder (recently played, thumbnails, unpacked extension copy). Runs before the instance lock, so it only ever sees a stopped old app.
/// The old Native Messaging host name stays registered (pointing at this app's helper) for
/// extensions that haven't reloaded yet; see `NMRegistrar.registerHost()`.
enum LegacyMigration {
    static let oldBundleID = "com.nowplaying.app"
    static let oldHostName = "com.nowplaying.host"
    static var oldSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NowPlaying", isDirectory: true)
    }

    static func run() {
        migrateDefaults()
        migrateSupportDir()
    }

    /// Copies keys the new domain doesn't have yet, then drops the old domain.
    static func migrateDefaults() {
        let d = UserDefaults.standard
        guard let old = d.persistentDomain(forName: oldBundleID), !old.isEmpty else { return }
        var merged = d.persistentDomain(forName: SublinePaths.bundleID) ?? [:]
        for (k, v) in old where merged[k] == nil { merged[k] = v }
        d.setPersistentDomain(merged, forName: SublinePaths.bundleID)
        d.removePersistentDomain(forName: oldBundleID)
        NSLog("Subline: migrated %d preferences from %@", old.count, oldBundleID)
    }

    /// Moves the old folder when the new one doesn't exist yet; runtime files are dropped.
    static func migrateSupportDir() {
        let fm = FileManager.default
        let old = oldSupportDir, new = SublinePaths.supportDir
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
            for name in try fm.contentsOfDirectory(atPath: new.path)
            where name == "np.sock" || name == "app.lock" || name == "user-quit" || name.hasPrefix("debug-state.json") {
                try? fm.removeItem(at: new.appendingPathComponent(name))
            }
            NSLog("Subline: moved data folder from %@", old.path)
        } catch {
            NSLog("Subline: could not move %@: %@", old.path, error.localizedDescription)
        }
    }
}
