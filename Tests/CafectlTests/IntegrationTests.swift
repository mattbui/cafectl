import Foundation
import Testing
@testable import cafectl

@MainActor private final class IntegrationAssertions: AssertionManaging {
    var owned: [UInt32: Mode] = [:]
    private var nextID: UInt32 = 1
    func create(mode: Mode) throws -> UInt32 {
        let id = nextID
        nextID += 1
        owned[id] = mode
        return id
    }
    func release(id: UInt32) throws { owned.removeValue(forKey: id) }
}

@MainActor private final class IntegrationPower: PowerReading {
    var current = PowerSnapshot(source: .battery, batteryPercent: 40)
    func snapshot() -> PowerSnapshot { current }
}

@MainActor private final class IntegrationSettings: SettingsStore {
    var saved = SavedSettings()
    func load() throws -> SavedSettings { saved }
    func save(_ settings: SavedSettings) throws { saved = settings }
}

@Suite @MainActor struct IntegrationTests {
    /// Exercise the same actor crossing as start while using only fake power/assertions.
    @Test func socketCommandsDriveControllerAndQuitReleasesOwnedAssertions() async throws {
        let directory = URL(fileURLWithPath: "/tmp/cafectl-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let assertions = IntegrationAssertions()
        let power = IntegrationPower()
        let settings = IntegrationSettings()
        let controller = Controller(assertions: assertions, power: power, settings: settings)
        let quitEvents = AsyncStream<Int>.makeStream()
        let server = try IPCServer(directory: directory, handler: { command in
            await controller.handle(command)
        }, onQuit: { response in
            quitEvents.continuation.yield(response.exitCode)
            quitEvents.continuation.finish()
        })
        try server.prepare()
        try server.start()
        defer { server.stop() }

        // A synchronous client on MainActor would deadlock its own controller handler.
        func send(_ command: ControlCommand) async throws -> ControlResponse {
            try await Task.detached {
                try IPCClient(directory: directory).send(command)
            }.value
        }

        do {
            let waiting = try await send(.auto(.display, true))
            #expect(waiting.exitCode == 0)
            #expect(waiting.snapshot.modes["display"]?.automaticStart == true)
            #expect(waiting.snapshot.modes["display"]?.active == false)
            #expect(waiting.snapshot.modes["display"]?.blockedReason != nil)
            #expect(assertions.owned.isEmpty)

            let off = try await send(.off(.display))
            #expect(off.exitCode == 0)
            #expect(off.snapshot.modes["display"]?.automaticStart == false)
            #expect(settings.saved.modes["display"]?.automaticStart == false)
            power.current.source = .ac
            let afterPowerChange = try await send(.status)
            #expect(afterPowerChange.snapshot.modes["display"]?.active == false)
            #expect(assertions.owned.isEmpty)

            power.current.source = .battery
            let policy = try await send(.policy(.display, .allowBattery))
            #expect(policy.exitCode == 0)
            #expect(policy.snapshot.modes["display"]?.active == false)
            let on = try await send(.on(.display))
            #expect(on.exitCode == 0)
            #expect(on.snapshot.modes["display"]?.active == true)
            #expect(on.snapshot.modes["display"]?.automaticStart == false)
            #expect(Array(assertions.owned.values) == [.display])
            #expect(settings.saved.modes["display"]?.policy == .allowBattery)

            let quit = try await send(.quit)
            #expect(quit.exitCode == 0)
            #expect(!quit.snapshot.serviceRunning)
            #expect(quit.snapshot.modes.values.allSatisfy { !$0.active })
            #expect(assertions.owned.isEmpty)
            await server.stopAndWait()
            var events = quitEvents.stream.makeAsyncIterator()
            #expect(await events.next() == 0)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
            #expect(settings.saved.modes["display"]?.policy == .allowBattery)
            #expect(controller.handle(.on(.disk)).exitCode == 4)
        } catch {
            await server.stopAndWait()
            _ = controller.shutdown()
            throw error
        }
    }
}
