// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import RouterCore

/// Runs a blocking closure off the main thread. The engine calls wait on its queue, see `ShellEngine`.
public typealias ShellOffMain = @Sendable (@escaping @Sendable () -> Void) -> Void

/// Delivers a closure on the main actor, in order. The engine calls back on its own queue.
public typealias ShellMainHop = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

/// The state behind the menu bar item, the menu and the settings window.
@MainActor @Observable
public final class ShellViewModel {
    @ObservationIgnored private let engine: any ShellEngine
    @ObservationIgnored private let offMain: ShellOffMain
    @ObservationIgnored private var observation: (any Cancellable)?
    @ObservationIgnored private var shuttingDown = false

    /// The live meters. The views start and stop it, see `MeterPoller`.
    public let meters: MeterPoller
    /// Feeds the menu client of `meters` from the menu tracking notifications.
    public let menuTracker: MeterMenuTracker
    public private(set) var snapshot: EngineSnapshot
    /// Set when the engine could not start. Shown as the error state.
    public private(set) var startFailure: String?

    public static let backgroundOffMain: ShellOffMain = { work in
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
    public static let mainQueueHop: ShellMainHop = { work in
        DispatchQueue.main.async { work() }
    }

    public init(
        engine: any ShellEngine, offMain: @escaping ShellOffMain = ShellViewModel.backgroundOffMain,
        mainHop: @escaping ShellMainHop = ShellViewModel.mainQueueHop
    ) {
        self.engine = engine
        self.offMain = offMain
        let meters = MeterPoller(read: { engine.meterReadings() }, offMain: offMain, mainHop: mainHop)
        self.meters = meters
        menuTracker = MeterMenuTracker(poller: meters)
        snapshot = engine.snapshot
        // Handlers run on the engine queue. They only hop to the main actor and never call the engine.
        observation = engine.observe { [weak self] snapshot in
            mainHop { self?.snapshot = snapshot }
        }
    }

    deinit { observation?.cancel() }

    // MARK: - Derived state

    public var status: ShellStatus { ShellStatus.of(snapshot, startFailed: startFailure != nil) }
    public var isOn: Bool { snapshot.isOn }

    public var rows: [ShellRouteRow] {
        snapshot.routes.map {
            ShellRouteRow(
                id: $0.route.id, name: $0.route.name, isEnabled: $0.route.enabled, state: ShellRowState.of($0.state))
        }
    }

    // MARK: - Actions

    /// Sets the routes and starts the engine. A failed start becomes `startFailure`.
    public func start(routes: [Route]) async {
        engine.setRoutes(routes)
        let engine = engine
        let failure: String? = await blocking {
            do {
                try engine.start()
                return nil
            } catch {
                return String(describing: error)
            }
        }
        startFailure = failure
    }

    /// Global switch. Off returns after every route is down.
    public func setGlobalOn(_ on: Bool) async {
        guard !shuttingDown else { return }
        let engine = engine
        await blocking { engine.setOn(on) }
        // The observer delivers the same snapshot, possibly later. Reading it here keeps the switch
        // from showing the old state until then.
        snapshot = engine.snapshot
    }

    /// Switches one route on or off. The engine restarts or tears down that route.
    public func setRouteEnabled(_ id: UUID, _ enabled: Bool) {
        guard !shuttingDown else { return }
        // The latest list sent, not the snapshot: the snapshot lags a `setRoutes` still in the queue.
        let routes = engine.routesToBuildOn.map { route -> Route in
            var route = route
            if route.id == id { route.enabled = enabled }
            return route
        }
        engine.setRoutes(routes)
    }

    /// Clears a held failure of one route and tries again at once.
    public func retryNow(_ id: UUID) { engine.retryNow(id) }

    /// The quit path. Tears every route down off the main thread and calls `reply` on the main actor
    /// only after `stopAll` returned.
    ///
    /// The app delegate answers `applicationShouldTerminate` with `.terminateLater` and passes
    /// `reply(toApplicationShouldTerminate:)` here. `.terminateNow` would end the process while
    /// `stopAll` still runs, and a route that is not torn down leaves its tap and aggregate device
    /// behind. `stopAll` blocks on the engine queue, so it must not run on the main thread either.
    /// A second call while the first runs does nothing, because AppKit expects one reply.
    public func shutdown(reply: @escaping @MainActor () -> Void) {
        guard !shuttingDown else { return }
        shuttingDown = true
        meters.stopAll()
        let engine = engine
        Task { @MainActor in
            await blocking { engine.stopAll() }
            reply()
        }
    }

    @discardableResult
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let offMain = offMain
        return await withCheckedContinuation { continuation in
            offMain { continuation.resume(returning: work()) }
        }
    }
}
