import AppKit
import Darwin

@main
enum Cafectl {
    @MainActor
    static func main() {
        do {
            switch try CLI.parse(Array(CommandLine.arguments.dropFirst())) {
            case .help:
                print(CLI.help)
            case .start:
                let runtime = ServiceRuntime()
                try runtime.start()
                withExtendedLifetime(runtime) { NSApplication.shared.run() }
            case .request(let command, let json):
                let response: ControlResponse
                do { response = try IPCClient().send(command) }
                catch IPCError.unavailable {
                    if json { print(try CLI.unavailableJSON()) }
                    throw IPCError.unavailable
                }
                var output = response
                if response.exitCode != 0, let message = response.message {
                    writeError(message)
                    output.message = nil
                }
                print(try CLI.format(output, json: json))
                Darwin.exit(Int32(response.exitCode))
            }
        } catch let error as CLIArgumentError {
            writeError(error.localizedDescription)
            Darwin.exit(2)
        } catch let error as IPCError {
            writeError(error.localizedDescription)
            Darwin.exit(Int32(error.exitCode))
        } catch {
            writeError(error.localizedDescription)
            Darwin.exit(6)
        }
    }

    static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// AppKit and live adapters are constructed only by the explicit start command.
@MainActor
private final class ServiceRuntime: NSObject, NSApplicationDelegate {
    private var server: IPCServer?
    private var controller: Controller?
    private var menu: MenuBar?
    private var monitor: PowerMonitor?
    private var signals: [DispatchSourceSignal] = []
    private var terminating = false

    func start() throws {
        guard getuid() != 0 else {
            throw CLIArgumentError("Run cafectl start as your login user, without sudo.")
        }
        let server = try IPCServer(handler: { [self] command in
            await handle(command)
        }, onQuit: { [self] response in
            Task { @MainActor in terminate(exitCode: response.exitCode) }
        })
        // Acquire the lifetime lock before saved automation can create assertions.
        try server.prepare()
        self.server = server
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.delegate = self
            let power = IOKitPower()
            let controller = Controller(assertions: IOKitAssertions(), power: power,
                                        settings: FileSettingsStore())
            self.controller = controller
            let menu = MenuBar { [weak self] command in
                guard let self else { return }
                let response = self.handle(command)
                if case .quit = command { self.terminate(exitCode: response.exitCode) }
            }
            self.menu = menu
            controller.onChange = { [weak self] snapshot in self?.menu?.update(snapshot: snapshot) }
            menu.update(snapshot: controller.snapshot)
            let monitor = PowerMonitor { [weak self] in
                guard let controller = self?.controller else {
                    return PowerSnapshot(source: .unknown, batteryPercent: nil)
                }
                controller.refreshPower()
                return controller.snapshot.power
            }
            self.monitor = monitor
            try monitor.start()
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.terminate(exitCode: 0) }
                }
                signals.append(source)
                source.resume()
            }
            try server.start()
        } catch {
            monitor?.stop()
            _ = controller?.shutdown()
            menu?.remove()
            for source in signals { source.cancel() }
            server.stop()
            throw error
        }
    }

    private func handle(_ command: ControlCommand) -> ControlResponse {
        guard let controller else {
            return ControlResponse(snapshot: ServiceSnapshot(serviceRunning: false,
                power: PowerSnapshot(source: .unknown, batteryPercent: nil), modes: [:]),
                exitCode: 4, message: "Service not running")
        }
        let response = controller.handle(command)
        monitor?.retryIfNeeded(snapshot: response.snapshot.power)
        if case .status = command { return response }
        menu?.update(snapshot: response.snapshot, message: response.exitCode == 0 ? nil : response.message)
        return response
    }

    private func terminate(exitCode: Int) {
        guard !terminating else { return }
        terminating = true
        server?.stop()
        monitor?.stop()
        let result = controller?.shutdown()
        menu?.remove()
        for source in signals { source.cancel() }
        let code = max(exitCode, result?.exitCode ?? 0)
        if code != 0, let message = result?.message { Cafectl.writeError(message) }
        Task {
            await server?.stopAndWait()
            Darwin.exit(Int32(code))
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminate(exitCode: 0)
        return .terminateLater
    }
}
