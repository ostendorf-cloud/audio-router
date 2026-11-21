// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the engine needs of one route session. `RouteSession` conforms unchanged, tests use a fake.
///
/// `stop` must tear down in the fixed order (IO proc, aggregate device, tap) and return only when
/// that is done. A failed `start` must roll back what it created.
public protocol EngineSession: AnyObject, Sendable {
    func start() throws
    @discardableResult func stop() -> [String]
    func routeInfo() -> RouteInfo?
    func meterReading() -> MeterReading?
    func signalState(elapsed: TimeInterval, silenceAfter: TimeInterval) -> SignalState
    func tapReport(for state: SignalState) -> (activity: String, warning: String?)?
    func silentWaitOutput() -> TapCheck.SilentWaitOutput
}

extension RouteSession: EngineSession {}

/// Everything the engine knows when a route starts.
public struct SessionRequest: Equatable, Sendable {
    public let route: Route
    /// The destination device from the device model.
    public let device: DeviceInfo
    /// The parent app with every process the tap must cover, helpers included.
    public let app: AppGroup

    public init(route: Route, device: DeviceInfo, app: AppGroup) {
        self.route = route
        self.device = device
        self.app = app
    }
}

/// Makes one session per start. A route gets a new session for each start and restart.
public protocol EngineSessionMaking: Sendable {
    /// Throws when the session cannot be built. The engine treats that like a failed start.
    func makeSession(for request: SessionRequest) throws -> any EngineSession
}

/// Builds `RouteSession`s on a routing backend.
///
/// The backend needs the Core Audio object id of the device, which `DeviceInfo` does not carry. It is
/// looked up by uid in `devices` at each start, so a device that came back with a new id still works.
public struct BackendSessionMaker: EngineSessionMaking {
    private let backend: any AudioRoutingBackend
    private let devices: any AudioDeviceProviding
    private let tapMode: TapMode

    public init(backend: any AudioRoutingBackend, devices: any AudioDeviceProviding, tapMode: TapMode = .standard) {
        self.backend = backend
        self.devices = devices
        self.tapMode = tapMode
    }

    public func makeSession(for request: SessionRequest) throws -> any EngineSession {
        let uid = request.route.destinationUID
        guard let device = try devices.outputDevices().first(where: { $0.uid == uid }) else {
            throw RouterError.unknownDevice(uid: uid)
        }
        let plan = RoutePlan(
            device: device, channels: request.route.destinationPair, appBundleID: request.app.bundleID,
            processes: request.app.processes, tapMode: tapMode, sourceChannels: request.route.sourcePair)
        return RouteSession(backend: backend, plan: plan, meter: true)
    }
}
