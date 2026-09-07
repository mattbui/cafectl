import Foundation
import Darwin

// Handshake is separate from the command so an incompatible server cannot execute it.
private struct Hello: Codable { var version: Int }
private let protocolVersion = 1
private let maximumFrameSize = 65_536

enum IPCError: Error, LocalizedError {
    case unavailable, alreadyRunning, unsafePath(String), transport(String), incompatible
    var exitCode: Int { if case .unavailable = self { return 4 }; return 5 }
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Service not running"
        case .alreadyRunning: return "cafectl start is already running"
        case .unsafePath(let reason): return "Unsafe socket path: \(reason)"
        case .transport(let reason): return "Transport failure: \(reason). The result may be uncertain; check cafectl status before retrying."
        case .incompatible: return "Incompatible service protocol. Explicitly restart the cafectl service."
        }
    }
}

enum IPCPaths {
    // /tmp is short enough for sockaddr_un. Ownership and mode are checked before use.
    static var defaultDirectory: URL { URL(fileURLWithPath: "/tmp/cafectl-\(getuid())", isDirectory: true) }
}

private func validateDirectory(_ directory: URL, create: Bool) throws {
    if create, mkdir(directory.path, 0o700) != 0, errno != EEXIST {
        throw IPCError.unsafePath("cannot create private directory")
    }
    var info = stat()
    guard lstat(directory.path, &info) == 0 else {
        if !create, errno == ENOENT { throw IPCError.unavailable }
        throw IPCError.unsafePath("cannot inspect directory")
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
        throw IPCError.unsafePath("directory must be owned by this user with mode 0700")
    }
}

private func address(_ directory: URL) throws -> sockaddr_un {
    let bytes = Array(directory.appendingPathComponent("control.sock").path.utf8) + [0]
    var value = sockaddr_un()
    guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw IPCError.unsafePath("socket name too long") }
    value.sun_family = sa_family_t(AF_UNIX)
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
    return value
}

private func socketCall(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func configure(_ fd: Int32) throws {
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw IPCError.transport("socket configuration") }
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw IPCError.transport("socket configuration") }
}

private func verifyPeer(_ fd: Int32) throws {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw IPCError.transport("peer user mismatch") }
}

private func ready(_ fd: Int32, _ events: Int16, until deadline: TimeInterval) throws {
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw IPCError.transport("deadline exceeded") }
        var item = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&item, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
        if result < 0, errno == EINTR { continue }
        guard result > 0, item.revents & events != 0 else { throw IPCError.transport(result == 0 ? "deadline exceeded" : "connection closed") }
        return
    }
}

private func transfer(_ fd: Int32, bytes: UnsafeMutableRawBufferPointer, writing: Bool, deadline: TimeInterval) throws {
    var offset = 0
    while offset < bytes.count {
        try ready(fd, writing ? Int16(POLLOUT) : Int16(POLLIN), until: deadline)
        let pointer = bytes.baseAddress!.advanced(by: offset)
        let count = writing ? Darwin.write(fd, pointer, bytes.count - offset) : Darwin.read(fd, pointer, bytes.count - offset)
        if count < 0, errno == EAGAIN || errno == EINTR { continue }
        guard count > 0 else { throw IPCError.transport("connection closed") }
        offset += count
    }
}

private func sendFrame<T: Encodable>(_ value: T, fd: Int32, deadline: TimeInterval) throws {
    var body = try JSONEncoder().encode(value)
    guard body.count <= maximumFrameSize else { throw IPCError.transport("frame too large") }
    var size = UInt32(body.count).bigEndian
    try withUnsafeMutableBytes(of: &size) { try transfer(fd, bytes: $0, writing: true, deadline: deadline) }
    try body.withUnsafeMutableBytes { try transfer(fd, bytes: $0, writing: true, deadline: deadline) }
}

private func receiveFrame<T: Decodable>(_ type: T.Type, fd: Int32, deadline: TimeInterval) throws -> T {
    var size: UInt32 = 0
    try withUnsafeMutableBytes(of: &size) { try transfer(fd, bytes: $0, writing: false, deadline: deadline) }
    let count = Int(UInt32(bigEndian: size))
    guard count > 0, count <= maximumFrameSize else { throw IPCError.transport("invalid frame size") }
    var bytes = Data(count: count)
    try bytes.withUnsafeMutableBytes { try transfer(fd, bytes: $0, writing: false, deadline: deadline) }
    do { return try JSONDecoder().decode(type, from: bytes) }
    catch { throw IPCError.transport("malformed message") }
}

struct IPCClient {
    var directory: URL = IPCPaths.defaultDirectory
    var timeout: TimeInterval = 3
    func send(_ command: ControlCommand) throws -> ControlResponse {
        try validateDirectory(directory, create: false)
        var addr = try address(directory)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.transport("cannot create socket") }
        defer { close(fd) }
        try configure(fd)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let result = socketCall(&addr) { Darwin.connect(fd, $0, $1) }
        if result != 0 {
            if errno == ENOENT || errno == ECONNREFUSED { throw IPCError.unavailable }
            guard errno == EINPROGRESS else { throw IPCError.transport("cannot connect") }
            try ready(fd, Int16(POLLOUT), until: deadline)
            var status: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &length) == 0, status == 0 else { throw IPCError.unavailable }
        }
        try verifyPeer(fd)
        try sendFrame(Hello(version: protocolVersion), fd: fd, deadline: deadline)
        guard try receiveFrame(Hello.self, fd: fd, deadline: deadline).version == protocolVersion else { throw IPCError.incompatible }
        try sendFrame(command, fd: fd, deadline: deadline)
        return try receiveFrame(ControlResponse.self, fd: fd, deadline: deadline)
    }
}

private final class ResponseBox: @unchecked Sendable {
    let lock = NSLock()
    var value: ControlResponse?
    func set(_ response: ControlResponse) { lock.lock(); value = response; lock.unlock() }
    func get() -> ControlResponse? { lock.lock(); defer { lock.unlock() }; return value }
}

final class IPCServer: @unchecked Sendable {
    private let directory: URL
    private let handler: @Sendable (ControlCommand) async -> ControlResponse
    private let onQuit: @Sendable (ControlResponse) -> Void
    private let stateLock = NSLock()
    private var stopping = false
    private var started = false
    private var listener: Int32 = -1
    private var lockFD: Int32 = -1
    private var ownsSocket = false
    var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return listener == -1 }

    init(directory: URL = IPCPaths.defaultDirectory, handler: @escaping @Sendable (ControlCommand) async -> ControlResponse, onQuit: @escaping @Sendable (ControlResponse) -> Void = { _ in }) throws {
        self.directory = directory
        self.handler = handler
        self.onQuit = onQuit
        _ = try address(directory)
    }

    func prepare() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lockFD == -1 else { throw IPCError.alreadyRunning }
        try validateDirectory(directory, create: true)
        let path = directory.appendingPathComponent("instance.lock").path
        lockFD = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw IPCError.unsafePath("cannot open instance lock") }
        do {
            var info = stat()
            guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw IPCError.unsafePath("invalid instance lock") }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw IPCError.alreadyRunning }
            let socketPath = directory.appendingPathComponent("control.sock").path
            if lstat(socketPath, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw IPCError.unsafePath("existing path is not a user socket") }
                guard unlink(socketPath) == 0 else { throw IPCError.unsafePath("cannot remove stale socket") }
            } else if errno != ENOENT { throw IPCError.unsafePath("cannot inspect socket") }
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw IPCError.transport("cannot create socket") }
            try configure(listener)
            var addr = try address(directory)
            guard socketCall(&addr, { Darwin.bind(listener, $0, $1) }) == 0 else { throw IPCError.transport("cannot bind socket: \(String(cString: strerror(errno)))") }
            ownsSocket = true
            guard chmod(socketPath, 0o600) == 0, listen(listener, 16) == 0 else { throw IPCError.transport("cannot listen") }

        } catch {
            cleanup()
            throw error
        }
    }

    func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listener >= 0, !started, !stopping else { throw IPCError.transport("server is not prepared") }
        started = true
        DispatchQueue.global(qos: .userInitiated).async { self.run() }
    }

    func stop() {
        stateLock.lock()
        stopping = true
        if !started { cleanup() }
        stateLock.unlock()
    }
    func stopAndWait() async {
        stop()
        while !isStopped { try? await Task.sleep(for: .milliseconds(10)) }
    }
    deinit { cleanup() }
    private var shouldStop: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopping }

    private func run() {
        defer { stateLock.lock(); cleanup(); stateLock.unlock() }
        while !shouldStop {
            var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&item, 1, 100) > 0 else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            process(fd)
            close(fd)
        }
    }

    private func process(_ fd: Int32) {
        var quitResponse: ControlResponse?
        defer { if let result = quitResponse { stop(); onQuit(result) } }
        do {
            try configure(fd)
            try verifyPeer(fd)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            let hello = try receiveFrame(Hello.self, fd: fd, deadline: deadline)
            try sendFrame(Hello(version: protocolVersion), fd: fd, deadline: deadline)
            guard hello.version == protocolVersion else { return }
            let command = try receiveFrame(ControlCommand.self, fd: fd, deadline: deadline)
            guard !shouldStop else { return }
            let box = ResponseBox()
            let completed = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task { box.set(await handler(command)); completed.signal() }
            // Wait for the one accepted operation to finish. Never accept another mutation
            // while this one is still running, even if its client's deadline expires.
            completed.wait()
            guard let result = box.get() else { return }
            if case .quit = command { quitResponse = result }
            try sendFrame(result, fd: fd, deadline: deadline)
        } catch { /* Invalid/disconnected clients do not terminate the service. */ }
    }

    private func cleanup() {
        if listener >= 0 { close(listener); listener = -1 }
        if ownsSocket { unlink(directory.appendingPathComponent("control.sock").path); ownsSocket = false }
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
        // Keep the lock file itself: unlinking it would let another process lock a different inode.
    }
}
