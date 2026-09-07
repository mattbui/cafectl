import Foundation
import IOKit.pwr_mgt

struct AssertionError: LocalizedError {
    let operation: String
    let code: IOReturn
    var errorDescription: String? { "\(operation) failed, IOKit code \(code)" }
}

/// The controller owns assertion IDs. This adapter never searches for or releases
/// assertions belonging to another process.
@MainActor
final class IOKitAssertions: AssertionManaging {
    func create(mode: Mode) throws -> UInt32 {
        let type: String
        switch mode {
        case .display: type = kIOPMAssertionTypePreventUserIdleDisplaySleep
        case .system: type = kIOPMAssertionTypePreventUserIdleSystemSleep
        case .disk: type = kIOPMAssertPreventDiskIdle
        }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "cafectl \(mode.rawValue)" as CFString, &id
        )
        guard result == kIOReturnSuccess else {
            throw AssertionError(operation: "Create \(mode.rawValue) assertion", code: result)
        }
        return id
    }

    func release(id: UInt32) throws {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else {
            throw AssertionError(operation: "Release assertion \(id)", code: result)
        }
    }
}
