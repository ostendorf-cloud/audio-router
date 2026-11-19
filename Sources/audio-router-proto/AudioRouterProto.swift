// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
import RouterCore

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
        try session.start()

        // Every way out goes through finish, so the tap and the aggregate device never outlive
        // the command. The signal handlers run on the main queue, not in signal context.
        let finish: @Sendable (Int32, String?) -> Never = { code, message in
            let leftovers = session.stop()
            if let message { FileHandle.standardError.write(Data((message + "\n").utf8)) }
            for leftover in leftovers {
                FileHandle.standardError.write(Data("teardown: \(leftover)\n".utf8))
            }
            exit(leftovers.isEmpty ? code : 1)
        }
        var sources: [any DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { finish(0, "stopped") }
            source.resume()
            sources.append(source)
        }

        // The target device disappearing ends the route. Re-routing is a later phase.
        let uid = plan.device.uid
        let observer = try devices.observeDeviceList {
            let present = (try? devices.outputDevices())?.contains { $0.uid == uid } ?? false
            if !present { finish(1, "error: output device \(uid) is gone") }
        }

        let apps = plan.processes.count
        print(
            "Routing \(plan.appBundleID) (\(apps) processes) to \(plan.device.name), "
                + "channels \(plan.channels.first),\(plan.channels.second). Press Ctrl-C to stop."
        )
        withExtendedLifetime((sources, observer)) { dispatchMain() }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
