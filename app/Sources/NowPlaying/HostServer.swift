import Foundation
import NowPlayingCore
import Darwin

/// Accepts np-host connections on the Unix socket. All socket I/O happens on a private
/// serial queue; parsed messages are delivered on the main queue.
final class HostServer: @unchecked Sendable {
    var onConnect: (@MainActor (Int) -> Void)?
    var onDisconnect: (@MainActor (Int) -> Void)?
    var onMessage: (@MainActor (Int, Incoming) -> Void)?

    private let queue = DispatchQueue(label: "nowplaying.server", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var conns: [Int: Conn] = [:]
    private var nextID = 1
    private static let maxOutgoing = 64 * 1024

    private final class Conn {
        let id: Int
        let fd: Int32
        var source: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var writerActive = false
        var pending = Data()           // bytes not yet accepted by the kernel
        var decoder = Framing.Decoder()
        init(id: Int, fd: Int32) { self.id = id; self.fd = fd }
    }
    private static let maxPending = 256 * 1024

    func start() throws {
        try NPPaths.ensureSupportDir()
        listenFD = try UnixSocket.listen(path: NPPaths.socketPath)
        _ = fcntl(listenFD, F_SETFL, fcntl(listenFD, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        acceptSource = src
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            for c in Array(conns.values) { drop(c) }
            if listenFD >= 0 { close(listenFD); unlink(NPPaths.socketPath) } // safe: we hold the instance lock
            listenFD = -1
        }
    }

    /// Sends to one connection, or broadcasts when `conn` is nil.
    func send(_ msg: Outgoing, to conn: Int?) {
        let payload = msg.json()
        guard payload.count <= Self.maxOutgoing else { return }
        let frame = Framing.encode(payload)
        queue.async { [weak self] in
            guard let self else { return }
            let targets = conn.map { id in self.conns[id].map { [$0] } ?? [] } ?? Array(self.conns.values)
            for c in targets { self.enqueue(frame, on: c) }
        }
    }

    /// Queues a whole frame; flushes as far as the socket allows and resumes on writability.
    private func enqueue(_ frame: Data, on c: Conn) {
        guard c.pending.count + frame.count <= Self.maxPending else { drop(c); return } // peer is stuck
        c.pending.append(frame)
        flush(c)
    }

    private func flush(_ c: Conn) {
        while !c.pending.isEmpty {
            let n = c.pending.withUnsafeBytes { write(c.fd, $0.baseAddress, $0.count) }
            if n > 0 { c.pending.removeFirst(n); continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN {
                if !c.writerActive { c.writerActive = true; c.writer?.resume() }
                return
            }
            drop(c); return
        }
        if c.writerActive { c.writerActive = false; c.writer?.suspend() }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            // Only accept peers running as the same user.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let c = Conn(id: nextID, fd: fd)
            nextID += 1
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self, weak c] in
                guard let self, let c else { return }
                self.readAvailable(c)
            }
            let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            w.setEventHandler { [weak self, weak c] in
                guard let self, let c else { return }
                self.flush(c)
            }
            c.writer = w // created suspended; resumed only while bytes are pending
            // Close the fd only once the read source is gone (write source is cancelled first in drop).
            src.setCancelHandler { close(fd) }
            c.source = src
            conns[c.id] = c
            src.resume()
            let id = c.id
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onConnect?(id) }
            }
        }
    }

    private func readAvailable(_ c: Conn) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(c.fd, &buf, buf.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else { drop(c); return }
        c.decoder.append(Data(buf[0..<n]))
        var parsed: [Incoming] = []
        do {
            while let frame = try c.decoder.next() {
                if let msg = try? Incoming.parse(frame) { parsed.append(msg) }
            }
        } catch {
            NSLog("NowPlaying: dropping connection %d: %@", c.id, "\(error)")
            drop(c)
            return
        }
        guard !parsed.isEmpty else { return }
        let id = c.id
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                for m in parsed { self?.onMessage?(id, m) }
            }
        }
    }

    private func drop(_ c: Conn) {
        guard conns.removeValue(forKey: c.id) != nil else { return }
        if let w = c.writer {
            if !c.writerActive { w.resume() } // a suspended source must be resumed before cancel
            w.cancel()
        }
        c.pending.removeAll()
        c.source?.cancel()
        let id = c.id
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onDisconnect?(id) }
        }
    }
}
