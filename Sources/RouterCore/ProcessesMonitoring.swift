// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A change in the set of audio client processes, seen per parent app.
public enum ProcessEvent: Equatable, Sendable {
    /// An app has its first process. Also sent once per running app when the monitor starts.
    case appStarted(AppGroup)
    /// A process joined an app that was already known, for example a helper.
    case helperStarted(bundleID: String, process: AudioProcess)
    /// A process left an app that still has other processes.
    case helperStopped(bundleID: String, process: AudioProcess)
    /// The last process of an app is gone.
    case appQuit(bundleID: String)
}

/// Reports when an app or one of its helpers appears or disappears.
///
/// Known limit: a helper that starts after a route started is not tapped until the route
/// restarts. The tap is built over the process objects that exist at that moment, and the macOS
/// 26 `CATapDescription.bundleIDs` API that follows an app by id is out of reach with a 14.2 floor.
/// A consumer that wants the helper in the route has to restart the route on `helperStarted`.
public protocol ProcessMonitoring: Sendable {
    /// Calls `handler` for every event, serialized and in order, on an arbitrary thread. Apps that
    /// run when the monitor starts arrive as `appStarted`. After `cancel` returned no further call
    /// begins. Keep the returned value alive as long as events are wanted.
    func start(_ handler: @escaping @Sendable (ProcessEvent) -> Void) throws -> any Cancellable
}

/// Reports changes of the process object list. The real implementation is a Core Audio property
/// listener, tests use a fake.
public protocol ProcessListObserving: Sendable {
    /// Calls `handler` when the list may have changed. The handler must re-read the list.
    /// `cancel` removes the listener.
    func observeProcessList(_ handler: @escaping @Sendable () -> Void) throws -> any Cancellable
}

/// Computes events from two snapshots, grouped with `BundleGrouping`.
public enum ProcessDiff {
    /// The events that turn the groups `old` into the groups `new`. Order: quits, helper stops,
    /// app starts, helper starts. Each part is sorted by bundle id then pid.
    public static func events(from old: [AppGroup], to new: [AppGroup]) -> [ProcessEvent] {
        let oldByID = Dictionary(old.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        let newByID = Dictionary(new.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        var quits: [ProcessEvent] = []
        var stops: [ProcessEvent] = []
        var starts: [ProcessEvent] = []
        var joins: [ProcessEvent] = []
        for id in oldByID.keys.sorted() where newByID[id] == nil {
            quits.append(.appQuit(bundleID: id))
        }
        for id in newByID.keys.sorted() {
            guard let group = newByID[id] else { continue }
            guard let before = oldByID[id] else {
                starts.append(.appStarted(group))
                continue
            }
            let oldIDs = Set(before.processes.map(\.objectID))
            let newIDs = Set(group.processes.map(\.objectID))
            stops += before.processes.filter { !newIDs.contains($0.objectID) }
                .map { .helperStopped(bundleID: id, process: $0) }
            joins += group.processes.filter { !oldIDs.contains($0.objectID) }
                .map { .helperStarted(bundleID: id, process: $0) }
        }
        return quits + stops + starts + joins
    }
}

/// Watches the process list through a `ProcessListObserving` and turns each change into events.
public struct ProcessMonitor: ProcessMonitoring {
    private let processes: any ProcessProviding
    private let observer: any ProcessListObserving

    public init(processes: any ProcessProviding, observer: any ProcessListObserving) {
        self.processes = processes
        self.observer = observer
    }

    public func start(_ handler: @escaping @Sendable (ProcessEvent) -> Void) throws -> any Cancellable {
        let session = ProcessMonitorSession(processes: processes, handler: handler)
        // Register first, then read once: a process that starts in between is not missed.
        session.registration = try observer.observeProcessList { session.refresh() }
        session.refresh()
        return session
    }
}

/// One running monitor. A recursive lock serializes the refreshes and the handler calls, so
/// events keep their order and `cancel` from inside the handler does not deadlock.
private final class ProcessMonitorSession: Cancellable, @unchecked Sendable {
    private let processes: any ProcessProviding
    private let handler: @Sendable (ProcessEvent) -> Void
    private let lock = NSRecursiveLock()
    private var known: [AppGroup] = []
    private var cancelled = false
    var registration: (any Cancellable)?

    init(processes: any ProcessProviding, handler: @escaping @Sendable (ProcessEvent) -> Void) {
        self.processes = processes
        self.handler = handler
    }

    func refresh() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        // A failed read keeps the last snapshot. The next change reads again.
        guard let list = try? processes.processes() else { return }
        let groups = BundleGrouping.groups(list)
        let events = ProcessDiff.events(from: known, to: groups)
        known = groups
        for event in events {
            guard !cancelled else { return }
            handler(event)
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        registration?.cancel()
        registration = nil
    }
}
