import Foundation

enum Mode: String, Codable, CaseIterable, Sendable { case display, system, disk }
enum PowerPolicy: String, Codable, CaseIterable, Sendable {
    case allowBattery = "allow-battery"
    case pluggedIn = "plugged-in"
    case batteryAbove20 = "battery-above-20"

    func blockedReason(for power: PowerSnapshot) -> String? {
        if self == .allowBattery || power.source == .ac { return nil }
        guard power.source == .battery else { return "Power source unknown" }
        if self == .pluggedIn { return "Requires external power" }
        guard let charge = power.batteryPercent, (0...100).contains(charge) else {
            return "Battery charge unknown"
        }
        return charge > 20 ? nil : "Battery must be above 20%"
    }
}
struct PowerSnapshot: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case ac, battery, unknown }
    var source: Source
    var batteryPercent: Int?
}
struct ModeSnapshot: Codable, Equatable, Sendable {
    var active: Bool
    var automaticStart: Bool
    var policy: PowerPolicy
    var blockedReason: String?
    var error: String?
}
struct ServiceSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var serviceRunning: Bool
    var power: PowerSnapshot
    var modes: [String: ModeSnapshot]
    var error: String?
}
enum ControlCommand: Codable, Sendable {
    case status, on(Mode), off(Mode), toggle(Mode), offAll
    case auto(Mode, Bool), policy(Mode, PowerPolicy), quit
}
struct ControlResponse: Codable, Sendable {
    var snapshot: ServiceSnapshot
    var exitCode: Int
    var message: String?
}
struct ModeSettings: Codable, Equatable, Sendable {
    var automaticStart = false
    var policy: PowerPolicy = .pluggedIn
}
struct SavedSettings: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var modes: [String: ModeSettings] = [:]
}
@MainActor protocol AssertionManaging {
    func create(mode: Mode) throws -> UInt32
    func release(id: UInt32) throws
}
@MainActor protocol PowerReading { func snapshot() -> PowerSnapshot }
@MainActor protocol SettingsStore {
    func load() throws -> SavedSettings
    func save(_ settings: SavedSettings) throws
}

@MainActor final class FileSettingsStore: SettingsStore {
    let url: URL
    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/cafectl/settings.json")) {
        self.url = url
    }
    func load() throws -> SavedSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedSettings() }
        let saved = try JSONDecoder().decode(SavedSettings.self, from: Data(contentsOf: url))
        guard saved.schemaVersion == 1 else { throw SettingsError.unsupportedVersion }
        return saved
    }
    func save(_ settings: SavedSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
    enum SettingsError: Error { case unsupportedVersion }
}

/// Owns only this process's assertion IDs. All callers run on the main actor.
@MainActor final class Controller {
    private struct State {
        var settings = ModeSettings()
        var requested = false
        var assertionID: UInt32?
        var error: String?
    }
    private let assertions: any AssertionManaging
    private let powerReader: any PowerReading
    private let settingsStore: any SettingsStore
    private var states: [Mode: State] = [:]
    private var power: PowerSnapshot
    private var running = true
    private var settingsError: String?
    // A corrupt file must remain available for recovery instead of being silently overwritten.
    private var settingsLoaded = true
    var onChange: ((ServiceSnapshot) -> Void)?

    init(assertions: any AssertionManaging, power: any PowerReading, settings: any SettingsStore) {
        self.assertions = assertions
        self.powerReader = power
        self.settingsStore = settings
        self.power = power.snapshot()
        var saved = SavedSettings()
        do {
            saved = try settings.load()
            guard saved.schemaVersion == 1 else { throw FileSettingsStore.SettingsError.unsupportedVersion }
        } catch {
            saved = SavedSettings()
            settingsLoaded = false
            settingsError = "Could not load settings: \(error.localizedDescription)"
        }
        for mode in Mode.allCases {
            states[mode] = State(settings: saved.modes[mode.rawValue] ?? ModeSettings())
        }
        reconcile()
    }

    var snapshot: ServiceSnapshot {
        ServiceSnapshot(serviceRunning: running, power: power,
            modes: Dictionary(uniqueKeysWithValues: Mode.allCases.map { mode in
                let state = states[mode]!
                return (mode.rawValue, ModeSnapshot(active: state.assertionID != nil,
                    automaticStart: state.settings.automaticStart, policy: state.settings.policy,
                    blockedReason: state.settings.policy.blockedReason(for: power), error: state.error))
            }), error: settingsError)
    }

    func refreshPower() {
        guard running else { return }
        power = powerReader.snapshot()
        reconcile()
        publish()
    }

    func handle(_ command: ControlCommand) -> ControlResponse {
        if case .status = command {
            refreshPower()
            return response()
        }
        guard running else { return response(code: 4, message: "Service not running") }
        if case .quit = command { return shutdown() }
        power = powerReader.snapshot()
        var saveNeeded = false
        var blocked: String?
        switch command {
        case .on(let mode): blocked = turnOn(mode)
        case .off(let mode): turnOff(mode); saveNeeded = true
        case .toggle(let mode):
            if states[mode]!.assertionID != nil { turnOff(mode); saveNeeded = true }
            else { blocked = turnOn(mode) }
        case .offAll:
            for mode in Mode.allCases { turnOff(mode) }
            saveNeeded = true
        case .auto(let mode, let enabled):
            states[mode]!.settings.automaticStart = enabled
            // Disabling automation preserves an already active assertion.
            if !enabled && states[mode]!.assertionID != nil { states[mode]!.requested = true }
            saveNeeded = true
        case .policy(let mode, let policy):
            states[mode]!.settings.policy = policy
            saveNeeded = true
        case .status, .quit: break
        }
        reconcile()
        if saveNeeded { persist() }
        publish()
        if let failure = failureMessage { return response(code: 6, message: failure) }
        if let blocked { return response(code: 3, message: blocked) }
        return response()
    }

    func shutdown() -> ControlResponse {
        running = false
        for mode in Mode.allCases { release(mode) }
        publish()
        return response(code: failureMessage == nil ? 0 : 6, message: failureMessage)
    }

    private func turnOn(_ mode: Mode) -> String? {
        if let reason = states[mode]!.settings.policy.blockedReason(for: power) { return reason }
        states[mode]!.requested = true
        return nil
    }
    private func turnOff(_ mode: Mode) {
        states[mode]!.requested = false
        states[mode]!.settings.automaticStart = false
    }
    private func reconcile() {
        for mode in Mode.allCases {
            let allowed = states[mode]!.settings.policy.blockedReason(for: power) == nil
            if !allowed { states[mode]!.requested = false }
            let wanted = allowed && (states[mode]!.requested || states[mode]!.settings.automaticStart)
            if wanted {
                guard states[mode]!.assertionID == nil else {
                    states[mode]!.error = nil
                    continue
                }
                do {
                    states[mode]!.assertionID = try assertions.create(mode: mode)
                    states[mode]!.error = nil
                } catch { states[mode]!.error = "Could not start \(mode.rawValue): \(error.localizedDescription)" }
            } else { release(mode) }
        }
    }
    private func release(_ mode: Mode) {
        guard let id = states[mode]!.assertionID else { states[mode]!.error = nil; return }
        do {
            try assertions.release(id: id)
            states[mode]!.assertionID = nil
            states[mode]!.error = nil
        } catch { states[mode]!.error = "Could not stop \(mode.rawValue): \(error.localizedDescription)" }
    }
    private func persist() {
        guard settingsLoaded else { return }
        let saved = SavedSettings(modes: Dictionary(uniqueKeysWithValues:
            Mode.allCases.map { ($0.rawValue, states[$0]!.settings) }))
        do { try settingsStore.save(saved); settingsError = nil }
        catch { settingsError = "Could not save settings: \(error.localizedDescription)" }
    }
    private var failureMessage: String? {
        settingsError ?? Mode.allCases.compactMap { states[$0]!.error }.first
    }
    private func response(code: Int = 0, message: String? = nil) -> ControlResponse {
        ControlResponse(snapshot: snapshot, exitCode: code, message: message)
    }
    private func publish() { onChange?(snapshot) }
}
