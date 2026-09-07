import Foundation
import Testing
@testable import cafectl

struct CommandsTests {
    @Test func acceptsStartAndStop() throws {
        guard case .start = try CLI.parse(["start"]) else {
            Issue.record("Expected foreground service startup")
            return
        }
        guard case .request(.quit, false) = try CLI.parse(["stop"]) else {
            Issue.record("Expected service shutdown request")
            return
        }
    }

    @Test func acceptsEveryModeAndPolicy() throws {
        for mode in Mode.allCases {
            for verb in ["on", "off", "toggle"] {
                guard case .request(_, false) = try CLI.parse([verb, mode.rawValue]) else { Issue.record("Expected request"); return }
            }
            for policy in PowerPolicy.allCases {
                guard case .request(.policy(let parsedMode, let parsedPolicy), false) = try CLI.parse(["policy", mode.rawValue, policy.rawValue]) else { Issue.record("Expected policy"); return }
                #expect(parsedMode == mode)
                #expect(parsedPolicy == policy)
            }
        }
        guard case .request(.auto(.display, false), false) = try CLI.parse(["auto", "display", "off"]) else { Issue.record("Expected auto off"); return }
    }

    @Test func rejectsInvalidAndExtraArguments() {
        for arguments in [["launch"], ["status", "--launch"], ["start", "--json"], ["stop", "--json"], ["serve"], ["quit"], ["toggle", "screen"], ["off-all", "disk"], ["auto", "disk", "true"], ["policy", "disk", "battery"], ["on", "disk", "--json"]] {
            #expect(throws: CLIArgumentError.self) { try CLI.parse(arguments) }
        }
    }

    @Test func stoppedJSONIsMachineReadable() throws {
        let data = Data(try CLI.unavailableJSON().utf8)
        let snapshot = try JSONDecoder().decode(ServiceSnapshot.self, from: data)
        #expect(!snapshot.serviceRunning)
        #expect(snapshot.schemaVersion == 1)
    }

    @Test func outputDescribesWaitingAndFailures() throws {
        let snapshot = ServiceSnapshot(serviceRunning: true, power: .init(source: .battery, batteryPercent: 20), modes: ["display": .init(active: false, automaticStart: true, policy: .batteryAbove20, blockedReason: "Battery must be above 20%", error: "failed")])
        let response = ControlResponse(snapshot: snapshot, exitCode: 6, message: nil)
        let text = try CLI.format(response, json: false)
        #expect(text.contains("display: Waiting"))
        #expect(text.contains("automatic start on"))
        #expect(text.contains("Battery must be above 20%"))
        #expect(text.contains("error: failed"))
        #expect(try JSONDecoder().decode(ServiceSnapshot.self, from: Data(CLI.format(response, json: true).utf8)) == snapshot)
    }
}
