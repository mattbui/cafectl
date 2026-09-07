import Foundation
import Testing
@testable import cafectl

@MainActor private final class FakeAssertions: AssertionManaging {
    var owned: [UInt32: Mode] = [:]
    var next: UInt32 = 1
    var createCalls = 0
    var failCreate = false
    var failRelease = false
    enum Failure: Error { case injected }
    func create(mode: Mode) throws -> UInt32 {
        createCalls += 1
        if failCreate { throw Failure.injected }
        let id = next; next += 1; owned[id] = mode; return id
    }
    func release(id: UInt32) throws {
        if failRelease { throw Failure.injected }
        owned.removeValue(forKey: id)
    }
}
@MainActor private final class FakePower: PowerReading {
    var value = PowerSnapshot(source: .ac, batteryPercent: nil)
    func snapshot() -> PowerSnapshot { value }
}
@MainActor private final class MemorySettings: SettingsStore {
    var value = SavedSettings()
    var failLoad = false
    var failSave = false
    var saves = 0
    func load() throws -> SavedSettings {
        if failLoad { throw FakeAssertions.Failure.injected }
        return value
    }
    func save(_ settings: SavedSettings) throws {
        saves += 1
        if failSave { throw FakeAssertions.Failure.injected }
        value = settings
    }
}
@Suite @MainActor struct ControllerTests {
    @Test func policyBoundaries() {
        for charge in [19, 20, 21] {
            let battery = PowerSnapshot(source: .battery, batteryPercent: charge)
            #expect(PowerPolicy.allowBattery.blockedReason(for: battery) == nil)
            #expect(PowerPolicy.pluggedIn.blockedReason(for: battery) != nil)
            #expect((PowerPolicy.batteryAbove20.blockedReason(for: battery) == nil) == (charge > 20))
            for policy in PowerPolicy.allCases {
                #expect(policy.blockedReason(for: PowerSnapshot(source: .ac, batteryPercent: charge)) == nil)
            }
        }
        #expect(PowerPolicy.batteryAbove20.blockedReason(for: .init(source: .battery, batteryPercent: nil)) != nil)
        #expect(PowerPolicy.pluggedIn.blockedReason(for: .init(source: .unknown, batteryPercent: nil)) != nil)
    }
    @Test func independentManualModesAndIdempotence() {
        let assertions = FakeAssertions()
        let c = Controller(assertions: assertions, power: FakePower(), settings: MemorySettings())
        #expect(c.snapshot.modes.values.allSatisfy { !$0.active && !$0.automaticStart && $0.policy == .pluggedIn })
        for mode in Mode.allCases { #expect(c.handle(.on(mode)).exitCode == 0) }
        #expect(assertions.owned.count == 3)
        _ = c.handle(.on(.display))
        #expect(assertions.owned.count == 3)
        _ = c.handle(.toggle(.system))
        #expect(c.snapshot.modes["display"]!.active)
        #expect(!c.snapshot.modes["system"]!.active)
        _ = c.handle(.offAll)
        #expect(assertions.owned.isEmpty)
    }
    @Test func automationWaitsAndManualOffCancelsWaiting() {
        let power = FakePower(); power.value = .init(source: .battery, batteryPercent: 50)
        let c = Controller(assertions: FakeAssertions(), power: power, settings: MemorySettings())
        #expect(c.handle(.auto(.display, true)).exitCode == 0)
        #expect(!c.snapshot.modes["display"]!.active)
        #expect(c.handle(.toggle(.display)).exitCode == 3)
        #expect(c.snapshot.modes["display"]!.automaticStart)
        _ = c.handle(.off(.display))
        power.value = .init(source: .ac, batteryPercent: nil); c.refreshPower()
        #expect(!c.snapshot.modes["display"]!.active)
        _ = c.handle(.auto(.display, true))
        #expect(c.snapshot.modes["display"]!.active)
        _ = c.handle(.auto(.display, false))
        #expect(c.snapshot.modes["display"]!.active)
        power.value = .init(source: .battery, batteryPercent: 80); c.refreshPower()
        power.value = .init(source: .ac, batteryPercent: nil); c.refreshPower()
        #expect(!c.snapshot.modes["display"]!.active)
    }
    @Test func automaticPolicyStopsAndRestartsButManualDoesNot() {
        let power = FakePower()
        let c = Controller(assertions: FakeAssertions(), power: power, settings: MemorySettings())
        _ = c.handle(.auto(.display, true)); _ = c.handle(.on(.system))
        power.value = .init(source: .unknown, batteryPercent: nil); c.refreshPower()
        #expect(c.snapshot.modes.values.allSatisfy { !$0.active })
        power.value = .init(source: .ac, batteryPercent: nil); c.refreshPower()
        #expect(c.snapshot.modes["display"]!.active)
        #expect(!c.snapshot.modes["system"]!.active)
        power.value = .init(source: .battery, batteryPercent: 20)
        _ = c.handle(.policy(.display, .batteryAbove20))
        #expect(!c.snapshot.modes["display"]!.active)
        power.value.batteryPercent = 21; c.refreshPower()
        #expect(c.snapshot.modes["display"]!.active)
    }
    @Test func offAllDisablesEveryWaitingMode() {
        let power = FakePower(); power.value = .init(source: .battery, batteryPercent: 80)
        let c = Controller(assertions: FakeAssertions(), power: power, settings: MemorySettings())
        for mode in Mode.allCases { _ = c.handle(.auto(mode, true)) }
        _ = c.handle(.offAll)
        power.value.source = .ac; c.refreshPower()
        #expect(c.snapshot.modes.values.allSatisfy { !$0.active && !$0.automaticStart })
    }
    @Test func startupRestoresOnlyAutomationAndQuitPreservesIt() {
        let settings = MemorySettings()
        let assertions = FakeAssertions()
        let c = Controller(assertions: assertions, power: FakePower(), settings: settings)
        _ = c.handle(.auto(.display, true)); _ = c.handle(.on(.disk))
        #expect(c.handle(.quit).exitCode == 0)
        #expect(assertions.owned.isEmpty)
        #expect(c.handle(.on(.system)).exitCode == 4)
        let next = Controller(assertions: FakeAssertions(), power: FakePower(), settings: settings)
        #expect(next.snapshot.modes["display"]!.active)
        #expect(!next.snapshot.modes["disk"]!.active)
        _ = next.handle(.toggle(.display))
        #expect(!next.snapshot.modes["display"]!.automaticStart)
    }
    @Test func assertionFailuresNeverReportFalseState() {
        let assertions = FakeAssertions()
        let c = Controller(assertions: assertions, power: FakePower(), settings: MemorySettings())
        assertions.failCreate = true
        #expect(c.handle(.on(.display)).exitCode == 6)
        #expect(!c.snapshot.modes["display"]!.active)
        assertions.failCreate = false
        _ = c.handle(.on(.display))
        assertions.failRelease = true
        #expect(c.handle(.off(.display)).exitCode == 6)
        #expect(c.snapshot.modes["display"]!.active)
        #expect(!c.snapshot.modes["display"]!.automaticStart)
        #expect(c.handle(.quit).exitCode == 6)
        #expect(c.snapshot.modes["display"]!.active)
    }
    @Test func failedSaveDisablesAutomationInMemory() {
        let settings = MemorySettings()
        let c = Controller(assertions: FakeAssertions(), power: FakePower(), settings: settings)
        _ = c.handle(.auto(.display, true))
        settings.failSave = true
        #expect(c.handle(.off(.display)).exitCode == 6)
        #expect(!c.snapshot.modes["display"]!.active)
        #expect(!c.snapshot.modes["display"]!.automaticStart)
        #expect(c.snapshot.error != nil)
        settings.failSave = false
        #expect(c.handle(.off(.display)).exitCode == 0)
        #expect(c.snapshot.error == nil)
    }
    @Test func corruptSettingsRemainVisibleAndAreNotOverwritten() {
        let settings = MemorySettings(); settings.failLoad = true
        let c = Controller(assertions: FakeAssertions(), power: FakePower(), settings: settings)
        #expect(c.snapshot.error != nil)
        #expect(c.handle(.auto(.display, true)).exitCode == 6)
        #expect(settings.saves == 0)
    }
    @Test func disablingWaitingAutomationDoesNotBrieflyCreateAssertion() {
        for disable in [ControlCommand.off(.display), .offAll, .auto(.display, false)] {
            let assertions = FakeAssertions()
            let power = FakePower(); power.value.source = .battery
            let c = Controller(assertions: assertions, power: power, settings: MemorySettings())
            _ = c.handle(.auto(.display, true))
            power.value.source = .ac
            #expect(c.handle(disable).exitCode == 0)
            #expect(assertions.createCalls == 0)
            #expect(!c.snapshot.modes["display"]!.active)
        }
    }
    @Test func toggleUsesActualStateAndRetriesCreationOnlyOnce() {
        let assertions = FakeAssertions()
        let power = FakePower(); power.value.source = .battery
        let c = Controller(assertions: assertions, power: power, settings: MemorySettings())
        _ = c.handle(.auto(.display, true))
        power.value.source = .ac
        #expect(c.handle(.toggle(.display)).exitCode == 0)
        #expect(c.snapshot.modes["display"]!.active)
        #expect(c.snapshot.modes["display"]!.automaticStart)
        assertions.failCreate = true
        _ = c.handle(.on(.disk))
        let before = assertions.createCalls
        #expect(c.handle(.on(.disk)).exitCode == 6)
        #expect(assertions.createCalls == before + 1)
    }
    @Test func statusReconcilesCurrentPowerAndShutdownNeverRestarts() {
        let power = FakePower()
        let assertions = FakeAssertions()
        let c = Controller(assertions: assertions, power: power, settings: MemorySettings())
        _ = c.handle(.auto(.display, true))
        power.value.source = .battery
        #expect(!c.handle(.status).snapshot.modes["display"]!.active)
        _ = c.shutdown()
        power.value.source = .ac
        #expect(!c.handle(.status).snapshot.serviceRunning)
        #expect(!c.snapshot.modes["display"]!.active)
        #expect(c.shutdown().exitCode == 0)
    }
    @Test func turningOnAfterReleaseFailureClearsObsoleteStopError() {
        let assertions = FakeAssertions()
        let c = Controller(assertions: assertions, power: FakePower(), settings: MemorySettings())
        _ = c.handle(.on(.display))
        assertions.failRelease = true
        #expect(c.handle(.off(.display)).exitCode == 6)
        #expect(c.handle(.on(.display)).exitCode == 0)
        #expect(c.snapshot.modes["display"]!.error == nil)
        #expect(assertions.createCalls == 1)
    }
    @Test func fileSettingsRoundTripAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSettingsStore(url: directory.appendingPathComponent("settings.json"))
        #expect(try store.load() == SavedSettings())
        let saved = SavedSettings(modes: ["disk": ModeSettings(automaticStart: true, policy: .allowBattery)])
        try store.save(saved)
        #expect(try store.load() == saved)
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
    }
}
