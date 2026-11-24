// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The state of one route in the engine.
public enum RouteState: Equatable, Sendable {
    /// The route is switched off, or the engine is globally off.
    case disabled
    /// The destination device is not in the device list or not alive.
    case waitingForDevice
    /// No process of the app is connected to Core Audio.
    case waitingForApp
    /// `RouteSession.start` runs.
    case starting
    /// The route copies audio. Warnings never stop it.
    case running(warnings: [RouteWarning])
    /// The route does not run. See `RouteFailure` for whether the engine retries.
    case failed(RouteFailure)
}

/// Something a running route reports without stopping.
public enum RouteWarning: Equatable, Sendable {
    /// No routed channel carried a sample for the whole wait. The texts come from
    /// `TapCheck.silentWait`: the tap check first, the permission hint only where it can be the cause.
    /// It goes away when a signal arrives.
    case noSignal([String])
    /// The tap check after the first signal found channels outside the source pair, or a silent tap
    /// next to an active device input. The text comes from `TapCheck.warning`.
    case tapCheck(String)
    /// The tap and the destination device run at different nominal rates after the start, also after
    /// the restart that a rate change of the destination causes. Rates in Hz.
    case sampleRateMismatch(tap: Double, device: Double)
}

/// Why a route is in `failed`.
public enum RouteFailure: Equatable, Sendable {
    /// The route does not fit the devices of the moment, see `RouteValidator`. Not retried. The engine
    /// checks again on every route change and every device change. An unknown device is not a
    /// failure: that route waits in `waitingForDevice`.
    case validation([RouteValidationError])
    /// A start failed with an error of the transient class. A retry is scheduled after `retryIn`
    /// seconds. `attempt` counts the failed starts since the last success, from 1.
    case startFailed(message: String, attempt: Int, retryIn: TimeInterval)
    /// A start failed with an error of the permanent class. No retry until `retryNow`, a changed
    /// route, global off and on, or a new run of the engine.
    case refused(message: String)
    /// A transient error came back `attempts` times in a row. No retry until `retryNow`, a changed
    /// route, global off and on, a new run, the destination device coming back after it was gone, or
    /// the app starting again after it quit. A denied capture permission that fails with an OSStatus
    /// ends here, see `StartErrorClass`.
    case retriesExhausted(message: String, attempts: Int)
}

/// How the engine treats an error thrown by a start.
///
/// The classes follow the errors that exist in the code (`RouterError`):
/// - permanent: the same devices and processes refuse in the same way again. `usage`,
///   `channelsOutOfRange`, `unsupportedFormat` (the exclusive tap included), `ambiguousTapStream`,
///   `unprovableTapOrder`, `refusedWithDiff`, and `teardownFailed`, because a start whose rollback
///   failed leaves Core Audio objects behind and a retry would pile up more.
/// - transient: everything else. `coreAudio` with any OSStatus, `unknownDevice` and
///   `noMatchingProcess` (the lists changed between the read and the start), `sessionAlreadyStopped`
///   and errors of other types.
///
/// Known limit: whether a denied capture permission fails with an OSStatus or delivers silence is
/// not measured (`docs/prototype-findings.md` section 1). As an OSStatus it falls in the transient
/// class and ends in `retriesExhausted` after `EngineConfiguration.maxAttempts`. As silence it shows
/// as the `noSignal` warning. Once the status is measured, `EngineConfiguration.classify` can map it
/// to `permanent`.
public enum StartErrorClass: Equatable, Sendable {
    case transient
    case permanent

    /// The default classification, see the type.
    public static func of(_ error: Error) -> StartErrorClass {
        guard let error = error as? RouterError else { return .transient }
        switch error {
        case .usage, .channelsOutOfRange, .unsupportedFormat, .ambiguousTapStream, .unprovableTapOrder,
            .refusedWithDiff, .teardownFailed:
            return .permanent
        case .unknownDevice, .noMatchingProcess, .coreAudio, .sessionAlreadyStopped:
            return .transient
        }
    }
}

/// One route as the UI sees it.
public struct RouteStatus: Equatable, Sendable {
    public let route: Route
    public let state: RouteState
    /// The steps that failed in the last teardown of this route, empty when it went clean. A failed
    /// step can leave a tap or an aggregate device behind until the process exits.
    public let teardownFailures: [String]

    public init(route: Route, state: RouteState, teardownFailures: [String]) {
        self.route = route
        self.state = state
        self.teardownFailures = teardownFailures
    }
}

/// Everything the UI shows, published by the engine. The UI never calls Core Audio.
public struct EngineSnapshot: Equatable, Sendable {
    /// Global on and off.
    public let isOn: Bool
    /// One entry per route id, in the order of `setRoutes`.
    public let routes: [RouteStatus]
    /// The devices as the engine's device model reported them last.
    public let devices: [DeviceInfo]
    /// The running apps as the engine's process monitor reported them, sorted by bundle id.
    public let apps: [AppGroup]

    public init(isOn: Bool, routes: [RouteStatus], devices: [DeviceInfo], apps: [AppGroup]) {
        self.isOn = isOn
        self.routes = routes
        self.devices = devices
        self.apps = apps
    }

    public static let empty = EngineSnapshot(isOn: true, routes: [], devices: [], apps: [])

    /// The status of the route `id`, nil when the engine does not know it.
    public func status(of id: UUID) -> RouteStatus? {
        routes.first { $0.route.id == id }
    }
}

/// The time source of the engine: backoff, silence wait and meter polling. Tests inject a clock
/// that only moves when told, so no test sleeps.
public protocol EngineClock: DebounceClock {
    /// Seconds on a monotonic time line. Only differences are used.
    func now() -> TimeInterval
}

/// The real clock, on a private serial dispatch queue. `now` is the uptime.
public struct DispatchEngineClock: EngineClock {
    private let debounce: DispatchDebounceClock

    public init(queue: DispatchQueue = DispatchQueue(label: "audio-router.engine-clock")) {
        debounce = DispatchDebounceClock(queue: queue)
    }

    public func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any Cancellable {
        debounce.schedule(after: seconds, work)
    }
}

/// Tuning of the engine. The defaults are what the app uses.
public struct EngineConfiguration: Sendable {
    /// The delay before the first retry of a failed start, in seconds. It doubles per failure.
    public var retryBase: TimeInterval
    /// The cap of the retry delay, in seconds.
    public var retryCap: TimeInterval
    /// Failed starts in a row after which a transient error stops retrying (`retriesExhausted`).
    public var maxAttempts: Int
    /// How often running routes are polled for meters, signal and the tap check, in seconds.
    public var pollInterval: TimeInterval
    /// Seconds without a routed sample after which a running route gets the `noSignal` warning.
    public var silenceAfter: TimeInterval
    /// Seconds after the first signal before the tap check runs, so the activity flags cover a while.
    public var tapCheckDelay: TimeInterval
    /// Sorts start errors into retry or stop.
    public var classify: @Sendable (Error) -> StartErrorClass

    public init(
        retryBase: TimeInterval = 1, retryCap: TimeInterval = 30, maxAttempts: Int = 8,
        pollInterval: TimeInterval = 1, silenceAfter: TimeInterval = 10, tapCheckDelay: TimeInterval = 2,
        classify: @escaping @Sendable (Error) -> StartErrorClass = StartErrorClass.of
    ) {
        self.retryBase = retryBase
        self.retryCap = retryCap
        self.maxAttempts = max(1, maxAttempts)
        self.pollInterval = pollInterval
        self.silenceAfter = silenceAfter
        self.tapCheckDelay = tapCheckDelay
        self.classify = classify
    }

    /// The delay before the retry after failure number `attempt` (from 1): base times 2 to the
    /// power of attempt minus 1, at most the cap.
    public func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(min(max(attempt - 1, 0), 30))
        return min(retryBase * pow(2, exponent), retryCap)
    }
}
