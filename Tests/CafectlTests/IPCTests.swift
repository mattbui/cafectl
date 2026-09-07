import Foundation
import Darwin
import Testing
@testable import cafectl

private actor FakeService {
    var toggles = 0
    func handle(_ command: ControlCommand) -> ControlResponse {
        if case .toggle = command { toggles += 1 }
        return ControlResponse(snapshot: ServiceSnapshot(serviceRunning: true, power: .init(source: .ac, batteryPercent: nil), modes: [:]), exitCode: 0, message: String(toggles))
    }
}

struct IPCTests {
    private func directory() -> URL { URL(fileURLWithPath: "/tmp/cafectl-test-\(UUID().uuidString)") }

    @Test func roundTripConcurrentMutationsAndLifetimeLock() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService()
        let server = try IPCServer(directory: directory, handler: { await service.handle($0) })
        try server.prepare()
        try server.start()
        let second = try IPCServer(directory: directory, handler: { await service.handle($0) })
        #expect(throws: IPCError.self) { try second.prepare() }
        let results = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? Int(IPCClient(directory: directory).send(.toggle(.display)).message ?? "") }
            }
            var results: [Int] = []
            for await value in group { if let value { results.append(value) } }
            return results
        }
        #expect(results.sorted() == Array(1...8))
        await server.stopAndWait()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
        let replacement = try IPCServer(directory: directory, handler: { await service.handle($0) })
        try replacement.prepare()
        replacement.stop()
    }

    @Test func missingServiceAndUnsafeDirectory() throws {
        let directory = directory()
        #expect(throws: IPCError.self) { try IPCClient(directory: directory).send(.status) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        chmod(directory.path, 0o755)
        let server = try IPCServer(directory: directory, handler: { _ in fatalError("Must not execute") })
        #expect(throws: IPCError.self) { try server.prepare() }
    }

    @Test func incompatibleHandshakeCannotMutate() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService()
        let server = try IPCServer(directory: directory, handler: { await service.handle($0) })
        try server.prepare()
        try server.start()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(directory.appendingPathComponent("control.sock").path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)
        var body = Data("{\"version\":999}".utf8)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
        body.withUnsafeMutableBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
        // A valid subsequent connection proves the previous client was handled.
        let result = try IPCClient(directory: directory).send(.status)
        #expect(result.message == "0")
        await server.stopAndWait()
    }

    @Test func nonSocketStalePathIsPreserved() throws {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock")
        try Data("preserve".utf8).write(to: path)
        let server = try IPCServer(directory: directory, handler: { _ in fatalError("Must not execute") })
        #expect(throws: IPCError.self) { try server.prepare() }
        #expect(try String(contentsOf: path, encoding: .utf8) == "preserve")
    }
    @Test func lostReplyDoesNotRetryMutation() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService()
        let server = try IPCServer(directory: directory, handler: { command in
            let result = await service.handle(command)
            try? await Task.sleep(for: .milliseconds(400))
            return result
        })
        try server.prepare()
        try server.start()
        #expect(throws: IPCError.self) { try IPCClient(directory: directory, timeout: 0.2).send(.toggle(.display)) }
        await server.stopAndWait()
        #expect(await service.toggles == 1)
    }

    @Test func fragmentedHandshakeAndOversizedFrameDoNotMutate() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService()
        let server = try IPCServer(directory: directory, handler: { await service.handle($0) })
        try server.prepare()
        try server.start()
        let fd = try rawConnect(directory)
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let body = Data("{\"version\":1}".utf8)
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        for var byte in frame { #expect(Darwin.write(fd, &byte, 1) == 1) }
        var helloLength: UInt32 = 0
        #expect(Darwin.recv(fd, &helloLength, 4, MSG_WAITALL) == 4)
        var response = [UInt8](repeating: 0, count: Int(UInt32(bigEndian: helloLength)))
        let responseCount = response.count
        #expect(Darwin.recv(fd, &response, responseCount, MSG_WAITALL) == responseCount)
        #expect(String(decoding: response, as: UTF8.self).contains("1"))
        var oversized = UInt32(65_537).bigEndian
        #expect(Darwin.write(fd, &oversized, 4) == 4)
        let result = try IPCClient(directory: directory).send(.status)
        #expect(result.message == "0")
        await server.stopAndWait()
    }

    private func rawConnect(_ directory: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(directory.appendingPathComponent("control.sock").path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw IPCError.transport("test connect") }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    @Test func quitRepliesBeforeCleanup() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService()
        let callback = QuitResult()
        let server = try IPCServer(directory: directory, handler: { await service.handle($0) }, onQuit: { response in
            callback.store(response.exitCode)
        })
        try server.prepare()
        try server.start()
        let response = try IPCClient(directory: directory).send(.quit)
        #expect(response.exitCode == 0)
        await server.stopAndWait()
        #expect(callback.value == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
    }

    @Test func staleSocketRecoveredByLockOwner() async throws {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(directory.appendingPathComponent("control.sock").path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(result == 0)
        let service = FakeService()
        let server = try IPCServer(directory: directory, handler: { await service.handle($0) })
        try server.prepare()
        try server.start()
        #expect(try IPCClient(directory: directory).send(.status).exitCode == 0)
        await server.stopAndWait()
    }

}

private final class QuitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int?
    var value: Int? { lock.lock(); defer { lock.unlock() }; return code }
    func store(_ value: Int) { lock.lock(); code = value; lock.unlock() }
}
