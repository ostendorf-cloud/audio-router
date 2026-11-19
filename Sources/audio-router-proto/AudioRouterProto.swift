// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
import RouterCore

/// The one way out of a running route. The first caller tears the route down, waits until that
/// is finished and exits. Any later caller waits here until the process is gone, so a second
/// signal or a device removal cannot exit in the middle of the teardown or change the exit code.
final class Finisher: @unchecked Sendable {
    private let session: RouteSession
    private let lock = NSLock()
    private var finishing = false

    init(session: RouteSession) {
        self.session = session
    }

    func finish(code: Int32, message: String?) -> Never {
        let first = lock.withLock {
            defer { finishing = true }
            return !finishing
        }
        if !first {
            while true { sleep(60) }
        }
        let leftovers = session.stop()  // returns after the teardown completed
        if let message { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        for leftover in leftovers {
            FileHandle.standardError.write(Data("teardown: \(leftover)\n".utf8))
        }
        exit(leftovers.isEmpty ? code : 1)
    }
}

@main
struct AudioRouterProto {
    static func main() {
        do {
            let command = try ArgumentParser.parse(Array(CommandLine.arguments.dropFirst()))
            try run(command)
        } catch {
            fail("error: \(error)")
        }
    }

    static func run(_ command: Command) throws {
        switch command {
        case .help:
            print(ArgumentParser.usage)
        case .devices:
            print(Formatting.devices(try CoreAudioDeviceProvider().outputDevices()))
        case .apps:
            print(Formatting.apps(try CoreAudioProcessProvider().processes()))
        case .route(let arguments):
            try route(arguments)
        }
    }

    static func route(_ arguments: RouteArguments) throws {
        let devices = CoreAudioDeviceProvider()
        let plan = try RoutePlanner.plan(
            arguments,
            devices: try devices.outputDevices(),
            processes: try CoreAudioProcessProvider().processes()
        )
        let session = RouteSession(backend: CoreAudioRoutingBackend(), plan: plan)
        let finisher = Finisher(session: session)

        // The handlers are installed before the route starts. They run on the main queue, not in
        // signal context, and wait for a start in progress, because the session holds its lock
        // while it starts.
        // SIGHUP (closed terminal) tears down like SIGINT and SIGTERM.
        var sources: [any DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { finisher.finish(code: 0, message: "stopped") }
            source.resume()
            sources.append(source)
        }
        // Ctrl-Z would suspend the process and leave the app muted and the audio frozen until it
        // resumes, and a stopped process cannot tear down. Ignore it so the terminal cannot do that.
        signal(SIGTSTP, SIG_IGN)

        var observer: (any Cancellable)?
        do {
            try session.start()
            // The target device disappearing ends the route. Re-routing is a later phase.
            let uid = plan.device.uid
            observer = try devices.observeDeviceList {
                let present = (try? devices.outputDevices())?.contains { $0.uid == uid } ?? false
                if !present { finisher.finish(code: 1, message: "error: output device \(uid) is gone") }
            }
        } catch {
            finisher.finish(code: 1, message: "error: \(error)")
        }

        // Without audio for a while the usual cause is a missing permission or a paused app.
        let startedAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            switch session.signalState(elapsed: Date().timeIntervalSince(startedAt)) {
            case .waiting:
                break
            case .present:
                timer.cancel()
            case .silent:
                timer.cancel()
                FileHandle.standardError.write(
                    Data(
                        ("warning: no audio arrived in 10 seconds. If \(plan.appBundleID) is playing, the system audio "
                            + "capture permission may be missing or denied for this terminal app: a denied tap may "
                            + "deliver silence instead of an error. See docs/prototype-findings.md.\n").utf8))
            }
        }
        timer.resume()

        let apps = plan.processes.count
        print(
            "Routing \(plan.appBundleID) (\(apps) processes) to \(plan.device.name), "
                + "channels \(plan.channels.first),\(plan.channels.second). Press Ctrl-C to stop."
        )
        withExtendedLifetime((sources, observer, timer)) { dispatchMain() }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
