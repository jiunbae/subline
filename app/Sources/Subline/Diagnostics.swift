import AppKit
import SublineCore

/// What the setup window shows when the extension can't reach the app: whether the helper exists,
/// which browsers got the Native Messaging registration (and why not), and socket problems.
@MainActor @Observable
final class Diagnostics {
    static let shared = Diagnostics()

    struct Registration: Identifiable, Equatable {
        let browser: String
        let path: String
        let error: String?
        var id: String { browser }
    }

    private(set) var helperPath = ""
    private(set) var helperOK = false
    private(set) var registrations: [Registration] = []
    var socketError: String?
    private(set) var checkedAt = Date.distantPast

    var hasProblem: Bool {
        !helperOK || socketError != nil || registrations.isEmpty || registrations.contains { $0.error != nil }
    }

    func update(helperPath: String, helperOK: Bool, registrations: [Registration]) {
        self.helperPath = helperPath
        self.helperOK = helperOK
        self.registrations = registrations
        checkedAt = Date()
    }

    /// Plain-text report for support (no browsing data).
    var report: String {
        var lines = ["Subline \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "App: \(Bundle.main.bundlePath)",
                     "Helper: \(helperOK ? "ok" : "MISSING") \(helperPath)",
                     "Socket: \(socketError ?? "listening at \(SublinePaths.socketPath)")",
                     "Background cursor: \(BackgroundCursor.enabled ? "on" : "off (public API only)")"]
        if registrations.isEmpty { lines.append("Browsers: none found (Chrome, Chromium, Brave, Edge, Vivaldi, Arc)") }
        for r in registrations { lines.append("Browser \(r.browser): \(r.error.map { "FAILED — \($0)" } ?? "registered") \(r.path)") }
        return lines.joined(separator: "\n")
    }
}
