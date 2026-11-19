// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One running route: a muted tap over an app, an aggregate device on the target device and the
/// IO proc between them.
///
/// Creation order: tap, aggregate, IO proc. Teardown runs in the reverse order: IO proc,
/// aggregate, tap. The tap goes last because destroying it is what lets the app play normally
/// again, and nothing may still read from it by then.
///
/// A failed `start` rolls back what it created. `stop` can be called any number of times from any
/// thread, runs the teardown once and keeps going when a step fails.
public final class RouteSession: @unchecked Sendable {
    private let backend: any AudioRoutingBackend
    private let plan: RoutePlan
    private let lock = NSLock()  // guards the three handles below, never used on the audio thread
    private var tap: TapInfo?
    private var aggregate: ObjectID?
    private var io: IOHandle?
    private var stopped = false

    public init(backend: any AudioRoutingBackend, plan: RoutePlan) {
        self.backend = backend
        self.plan = plan
    }

    /// Creates the tap, the aggregate device and the IO proc. On failure everything created so far
    /// is destroyed again before the error is thrown.
    public func start() throws {
        do {
            let tap = try backend.createTap(
                processes: plan.processes.map(\.objectID),
                name: "audio-router \(plan.appBundleID)"
            )
            lock.withLock { self.tap = tap }
            let aggregate = try backend.createAggregate(deviceUID: plan.device.uid, tap: tap)
            lock.withLock { self.aggregate = aggregate }
            let io = try backend.startIO(aggregate: aggregate, channels: plan.channels)
            lock.withLock { self.io = io }
        } catch {
            let leftovers = stop()
            if !leftovers.isEmpty {
                throw RouterError.teardownFailed([String(describing: error)] + leftovers)
            }
            throw error
        }
    }

    /// Tears the route down. Returns the messages of the steps that failed, empty on success.
    /// Later calls do nothing and return an empty list.
    @discardableResult
    public func stop() -> [String] {
        let (tap, aggregate, io): (TapInfo?, ObjectID?, IOHandle?) = lock.withLock {
            guard !stopped else { return (nil, nil, nil) }
            stopped = true
            defer {
                self.tap = nil
                self.aggregate = nil
                self.io = nil
            }
            return (self.tap, self.aggregate, self.io)
        }
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
