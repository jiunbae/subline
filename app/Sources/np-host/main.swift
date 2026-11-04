// np-host: Chrome Native Messaging host. Relays length-prefixed frames between
// Chrome (stdin/stdout) and NowPlaying.app (Unix domain socket). Never writes
// anything but protocol frames to stdout; diagnostics go to stderr.
import Foundation
import NowPlayingCore
#if canImport(Darwin)
import Darwin
#endif

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

func log(_ s: String) { FileHandle.standardError.write(("np-host: " + s + "\n").data(using: .utf8)!) }

/// .app bundle containing this helper (…/NowPlaying.app/Contents/Helpers/np-host).
func enclosingApp() -> URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

func launchApp() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let app = enclosingApp() {
        p.arguments = ["-g", app.path]
    } else {
        p.arguments = ["-g", "-b", NPPaths.bundleID]
    }
    p.standardOutput = FileHandle.nullDevice // keep stdout clean for NM
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func connectToApp() -> Int32? {
    let path = NPPaths.socketPath
    if let fd = try? UnixSocket.connect(path: path) { return fd }
    if FileManager.default.fileExists(atPath: NPPaths.disabledMarker.path) {
        log("app was quit by user; not launching")
        return nil
    }
    launchApp()
    var delay: useconds_t = 100_000
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        usleep(delay)
        if let fd = try? UnixSocket.connect(path: path) { return fd }
        delay = min(delay * 2, 800_000)
    }
    return nil
}

guard let sock = connectToApp() else {
    log("could not reach NowPlaying.app")
    exit(1)
}

/// Copies validated frames from `src` to `dst` until EOF or error.
func pump(from src: Int32, to dst: Int32, maxFrame: Int) {
    var decoder = Framing.Decoder(maxFrame: maxFrame)
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(src, &buf, buf.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return }
        decoder.append(Data(buf[0..<n]))
        do {
            while let frame = try decoder.next() {
                guard UnixSocket.writeAll(dst, Framing.encode(frame)) else { return }
            }
        } catch {
            log("dropping connection: \(error)")
            return
        }
    }
}

// Chrome → app (Chrome allows up to 64 MiB; the app accepts 4 MiB).
let up = Thread {
    pump(from: STDIN_FILENO, to: sock, maxFrame: Framing.defaultMaxFrame)
    exit(0)
}
up.start()
// app → Chrome (Chrome's limit for host→browser frames is 1 MB).
pump(from: sock, to: STDOUT_FILENO, maxFrame: 1024 * 1024)
exit(0)
