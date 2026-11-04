import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum UnixSocket {
    public enum SocketError: Error { case pathTooLong, sys(String, Int32) }

    static func makeAddr(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Connects to a listening socket; returns fd.
    public static func connect(path: String) throws -> Int32 {
        var addr = try makeAddr(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.sys("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if r != 0 { let e = errno; close(fd); throw SocketError.sys("connect", e) }
        return fd
    }

    /// True when some process is accepting connections at `path`.
    public static func isLive(path: String) -> Bool {
        guard let fd = try? connect(path: path) else { return false }
        close(fd)
        return true
    }

    /// Binds and listens, removing a stale socket file only when no listener answers.
    public static func listen(path: String) throws -> Int32 {
        var addr = try makeAddr(path)
        if FileManager.default.fileExists(atPath: path) {
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() {
                // Remove only a socket nobody is listening on (ECONNREFUSED). Callers must hold the
                // instance lock so two launches cannot race here.
                do { let fd = try connect(path: path); close(fd) }
                catch SocketError.sys(_, let e) where e == ECONNREFUSED { unlink(path) }
                catch {}
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.sys("socket", errno) }
        let old = umask(0o177)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(old)
        if r != 0 { let e = errno; close(fd); throw SocketError.sys("bind", e) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else { let e = errno; close(fd); throw SocketError.sys("listen", e) }
        return fd
    }

    /// Writes all bytes, retrying on partial writes / EINTR.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n; p += n
            }
            return true
        }
    }
}
