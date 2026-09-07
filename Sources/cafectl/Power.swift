import AppKit
import IOKit.ps

@MainActor
final class IOKitPower: PowerReading {
    func snapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let provider = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return PowerSnapshot(source: .unknown, batteryPercent: nil)
        }
        let descriptions: [[String: Any]]
        if let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            descriptions = sources.compactMap {
                IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
            }
        } else {
            descriptions = []
        }
        return Self.decode(provider: provider as String, descriptions: descriptions)
    }

    /// Keep extraction independent of the machine's current power for testing.
    static func decode(provider: String?, descriptions: [[String: Any]]) -> PowerSnapshot {
        let source: PowerSnapshot.Source
        switch provider {
        case kIOPSACPowerValue: source = .ac
        case kIOPSBatteryPowerValue: source = .battery
        default: source = .unknown // A UPS or missing battery data is not proof of AC.
        }
        let percentages = descriptions.compactMap { description -> Int? in
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                  current.isFinite, maximum.isFinite, maximum > 0, current >= 0,
                  current <= maximum else { return nil }
            return Int((current / maximum * 100).rounded(.down))
        }
        return PowerSnapshot(source: source, batteryPercent: percentages.min())
    }
}

/// Notifications run on the main run loop; one short retry sequence follows an
/// unreadable snapshot. There is no ongoing timer polling a healthy power source.
@MainActor
final class PowerMonitor {
    private let onChange: @MainActor () -> PowerSnapshot
    private var source: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var retry: Task<Void, Never>?
    private var running = false
    private var retryGeneration = 0

    init(onChange: @escaping @MainActor () -> PowerSnapshot) {
        self.onChange = onChange
    }

    func start() throws {
        guard !running else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().changed()
            }
        }, context)?.takeRetainedValue() else {
            throw NSError(domain: "cafectl.power", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot register power-source notifications"])
        }
        self.source = source
        running = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        changed()
    }

    func stop() {
        running = false
        retryGeneration += 1
        retry?.cancel()
        retry = nil
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func changed() {
        guard running else { return }
        retryIfNeeded(snapshot: onChange())
    }

    func retryIfNeeded(snapshot: PowerSnapshot) {
        guard running, retry == nil, Self.needsRetry(snapshot) else { return }
        retryGeneration += 1
        let generation = retryGeneration
        retry = Task { [weak self] in
            defer {
                if self?.retryGeneration == generation { self?.retry = nil }
            }
            for delay in [250_000_000, 750_000_000, 2_000_000_000] as [UInt64] {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, self.running, !Task.isCancelled else { return }
                if !Self.needsRetry(self.onChange()) { return }
            }
        }
    }

    private static func needsRetry(_ snapshot: PowerSnapshot) -> Bool {
        return snapshot.source == .unknown ||
            (snapshot.source == .battery && snapshot.batteryPercent == nil)
    }
}
