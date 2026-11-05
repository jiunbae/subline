import Foundation

/// The overlay is a non-activating panel, so its app is almost never frontmost, and macOS ignores
/// cursor changes from background apps. The WindowServer connection property
/// "SetsCursorInBackground" lifts that (used by window managers and other floating utilities).
/// Private API, resolved at runtime: if it is missing, cursors simply stay as before.
enum BackgroundCursor {
    static func enable() {
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY),
              let mainSym = dlsym(handle, "_CGSDefaultConnection") ?? dlsym(handle, "CGSMainConnectionID"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(mainSym, to: MainConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
