import Foundation

public enum NPPaths {
    public static let bundleID = "com.nowplaying.app"
    public static let hostName = "com.nowplaying.host"
    public static let extensionID = "npkfiaebcfackgbinodgjobdlmeceaij"

    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NowPlaying", isDirectory: true)
    }
    public static var socketPath: String { supportDir.appendingPathComponent("np.sock").path }
    /// Present while the user has explicitly quit the app; the host then won't auto-launch it.
    public static var disabledMarker: URL { supportDir.appendingPathComponent("user-quit") }

    public static var lockPath: String { supportDir.appendingPathComponent("app.lock").path }

    /// Takes an exclusive, non-blocking lock held for the life of the process.
    /// Returns false if another instance holds it. Closes the stale-socket TOCTOU window.
    public static func acquireInstanceLock() -> Bool {
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        return true // fd intentionally leaked: the lock lives until exit
    }

    public static func ensureSupportDir() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
    }
}
