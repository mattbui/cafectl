import Foundation

enum CLIInvocation {
    case help, start
    case request(ControlCommand, json: Bool)
}

struct CLIArgumentError: Error, LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum CLI {
    static let help = """
    Usage: cafectl <command>
      start                           Run the menu bar service in the foreground
      status [--json]                  Report the running service state
      on|off|toggle <mode>             Change display, system, or disk mode
      off-all                         Stop every mode and disable automation
      auto <mode> on|off               Set automatic start
      policy <mode> <policy>           Set allow-battery, plugged-in, or battery-above-20
      stop                            Stop the service without changing saved preferences
      help                            Show this help

    Control commands never start the service. Run start for development or use
    brew services start cafectl after installation.
    """

    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        guard let first = arguments.first else { return .help }
        if ["help", "--help", "-h"].contains(first), arguments.count == 1 { return .help }
        if first == "start", arguments.count == 1 { return .start }
        if first == "status", arguments.count == 1 || arguments == ["status", "--json"] {
            return .request(.status, json: arguments.count == 2)
        }
        if first == "off-all", arguments.count == 1 { return .request(.offAll, json: false) }
        if first == "stop", arguments.count == 1 { return .request(.quit, json: false) }
        if arguments.count >= 2, let mode = Mode(rawValue: arguments[1]) {
            if arguments.count == 2 {
                switch first {
                case "on": return .request(.on(mode), json: false)
                case "off": return .request(.off(mode), json: false)
                case "toggle": return .request(.toggle(mode), json: false)
                default: break
                }
            }
            if arguments.count == 3 {
                if first == "auto", ["on", "off"].contains(arguments[2]) {
                    return .request(.auto(mode, arguments[2] == "on"), json: false)
                }
                if first == "policy", let policy = PowerPolicy(rawValue: arguments[2]) {
                    return .request(.policy(mode, policy), json: false)
                }
            }
        }
        throw CLIArgumentError("Invalid arguments. Run cafectl help for usage.")
    }

    static func format(_ response: ControlResponse, json: Bool) throws -> String {
        if json { return try formatSnapshot(response.snapshot) }
        var lines: [String] = []
        if let message = response.message { lines.append(message) }
        lines.append(response.snapshot.serviceRunning ? "Service running" : "Service not running")
        let power = response.snapshot.power
        lines.append("Power: \(power.source.rawValue)" + (power.batteryPercent.map { " (\($0)%)" } ?? ""))
        for mode in Mode.allCases {
            guard let state = response.snapshot.modes[mode.rawValue] else { continue }
            let label = state.active ? "On" : state.automaticStart ? "Waiting" : "Off"
            var line = "\(mode.rawValue): \(label), automatic start \(state.automaticStart ? "on" : "off"), policy \(state.policy.rawValue)"
            if let reason = state.blockedReason { line += ", \(reason)" }
            if let error = state.error { line += ", error: \(error)" }
            lines.append(line)
        }
        if let error = response.snapshot.error { lines.append("Error: \(error)") }
        return lines.joined(separator: "\n")
    }

    static func unavailableJSON() throws -> String {
        try formatSnapshot(ServiceSnapshot(serviceRunning: false, power: PowerSnapshot(source: .unknown, batteryPercent: nil), modes: [:]))
    }

    private static func formatSnapshot(_ snapshot: ServiceSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    }
}
