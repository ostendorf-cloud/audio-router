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
///
/// Events come from the difference of two reads, so two cases are not what they look like:
/// - A main process that is replaced between two reads shows as `helperStopped` plus
///   `helperStarted`, not as quit and start. The restart on `helperStarted` covers it.
/// - Regrouping can show a quit of a pseudo app followed by `appStarted` of the parent. An id
///   such as `com.example.App.Extra` is its own app until `com.example.App` appears, then it
///   becomes a member of that app. The behaviour is kept and a test pins the sequence.
public protocol ProcessMonitoring: Sendable {
    /// Calls `handler` for every event, serialized and in order, on an arbitrary thread. Apps that
    /// run when the monitor starts arrive as `appStarted`. The handler is not called for the
    /// process of the caller itself. After `cancel` returned no further call begins. Dropping the
    /// returned value without `cancel` also stops the monitor, but `cancel` is the clear way.
    /// Throws when the process list cannot be read at the start.
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
    private let ownPID: Int32
    private let ownBundleID: String

    /// `ownPID` and `ownBundleID` name the process of the caller. It is dropped from the events,
    /// because an app that routes becomes a Core Audio client itself.
    public init(
        processes: any ProcessProviding, observer: any ProcessListObserving,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        ownBundleID: String = Bundle.main.bundleIdentifier ?? ProcessFilter.ownBundleID
    ) {
        self.processes = processes
        self.observer = observer
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    public func start(_ handler: @escaping @Sendable (ProcessEvent) -> Void) throws -> any Cancellable {
        let session = ProcessMonitorSession(
            processes: processes, ownPID: ownPID, ownBundleID: ownBundleID, handler: handler)
        // Register first, then read once: a process that starts in between is not missed. The
        // listener holds the session weakly, so dropping the handle ends the monitor.
        session.registration = try observer.observeProcessList { [weak session] in
            session?.refresh()
        }
        do {
            try session.read()
        } catch {
            session.cancel()
            throw ProcessMonitorError.initialReadFailed("\(error)")
        }
        return session
    }
}

/// The monitor could not start.
public enum ProcessMonitorError: Error, Equatable, CustomStringConvertible {
    /// The first read of the process list failed. The text is the underlying error.
    case initialReadFailed(String)

    public var description: String {
        switch self {
        case .initialReadFailed(let reason):
            return "Cannot read the audio process list: \(reason)"
        }
    }
}

/// One running monitor. A recursive lock serializes the refreshes and the handler calls, so
/// events keep their order and `cancel` from inside the handler does not deadlock.
///
/// Dropping the last handle inside the handler does not stop the batch that is being delivered:
/// the weak load of the listener keeps the session alive until `read` returns, and `deinit` then
/// runs on the listener queue. Only `cancel` inside the handler stops the rest of the batch.
private final class ProcessMonitorSession: Cancellable, @unchecked Sendable {
    private let processes: any ProcessProviding
    private let ownPID: Int32
    private let ownBundleID: String
    private let handler: @Sendable (ProcessEvent) -> Void
    private let lock = NSRecursiveLock()
    private var known: [AppGroup] = []
    private var cancelled = false
    var registration: (any Cancellable)?

    init(
        processes: any ProcessProviding, ownPID: Int32, ownBundleID: String,
        handler: @escaping @Sendable (ProcessEvent) -> Void
    ) {
        self.processes = processes
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
        self.handler = handler
    }

    /// Ends the monitor when the last handle is dropped. See the note on the class.
    /// If the listener fires while `start` registers and the first read then fails, the handler
    /// may already have received events before `start` throws `initialReadFailed`.
    deinit { cancel() }

    /// A change notice. A failed read keeps the last snapshot, the next change reads again.
    func refresh() {
        try? read()
    }

    func read() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        let list = ProcessFilter.withoutSelf(try processes.processes(), bundleID: ownBundleID, pid: ownPID)
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
