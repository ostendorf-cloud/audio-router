// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
import RouterCore

/// True while `session.start()` runs. Set and cleared by the main thread, read by signal handlers.
private final class StartingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
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
            let processes = ProcessFilter.withoutSelf(
                try CoreAudioProcessProvider().processes(),
                bundleID: ProcessFilter.ownBundleID,
                pid: ProcessInfo.processInfo.processIdentifier
            )
            print(Formatting.apps(processes))
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
        let session = RouteSession(backend: CoreAudioRoutingBackend(), plan: plan, meter: arguments.meter)
        // Every write goes through Diagnostics: a closed terminal (SIGHUP) must not raise.
        let finisher = Finisher(
            session: session,
            exit: { exit($0) },
            write: { Diagnostics.write($0) },
            park: { while true { sleep(60) } }
        )
        let starting = StartingFlag()
        // A pipe closed by the reader (`| head`) must not kill the process without a teardown.
        signal(SIGPIPE, SIG_IGN)

        // The handlers are installed before the route starts. They run on their own concurrent
        // queue, not on the main thread, because the main thread is busy in `start`.
        // Core Audio calls cannot be cancelled. A stop during a slow start (for example a
        // permission prompt) therefore waits until `start` returns and then tears down: the
        // session holds its lock while it starts. The notice below says so and what to do.
        // SIGHUP (closed terminal) tears down like SIGINT and SIGTERM.
        let queue = DispatchQueue(label: "audio-router.signals", attributes: .concurrent)
        var sources: [any DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                if starting.isSet {
                    Diagnostics.write(
                        "stop requested while the route starts. The start cannot be cancelled, the route stops "
                            + "when it returns. If it hangs, kill the process: kill -KILL \(getpid()). Whether a "
                            + "tap or aggregate device survives that is not known, see docs/prototype-findings.md.\n")
                }
                finisher.finish(code: 0, message: "stopped")
            }
            source.resume()
            sources.append(source)
        }
        // Ctrl-Z would suspend the process and leave the app muted and the audio frozen until it
        // resumes, and a stopped process cannot tear down. Ignore it so the terminal cannot do that.
        signal(SIGTSTP, SIG_IGN)

        var observer: (any Cancellable)?
        starting.set(true)
        do {
            try session.start()
            starting.set(false)
            // The target device disappearing ends the route. Re-routing is a later phase.
            // The observer checks once right after it is registered, for a device lost during start.
            let uid = plan.device.uid
            observer = try DeviceWatch.start(devices: devices, uid: uid) {
                finisher.finish(code: 1, message: "error: output device \(uid) is gone")
            }
        } catch {
            starting.set(false)
            finisher.finish(code: 1, message: "error: \(error)")
            return
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
                // Two seconds later, name the channels that carried signal. It shows where the
                // app sits in the tap and whether a device input is hot.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    guard let active = session.activeInputChannels(), let info = session.routeInfo() else { return }
                    let found = ChannelMapper.activity(
                        active: active, inputBuffers: info.inputBuffers, tapBuffers: info.tapBuffers)
                    let line = Formatting.activity(
                        tap: found.tap, device: found.device, preferred: info.preferredStereo)
                    Diagnostics.write(line + "\n", to: STDOUT_FILENO)
                }
            case .silent:
                timer.cancel()
                Diagnostics.write(
                    Formatting.silenceWarning(
                        bundleID: plan.appBundleID, mode: plan.tapMode, deviceName: plan.device.name))
            }
        }
        timer.resume()

        // The meter lines go to stdout, once a second, from a utility queue. They cover the
        // interval before the last one, see MeterBlock.
        var meterTimer: (any DispatchSourceTimer)?
        if arguments.meter {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler {
                if let reading = session.meterReading() {
                    Diagnostics.write(Formatting.meter(reading) + "\n", to: STDOUT_FILENO)
                }
            }
            timer.resume()
            meterTimer = timer
        }

        let apps = plan.processes.count
        var lines = [
            "Routing \(plan.appBundleID) (\(apps) processes) to \(plan.device.name), "
                + "channels \(plan.channels.first),\(plan.channels.second). Press Ctrl-C to stop."
        ]
        if let info = session.routeInfo() { lines += Formatting.routeInfo(info) }
        if arguments.meter { lines.append("meter: stdout, once a second, covers the interval before the last one") }
        Diagnostics.write(lines.joined(separator: "\n") + "\n", to: STDOUT_FILENO)
        withExtendedLifetime((sources, observer, timer, meterTimer)) { dispatchMain() }
    }

    static func fail(_ message: String) -> Never {
        Diagnostics.write(message + "\n")
        exit(1)
    }
}
