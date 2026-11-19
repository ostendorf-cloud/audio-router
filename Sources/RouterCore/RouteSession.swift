// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the IO proc has delivered so far.
public enum SignalState: Equatable, Sendable {
    /// Not started, or the wait is not over yet.
    case waiting
    /// A sample that is not zero went through.
    case present
    /// Only zeros for the whole wait. The app may be paused, or the capture permission is
    /// missing: a denied tap may deliver silence instead of an error.
    case silent
}

/// One running route: a tap over an app, an aggregate device on the target device and the IO
/// proc between them.
///
/// Creation order: tap, aggregate, IO proc. Teardown runs in the reverse order: IO proc,
/// aggregate, tap. The tap goes last because destroying it is what lets the app play normally
/// again, and nothing may still read from it by then.
///
/// One lock is held for the whole of `start` and of a teardown. A `stop` that arrives while
/// another thread starts or tears down waits until that is finished, so when `stop` returns the
/// teardown has completed, whichever thread ran it. A failed `start` rolls back what it created.
/// A `stop` before `start` makes the later `start` fail.
public final class RouteSession: @unchecked Sendable {
    private let backend: any AudioRoutingBackend
    private let plan: RoutePlan
    private let lock = NSLock()  // never used on the audio thread
    private var tap: TapInfo?
    private var aggregate: ObjectID?
    private var io: IOHandle?
    private var stopped = false
    private var startFailure: String?

    private let meter: Bool

    public init(backend: any AudioRoutingBackend, plan: RoutePlan, meter: Bool = false) {
        self.backend = backend
        self.plan = plan
        self.meter = meter
    }

    /// The layout and formats of the running route, nil before the start and after the stop.
    public func routeInfo() -> RouteInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let io, !stopped else { return nil }
        return backend.routeInfo(handle: io)
    }

    /// The input channels that carried signal since the start, nil before the start and after the stop.
    public func activeInputChannels() -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        guard let io, !stopped else { return nil }
        return backend.activeInputChannels(handle: io)
    }

    /// The levels of the last full interval, nil when the meter is off or still priming.
    public func meterReading() -> MeterReading? {
        lock.lock()
        defer { lock.unlock() }
        guard meter, let io, !stopped else { return nil }
        return backend.readMeter(handle: io)
    }

    /// Creates the tap, the aggregate device and the IO proc. On failure everything created so far
    /// is destroyed again before the error is thrown.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw RouterError.sessionAlreadyStopped }
        do {
            let tap = try backend.createTap(
                processes: plan.processes.map(\.objectID),
                name: "audio-router \(plan.appBundleID)",
                mode: plan.tapMode,
                deviceUID: plan.device.uid
            )
            self.tap = tap
            let aggregate = try backend.createAggregate(deviceUID: plan.device.uid, tap: tap)
            self.aggregate = aggregate
            io = try backend.startIO(
                aggregate: aggregate, tap: tap, device: plan.device, channels: plan.channels,
                sourceChannels: plan.sourceChannels, tapBuffer: plan.tapBuffer, meter: meter)
        } catch {
            let leftovers = teardownLocked()
            let thrown: Error =
                leftovers.isEmpty ? error : RouterError.teardownFailed([String(describing: error)] + leftovers)
            startFailure = "\(thrown)"  // set under the lock, so a stop that waited for it sees it
            throw thrown
        }
    }

    /// The text of the error a failed `start` threw, nil if there was none. Blocks while a start
    /// or teardown runs.
    public func failureOfStart() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return startFailure
    }

    /// Tears the route down and returns the messages of the steps that failed, empty on success.
    /// Blocks while another thread starts or tears down. Later calls return an empty list.
    @discardableResult
    public func stop() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return teardownLocked()
    }

    /// Whether audio has flowed. `elapsed` is the time since `start` finished.
    public func signalState(elapsed: TimeInterval, silenceAfter: TimeInterval = 10) -> SignalState {
        lock.lock()
        defer { lock.unlock() }
        guard let io, !stopped else { return .waiting }
        if backend.signalSeen(handle: io) { return .present }
        return elapsed >= silenceAfter ? .silent : .waiting
    }

    /// The tap check for the state the signal wait ended in: the activity line and the warning, if
    /// any. It runs for `.present` and for `.silent`. A buffer that is silent on the source pair never
    /// reaches `.present`, because only a routed channel sets the signal flag, yet that is the case
    /// the check exists for: the device input may be active while the tap shows nothing. `.waiting`
    /// has nothing to say. Control thread only.
    public func tapReport(for state: SignalState) -> (activity: String, warning: String?)? {
        switch state {
        case .waiting:
            return nil
        case .present, .silent:
            guard let active = activeInputChannels(), let info = routeInfo() else { return nil }
            return TapCheck.report(active: active, info: info)
        }
    }

    private func teardownLocked() -> [String] {
        guard !stopped else { return [] }
        stopped = true
        let (tap, aggregate, io) = (self.tap, self.aggregate, self.io)
        self.tap = nil
        self.aggregate = nil
        self.io = nil
        var failures: [String] = []
        func attempt(_ step: String, _ body: () throws -> Void) {
            do { try body() } catch { failures.append("\(step): \(error)") }
        }
        if let aggregate, let io {
            attempt("stop IO") { try backend.stopIO(aggregate: aggregate, handle: io) }
        }
        if let aggregate {
            attempt("destroy aggregate") { try backend.destroyAggregate(aggregate) }
        }
        if let tap {
            attempt("destroy tap") { try backend.destroyTap(tap.objectID) }
        }
        return failures
    }
}
