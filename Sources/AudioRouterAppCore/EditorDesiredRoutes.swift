// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore

/// The routes the app last asked the engine for.
///
/// `RouteEngine.setRoutes` returns at once and the snapshot follows only after the engine queue
/// published. A caller that builds the next list from the snapshot can send a list that misses the
/// change made a moment before. So both view models build from this list instead.
public protocol DesiredRoutesProviding: Sendable {
    /// The last list sent with `setRoutes`, or the snapshot routes when nothing was sent yet.
    var desiredRoutes: [Route] { get }
}

/// Wraps an engine and remembers the last list sent to `setRoutes`. The shell and the editor share one
/// instance, so a menu toggle applies to the latest list of either of them.
public final class DesiredRoutesEngine: ShellEngine, DesiredRoutesProviding, @unchecked Sendable {
    private let inner: any ShellEngine
    private let lock = NSLock()
    private var latest: [Route]?

    public init(_ inner: any ShellEngine) {
        self.inner = inner
    }

    public var desiredRoutes: [Route] {
        lock.withLock { latest } ?? inner.snapshot.routes.map(\.route)
    }

    public var snapshot: EngineSnapshot { inner.snapshot }

    public func observe(_ handler: @escaping @Sendable (EngineSnapshot) -> Void) -> any Cancellable {
        inner.observe(handler)
    }

    public func start() throws { try inner.start() }

    public func setRoutes(_ routes: [Route]) {
        // The record and the send stay under one lock, so two callers reach the engine in the order
        // they were recorded. `setRoutes` only enqueues, it does not block.
        lock.withLock {
            latest = routes
            inner.setRoutes(routes)
        }
    }

    public func setOn(_ on: Bool) { inner.setOn(on) }

    public func retryNow(_ id: UUID) { inner.retryNow(id) }

    public func meterReadings() -> [UUID: MeterReading] { inner.meterReadings() }

    @discardableResult
    public func stopAll() -> [UUID: [String]] { inner.stopAll() }
}

extension ShellEngine {
    /// The list the next change builds on: the desired routes when the engine tracks them, else the
    /// snapshot routes.
    var routesToBuildOn: [Route] {
        (self as? any DesiredRoutesProviding)?.desiredRoutes ?? snapshot.routes.map(\.route)
    }
}
