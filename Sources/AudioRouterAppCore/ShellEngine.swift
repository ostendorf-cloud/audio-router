// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore

/// The part of `RouteEngine` the app shell uses. The seam for the view model tests: they drive a fake.
///
/// `setOn(false)`, `start` and `stopAll` block the caller until the engine queue answers, so the
/// view model calls them off the main thread. `observe` handlers run on the engine queue.
public protocol ShellEngine: Sendable {
    var snapshot: EngineSnapshot { get }
    func observe(_ handler: @escaping @Sendable (EngineSnapshot) -> Void) -> any Cancellable
    func start() throws
    func setRoutes(_ routes: [Route])
    func setOn(_ on: Bool)
    @discardableResult func stopAll() -> [UUID: [String]]
    /// The levels of the last interval of every running route. Blocks like `setOn`, so call it off the main
    /// thread. Reader driven, see `RouteEngine.meterReadings`. Used by `MeterPoller` only.
    func meterReadings() -> [UUID: MeterReading]
}

extension ShellEngine {
    /// A seam without meters reports none.
    public func meterReadings() -> [UUID: MeterReading] { [:] }
}

extension RouteEngine: ShellEngine {}
