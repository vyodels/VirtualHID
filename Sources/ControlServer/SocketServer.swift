import Darwin
import Foundation

public final class SocketServer {
    private let socketPath: String
    private let service: ControlService
    private let queue = DispatchQueue(label: "com.vyodels.virtualhid.control.socket")
    private let clientQueue = DispatchQueue(label: "com.vyodels.virtualhid.control.socket.clients", attributes: .concurrent)
    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var running = false

    public init(socketPath: String, service: ControlService) {
        self.socketPath = socketPath
        self.service = service
    }

    public func start() throws {
        lock.withLock {
            if running {
                return
            }
        }

        signal(SIGPIPE, SIG_IGN)
        let parentDirectory = (socketPath as NSString).deletingLastPathComponent
        if !parentDirectory.isEmpty {
            try FileManager.default.createDirectory(atPath: parentDirectory, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            if socketHasLiveOwner(path: socketPath) {
                throw POSIXError(.EADDRINUSE)
            }
            unlink(socketPath)
        }
        let previousMask = umask(0o077)
        defer { umask(previousMask) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        disableSigPipe(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try copy(path: socketPath, into: &address)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        lock.withLock {
            serverFD = fd
            running = true
        }

        queue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            running = false
            let fd = serverFD
            serverFD = -1
            return fd
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
    }

    deinit {
        stop()
    }

    private func acceptLoop(fd: Int32) {
        while lock.withLock({ running }) {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            disableSigPipe(client)
            clientQueue.async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer {
            close(fd)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        while true {
            let readCount = Darwin.read(fd, &buffer, buffer.count)
            if readCount < 0, errno == EINTR {
                continue
            }
            if readCount <= 0 {
                return
            }
            pending.append(buffer, count: readCount)

            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let line = String(data: Data(lineData), encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let response = service.handleLine(line) + "\n"
                if !writeAll(Data(response.utf8), to: fd) {
                    return
                }
            }
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else {
                return true
            }
            var offset = 0
            while offset < data.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                // Client-side MCP timeouts close the socket while an action may still be
                // finishing. Treat that as a per-client disconnect, not a daemon error.
                if result < 0, errno == EPIPE || errno == ECONNRESET {
                    return false
                }
                return false
            }
            return true
        }
    }

    private func copy(path: String, into address: inout sockaddr_un) throws {
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = path.withCString { pathPointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { destination in
                    strncpy(destination, pathPointer, maxLength - 1)
                }
            }
        }
    }

    private func socketHasLiveOwner(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer {
            close(fd)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        do {
            try copy(path: path, into: &address)
        } catch {
            return false
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        return result == 0
    }
}

private func disableSigPipe(_ fd: Int32) {
    #if os(macOS)
    var value: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
