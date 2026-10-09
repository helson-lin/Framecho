//
//  MCPSocket.swift
//  Framecho
//
//  The local transport behind agent access: a Unix-domain socket in
//  Framecho's Application Support folder, readable only by this user,
//  carrying newline-delimited JSON. MCP clients don't speak to it directly;
//  they launch `Framecho --mcp`, which relays stdio to it (MCPStdioBridge).
//

import Darwin
import Foundation

nonisolated enum MCPSocketLocation {
    /// One socket per bundle identifier, so Framecho and Framecho Dev can both
    /// run without answering for each other.
    static func url(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.jarinhe.Framecho") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Framecho", isDirectory: true)
            .appendingPathComponent("agent-\(bundleIdentifier).sock")
    }
}

nonisolated enum MCPSocketError: LocalizedError {
    case pathTooLong(String)
    case system(String, Int32)
    case alreadyServing

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            "The agent socket path is too long for macOS: \(path)"
        case .system(let call, let code):
            "\(call) failed: \(String(cString: strerror(code)))"
        case .alreadyServing:
            "Another copy of Framecho is already serving agents."
        }
    }
}

nonisolated enum MCPSocketIO {
    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw MCPSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.system("socket", errno) }
        // A peer that goes away mid-write must cost an error, not the process.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Connects to a listening socket; nil when nothing is listening there.
    static func connect(to path: String) -> Int32? {
        guard var address = try? address(for: path), let fd = try? makeSocket() else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Writes every byte, retrying short writes and interrupts.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }
}

/// One accepted client: reads lines on its own thread, writes replies under
/// a lock so concurrent tool calls never interleave their bytes.
nonisolated final class MCPSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ line: String) {
        writeLock.withLock {
            guard !isClosed else { return }
            MCPSocketIO.writeAll(fd, Data((line + "\n").utf8))
        }
    }

    /// Blocks the calling thread until the peer hangs up.
    func readLines(_ onLine: (String) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    onLine(line)
                }
            }
        }
    }

    func close() {
        writeLock.withLock {
            guard !isClosed else { return }
            isClosed = true
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// Accepts connections on the agent socket until stopped.
nonisolated final class MCPSocketListener: @unchecked Sendable {
    private let path: String
    private let onConnection: @Sendable (MCPSocketConnection) -> Void
    private let lock = NSLock()
    private var listeningFD: Int32 = -1
    private var connections: [ObjectIdentifier: MCPSocketConnection] = [:]

    init(path: String, onConnection: @escaping @Sendable (MCPSocketConnection) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    func start() throws {
        // A socket file left by a crash is removed; one with a live server
        // behind it belongs to another running copy and is left alone.
        if let existing = MCPSocketIO.connect(to: path) {
            close(existing)
            throw MCPSocketError.alreadyServing
        }
        unlink(path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var address = try MCPSocketIO.address(for: path)
        let fd = try MCPSocketIO.makeSocket()
        // Created owner-only from the start: no window in which another user
        // could connect before the chmod.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw MCPSocketError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw MCPSocketError.system("listen", code)
        }
        lock.withLock { listeningFD = fd }

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Framecho agent socket"
        thread.start()
    }

    func stop() {
        let (fd, open) = lock.withLock {
            let state = (listeningFD, Array(connections.values))
            listeningFD = -1
            connections.removeAll()
            return state
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
        open.forEach { $0.close() }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = MCPSocketConnection(fd: client)
            let isListening = lock.withLock {
                guard listeningFD == fd else { return false }
                connections[ObjectIdentifier(connection)] = connection
                return true
            }
            guard isListening else {
                connection.close()
                return
            }
            let thread = Thread { [weak self] in
                self?.onConnection(connection)
                connection.close()
                self?.forget(connection)
            }
            thread.name = "Framecho agent connection"
            thread.start()
        }
    }

    private func forget(_ connection: MCPSocketConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }
}
