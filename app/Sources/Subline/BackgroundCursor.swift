import Foundation

/// The overlay is a non-activating panel, so its app is almost never frontmost, and macOS ignores
/// cursor changes from background apps. The WindowServer connection property
/// "SetsCursorInBackground" lifts that (used by window managers and other floating utilities).
///
/// Private API, so it is strictly optional:
/// - resolved at runtime; if a symbol is missing nothing is called,
/// - `defaults write dev.jiun.subline disablePrivateAPIs -bool true` skips it,
/// - an App Store build (`APPSTORE=1 scripts/build-app.sh`) compiles it out.
/// Without it everything works the same; only the resize cursor shape isn't shown while
/// another app is frontmost.
enum BackgroundCursor {
    private(set) static var enabled = false

    @discardableResult
    static func enable() -> Bool {
        #if APPSTORE
        return false
        #else
        guard !UserDefaults.standard.bool(forKey: "disablePrivateAPIs") else { return false }
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY),
              let mainSym = dlsym(handle, "_CGSDefaultConnection") ?? dlsym(handle, "CGSMainConnectionID"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return false }
        let cid = unsafeBitCast(mainSym, to: MainConnection.self)()
        let status = unsafeBitCast(setSym, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        enabled = status == 0
        if !enabled { NSLog("Subline: background cursor unavailable (status %d)", status) }
        return enabled
        #endif
    }
}
