import Foundation

public enum NPPaths {
    public static let bundleID = "com.nowplaying.app"
    public static let hostName = "com.nowplaying.host"
    /// Development (unpacked) extension ID, fixed by the `key` in extension/manifest.json.
    public static let extensionID = "npkfiaebcfackgbinodgjobdlmeceaij"

    /// Chrome Web Store ID, baked into Info.plist (`NPStoreExtensionID`) at build time once published.
    public static var storeExtensionID: String? {
        validExtensionID(Bundle.main.object(forInfoDictionaryKey: "NPStoreExtensionID") as? String)
    }

    /// Chrome extension IDs are 32 characters in a–p.
    public static func validExtensionID(_ id: String?) -> String? {
        guard let id, id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }) else { return nil }
        return id
    }

    /// Every extension ID allowed to talk to the native host.
    public static var allowedExtensionIDs: [String] { [extensionID] + (storeExtensionID.map { [$0] } ?? []) }

    /// Stable copy of the bundled extension for "Load unpacked" (survives app updates/moves).
    public static var unpackedExtensionDir: URL { supportDir.appendingPathComponent("extension", isDirectory: true) }

    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NowPlaying", isDirectory: true)
    }
    public static var socketPath: String { supportDir.appendingPathComponent("np.sock").path }
    /// Present while the user has explicitly quit the app; the host then won't auto-launch it.
    public static var disabledMarker: URL { supportDir.appendingPathComponent("user-quit") }

    public static var lockPath: String { supportDir.appendingPathComponent("app.lock").path }

    public enum LockResult: Equatable {
        case acquired
        case heldByAnotherInstance
        /// The lock file could not be opened/locked for another reason (permissions, read-only disk…).
        case failed(String)
    }

    /// Takes an exclusive, non-blocking lock held for the life of the process. Closes the
    /// stale-socket TOCTOU window. Distinguishes contention from a filesystem problem.
    public static func acquireInstanceLock(at path: String = lockPath) -> LockResult {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let e = errno // read before anything else can overwrite it
            return .failed("\(path): \(String(cString: strerror(e)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(fd)
            return e == EWOULDBLOCK ? .heldByAnotherInstance : .failed("\(path): \(String(cString: strerror(e)))")
        }
        return .acquired // fd intentionally leaked: the lock lives until exit
    }

    public static func ensureSupportDir() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
    }
}
