// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import RouterCore

/// A process list that tests change and a listener slot that tests fire.
final class FakeProcessList: ProcessProviding, ProcessListObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [AudioProcess]
    private var handler: (@Sendable () -> Void)?
    private var failing = false
    private(set) var registrations = 0
    private(set) var removals = 0

    init(_ processes: [AudioProcess] = []) { current = processes }

    var listenerInstalled: Bool { lock.withLock { handler != nil } }

    func set(_ processes: [AudioProcess]) { lock.withLock { current = processes } }

    func setFailing(_ value: Bool) { lock.withLock { failing = value } }

    /// Sets the list and calls the listener, if one is installed.
    func change(to processes: [AudioProcess]) {
        set(processes)
        fire()
    }

    func fire() { lock.withLock { handler }?() }

    func processes() throws -> [AudioProcess] {
        try lock.withLock {
            if failing { throw FakeFailure(step: "processes") }
            return current
        }
    }

    func observeProcessList(_ handler: @escaping @Sendable () -> Void) throws -> any Cancellable {
        lock.withLock {
            registrations += 1
            self.handler = handler
        }
        return Remover(self)
    }

    private struct Remover: Cancellable {
        let owner: FakeProcessList
        init(_ owner: FakeProcessList) { self.owner = owner }

        func cancel() {
            owner.lock.withLock {
                owner.removals += 1
                owner.handler = nil
            }
        }
    }
}

/// A monitor that emits the events a test scripts, without any process list.
final class FakeProcessMonitor: ProcessMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ProcessEvent) -> Void)?
    private(set) var cancels = 0

    func start(_ handler: @escaping @Sendable (ProcessEvent) -> Void) throws -> any Cancellable {
        lock.withLock { self.handler = handler }
        return Stop(self)
    }

    /// Delivers `events` in order. Nothing arrives after cancel.
    func emit(_ events: ProcessEvent...) {
        for event in events { lock.withLock { handler }?(event) }
    }

    private struct Stop: Cancellable {
        let owner: FakeProcessMonitor
        init(_ owner: FakeProcessMonitor) { self.owner = owner }

        func cancel() {
            owner.lock.withLock {
                owner.cancels += 1
                owner.handler = nil
            }
        }
    }
}

/// Collects events in order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProcessEvent] = []

    var events: [ProcessEvent] { lock.withLock { items } }

    func append(_ event: ProcessEvent) { lock.withLock { items.append(event) } }

    func clear() { lock.withLock { items.removeAll() } }
}
