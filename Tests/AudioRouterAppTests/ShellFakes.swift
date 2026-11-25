// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore

@testable import AudioRouterAppCore

/// A scripted engine. `emit` plays the engine queue: it calls the observers on the calling thread.
final class FakeShellEngine: ShellEngine, @unchecked Sendable {
    struct StartFailure: Error {}

    private let lock = NSLock()
    private var current: EngineSnapshot
    private var handlers: [@Sendable (EngineSnapshot) -> Void] = []
    private var recorded: [String] = []
    private var routesSet: [[Route]] = []
    private var stopFinished = false
    private let gate: DispatchSemaphore?
    var startError: Error?

    /// `gate` makes `stopAll` block until the test signals it.
    init(snapshot: EngineSnapshot = .empty, gate: DispatchSemaphore? = nil) {
        current = snapshot
        self.gate = gate
    }

    var snapshot: EngineSnapshot { lock.withLock { current } }
    var calls: [String] { lock.withLock { recorded } }
    var routeCalls: [[Route]] { lock.withLock { routesSet } }
    var stopAllFinished: Bool { lock.withLock { stopFinished } }

    func observe(_ handler: @escaping @Sendable (EngineSnapshot) -> Void) -> any Cancellable {
        let snapshot = lock.withLock {
            handlers.append(handler)
            return current
        }
        handler(snapshot)
        return NoCancel()
    }

    func emit(_ snapshot: EngineSnapshot) {
        let targets = lock.withLock {
            current = snapshot
            return handlers
        }
        for handler in targets { handler(snapshot) }
    }

    func start() throws {
        lock.withLock { recorded.append("start") }
        if let startError { throw startError }
    }

    func setRoutes(_ routes: [Route]) {
        lock.withLock {
            recorded.append("setRoutes")
            routesSet.append(routes)
        }
    }

    func setOn(_ on: Bool) {
        lock.withLock { recorded.append("setOn(\(on))") }
        emit(
            EngineSnapshot(isOn: on, routes: snapshot.routes, devices: snapshot.devices, apps: snapshot.apps))
    }

    func retryNow(_ id: UUID) {
        lock.withLock { recorded.append("retryNow(\(id.uuidString))") }
    }

    func stopAll() -> [UUID: [String]] {
        lock.withLock { recorded.append("stopAll") }
        gate?.wait()
        lock.withLock { stopFinished = true }
        return [:]
    }

    func meterReadings() -> [UUID: MeterReading] { [:] }

    private struct NoCancel: Cancellable {
        func cancel() {}
    }
}

enum ShellSamples {
    static let music = Route(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Music", appBundleID: "com.example.music",
        destinationUID: "dev", destinationPair: try! ChannelPair(first: 3))
    static let video = Route(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Video", appBundleID: "com.example.video",
        destinationUID: "dev", destinationPair: try! ChannelPair(first: 5))

    static func snapshot(isOn: Bool = true, _ states: [(Route, RouteState)]) -> EngineSnapshot {
        EngineSnapshot(
            isOn: isOn,
            routes: states.map { RouteStatus(route: $0.0, state: $0.1, teardownFailures: []) },
            devices: [], apps: [])
    }
}
