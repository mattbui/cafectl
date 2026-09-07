import Testing
import AppKit
import IOKit.ps
@testable import cafectl

@Suite @MainActor
struct NativeTests {
    @Test func confirmedDesktopACNeedsNoBattery() {
        #expect(IOKitPower.decode(provider: kIOPSACPowerValue, descriptions: []) ==
                PowerSnapshot(source: .ac, batteryPercent: nil))
        #expect(IOKitPower.decode(provider: nil, descriptions: []).source == .unknown)
        #expect(IOKitPower.decode(provider: "UPS Power", descriptions: []).source == .unknown)
    }

    @Test func capacityUsesMaximumAndConservativeRounding() {
        let battery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 419, kIOPSMaxCapacityKey: 2000]
        #expect(IOKitPower.decode(provider: kIOPSBatteryPowerValue, descriptions: [battery]) ==
                PowerSnapshot(source: .battery, batteryPercent: 20))
    }

    @Test func missingInvalidAndExternalCapacityAreUnknown() {
        for description: [String: Any] in [
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 20],
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 20, kIOPSMaxCapacityKey: 0],
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 101, kIOPSMaxCapacityKey: 100],
            [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100]
        ] {
            #expect(IOKitPower.decode(provider: kIOPSBatteryPowerValue, descriptions: [description])
                .batteryPercent == nil)
        }
    }

    @Test func pillColorsFollowVisibleModePriority() {
        #expect(MenuBar.backgroundColor(activeModes: []) == nil)
        #expect(MenuBar.backgroundColor(activeModes: [.system]) == nil)
        let blue = NSColor(srgbRed: 18 / 255.0, green: 144 / 255.0, blue: 254 / 255.0, alpha: 1)
        let orange = NSColor(srgbRed: 1, green: 143 / 255.0, blue: 11 / 255.0, alpha: 1)
        #expect(MenuBar.backgroundColor(activeModes: [.display, .disk, .system]) == blue)
        #expect(MenuBar.backgroundColor(activeModes: [.disk, .system]) == orange)
    }

    @Test func prioritySymbolsAndCountsCoverEveryState() {
        let cases: [([Mode], [String])] = [
            ([], ["cup.and.saucer"]),
            ([.display], ["display"]),
            ([.system], ["cup.and.saucer.fill"]),
            ([.disk], ["internaldrive"]),
            ([.system, .display], ["display", "2.circle.fill"]),
            ([.system, .disk], ["internaldrive", "2.circle.fill"]),
            ([.disk, .display], ["display", "2.circle.fill"]),
            ([.system, .disk, .display], ["display", "3.circle.fill"])
        ]
        for (modes, expected) in cases {
            #expect(MenuBar.symbolNames(activeModes: modes) == expected)
        }
    }
}
