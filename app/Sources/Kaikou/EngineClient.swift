import Foundation

/// Newline-delimited JSON over a Unix domain socket to the local engine.
final class EngineClient {
    let socketPath: String
    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var fd: Int32 = -1
    private let writeQueue = DispatchQueue(label: "kaikou.engine.write")
    private let lock = NSLock()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0
    }

    /// Tries to connect once; returns false if the engine is not listening yet.
    func connect() -> Bool {
        if isConnected { return true }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) }
        }
        guard ok == 0 else { close(s); return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        lock.lock(); fd = s; lock.unlock()
        let reader = Thread { [weak self] in self?.readLoop(s) }
        reader.name = "kaikou.engine.read"
        reader.start()
        return true
    }

    /// Only the reader thread closes the descriptor; everyone else shuts it down, so a
    /// reconnect can never be handed a number another thread is still reading.
    func disconnect() {
        lock.lock()
        let s = fd
        fd = -1
        lock.unlock()
        if s >= 0 { shutdown(s, SHUT_RDWR) }
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let s = self.fd; self.lock.unlock()
            guard s >= 0 else { return }
            let failed = data.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < raw.count {
                    let n = write(s, raw.baseAddress! + off, raw.count - off)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return true }
                    off += n
                }
                return false
            }
            if failed { self.handleDisconnect(s) }
        }
    }

    private func readLoop(_ s: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(s, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    DispatchQueue.main.async { self.onMessage?(obj) }
                }
            }
        }
        handleDisconnect(s)
        close(s)
    }

    private func handleDisconnect(_ s: Int32) {
        lock.lock()
        let wasCurrent = fd == s
        if wasCurrent { fd = -1 }
        lock.unlock()
        guard wasCurrent else { return }
        shutdown(s, SHUT_RDWR)
        DispatchQueue.main.async { self.onDisconnect?() }
    }
}
