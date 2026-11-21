// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import RouterCore

/// An engine clock that only moves when the test says so.
final class FakeEngineClock: EngineClock, @unchecked Sendable {
    private struct Job {
        let id: Int
        let due: TimeInterval
        let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var nextID = 0
    private var jobs: [Job] = []
    private var ignoring = false

    /// When true, `cancel` does nothing, like a timer that already started to run.
    func ignoreCancel(_ value: Bool) { lock.withLock { ignoring = value } }

    var pendingCount: Int { lock.withLock { jobs.count } }

    func now() -> TimeInterval { lock.withLock { current } }

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any Cancellable {
        lock.withLock {
            nextID += 1
            jobs.append(Job(id: nextID, due: current + seconds, work: work))
            return Cancel(clock: self, id: nextID)
        }
    }

    /// Moves time forward and runs every job that falls due, in order.
    func advance(by seconds: TimeInterval) {
        let target = lock.withLock { current + seconds }
        while true {
            let job: Job? = lock.withLock {
                guard let next = jobs.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) else {
                    current = target
                    return nil
                }
                jobs.removeAll { $0.id == next.id }
                current = next.due
                return next
            }
            guard let job else { return }
            job.work()
        }
    }

    private struct Cancel: Cancellable {
        let clock: FakeEngineClock
        let id: Int
        func cancel() {
            clock.lock.withLock {
                guard !clock.ignoring else { return }
                clock.jobs.removeAll { $0.id == id }
            }
        }
    }
}

/// The calls of every fake session, in order, across routes.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    var calls: [String] { lock.withLock { items } }

    func append(_ call: String) { lock.withLock { items.append(call) } }

    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
}

/// A session that records `start` and `stop` as "start <route name> <process ids>" and
/// "stop <route name>" and plays what its maker scripts.
final class FakeSession: EngineSession, @unchecked Sendable {
    private let name: String
    private let processes: String
    private let maker: FakeSessionMaker
    private let failure: Error?
    private let gate: Gate?

    init(name: String, processes: String, maker: FakeSessionMaker, failure: Error?, gate: Gate?) {
        self.name = name
        self.processes = processes
        self.maker = maker
        self.failure = failure
        self.gate = gate
    }

    func start() throws {
        maker.log.append("start \(name) \(processes)")
        if let gate {
            gate.entered.signal()
            gate.release.wait()
        }
        if let failure { throw failure }
    }

    func stop() -> [String] {
        maker.log.append("stop \(name)")
        return maker.leftovers(for: name)
    }

    func routeInfo() -> RouteInfo? { maker.script.info }

    func meterReading() -> MeterReading? { maker.script.meter }

    func signalState(elapsed: TimeInterval, silenceAfter: TimeInterval) -> SignalState {
        if maker.script.signal { return .present }
        return elapsed >= silenceAfter ? .silent : .waiting
    }

    func tapReport(for state: SignalState) -> (activity: String, warning: String?)? {
        ("activity line", maker.script.tapWarning)
    }

    func silentWaitOutput() -> TapCheck.SilentWaitOutput {
        TapCheck.SilentWaitOutput(activity: nil, warnings: maker.script.silentWarnings)
    }
}

/// Makes `FakeSession`s. Failures and gates are per route name and used once each, in order.
final class FakeSessionMaker: EngineSessionMaking, @unchecked Sendable {
    struct Script {
        var info: RouteInfo?
        var meter: MeterReading?
        var signal = false
        var tapWarning: String?
        var silentWarnings: [String] = []
    }

    let log = CallLog()
    private let lock = NSLock()
    private var failures: [String: [Error]] = [:]
    private var gates: [String: Gate] = [:]
    private var teardownLeftovers: [String: [String]] = [:]
    private var scripted = Script()
    private var made = 0

    var script: Script { lock.withLock { scripted } }

    var sessionsMade: Int { lock.withLock { made } }

    func update(_ change: (inout Script) -> Void) { lock.withLock { change(&scripted) } }

    /// The next starts of route `name` throw these errors, one per start.
    func fail(_ name: String, with errors: [Error]) { lock.withLock { failures[name, default: []] += errors } }

    /// The next start of route `name` blocks until the test releases the gate.
    func gate(_ name: String) -> Gate {
        let gate = Gate()
        lock.withLock { gates[name] = gate }
        return gate
    }

    /// What `stop` of route `name` reports as failed steps.
    func leaveBehind(_ name: String, _ steps: [String]) { lock.withLock { teardownLeftovers[name] = steps } }

    fileprivate func leftovers(for name: String) -> [String] { lock.withLock { teardownLeftovers[name] ?? [] } }

    func makeSession(for request: SessionRequest) throws -> any EngineSession {
        let name = request.route.name
        let (failure, gate): (Error?, Gate?) = lock.withLock {
            made += 1
            let failure = failures[name]?.isEmpty == false ? failures[name]?.removeFirst() : nil
            return (failure, gates.removeValue(forKey: name))
        }
        let ids = request.app.processes.map { String($0.objectID) }.joined(separator: ",")
        return FakeSession(name: name, processes: ids, maker: self, failure: failure, gate: gate)
    }
}

/// A process monitor that keeps every handler it was given, so a test can play an event through the
/// handler of a cancelled run. `initial` is delivered inside `start`, like the real monitor does.
final class ScriptedProcessMonitor: ProcessMonitoring, @unchecked Sendable {
    struct StartFailure: Error {}

    private let lock = NSLock()
    private var handlers: [@Sendable (ProcessEvent) -> Void] = []
    private var active: Int?
    private var failing = false
    private var initialEvents: [ProcessEvent]
    private(set) var cancels = 0

    init(initial: [ProcessEvent] = []) { initialEvents = initial }

    func failStart(_ value: Bool) { lock.withLock { failing = value } }

    var isActive: Bool { lock.withLock { active != nil } }

    func start(_ handler: @escaping @Sendable (ProcessEvent) -> Void) throws -> any Cancellable {
        let (index, initial): (Int, [ProcessEvent]) = try lock.withLock {
            if failing { throw StartFailure() }
            handlers.append(handler)
            active = handlers.count - 1
            return (handlers.count - 1, initialEvents)
        }
        for event in initial { handler(event) }
        return Stop(owner: self, index: index)
    }

    /// Delivers `events` in order to the active handler. Nothing arrives after cancel.
    func emit(_ events: ProcessEvent...) {
        for event in events {
            let handler = lock.withLock { active.map { handlers[$0] } }
            handler?(event)
        }
    }

    /// Plays `event` through the handler of the n-th `start`, cancelled or not.
    func emit(_ event: ProcessEvent, throughRun index: Int) {
        let handler = lock.withLock { handlers[index] }
        handler(event)
    }

    private struct Stop: Cancellable {
        let owner: ScriptedProcessMonitor
        let index: Int

        func cancel() {
            owner.lock.withLock {
                owner.cancels += 1
                if owner.active == index { owner.active = nil }
            }
        }
    }
}

/// Collects the states of one route from the published snapshots, without repeats in a row.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RouteState] = []
    private let id: UUID

    init(_ id: UUID) { self.id = id }

    var states: [RouteState] { lock.withLock { items } }

    func record(_ snapshot: EngineSnapshot) {
        guard let state = snapshot.status(of: id)?.state else { return }
        lock.withLock {
            if items.last != state { items.append(state) }
        }
    }
}

/// Placeholders only, no real device uid or serial.
enum EngineSamples {
    static let mixerUID = "mixer-uid"
    static let playerID = "com.example.player"
    static let otherID = "com.example.other"

    static func mixer(channels: [Int] = [32], rate: Double? = 48000, alive: Bool = true) -> DeviceInfo {
        DeviceInfo(
            uid: mixerUID, name: "Mixer", outputChannelsPerStream: channels, nominalSampleRate: rate,
            isAlive: alive, isDefaultOutput: false)
    }

    static func process(_ id: ObjectID, _ bundleID: String = playerID) -> AudioProcess {
        AudioProcess(objectID: id, pid: Int32(id) + 1000, bundleID: bundleID, isRunningOutput: true)
    }

    static let player = AppGroup(bundleID: playerID, processes: [process(101), process(102)])
    static let other = AppGroup(bundleID: otherID, processes: [process(201, otherID)])

    static func id(_ number: Int) -> UUID {
        // A fixed id per test route. The format is always valid.
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    static func route(
        _ name: String, number: Int, pair: Int = 3, app: String = playerID, device: String = mixerUID,
        enabled: Bool = true
    ) -> Route {
        Route(
            id: id(number), name: name, appBundleID: app, destinationUID: device,
            destinationPair: Samples.pair(pair), enabled: enabled)
    }

    static let a = route("a", number: 1, pair: 3)
    static let b = route("b", number: 2, pair: 5, app: otherID)

    static let matchingRates = RouteInfo(
        tap: StreamFormatInfo(sampleRate: 48000, channels: 2, interleaved: true),
        inputBuffers: [2], tapBuffers: 0..<1, outputBuffers: [32], inputStreams: [], outputStreams: [],
        aggregateSampleRate: 48000, deviceSampleRate: 48000)

    static let mismatchedRates = RouteInfo(
        tap: StreamFormatInfo(sampleRate: 48000, channels: 2, interleaved: true),
        inputBuffers: [2], tapBuffers: 0..<1, outputBuffers: [32], inputStreams: [], outputStreams: [],
        aggregateSampleRate: 44100, deviceSampleRate: 44100)
}

/// An engine on fakes: a real `DeviceModel` over a fake monitor with its own fake clock, a scripted
/// process monitor, fake sessions and a fake engine clock.
final class EngineRig: @unchecked Sendable {
    static let debounce: TimeInterval = 1.5

    let deviceMonitor: FakeDeviceMonitor
    let deviceClock = FakeDebounceClock()
    let model: DeviceModel
    let processes: ScriptedProcessMonitor
    let clock = FakeEngineClock()
    let maker = FakeSessionMaker()
    let engine: RouteEngine

    init(
        devices: [DeviceInfo] = [EngineSamples.mixer()], apps: [AppGroup] = [EngineSamples.player],
        configuration: EngineConfiguration = EngineConfiguration(),
        sessions: (any EngineSessionMaking)? = nil
    ) {
        deviceMonitor = FakeDeviceMonitor(devices)
        model = DeviceModel(monitor: deviceMonitor, clock: deviceClock, debounce: Self.debounce)
        processes = ScriptedProcessMonitor(initial: apps.map { .appStarted($0) })
        engine = RouteEngine(
            deviceModel: model, processMonitor: processes, sessions: sessions ?? maker, clock: clock,
            configuration: configuration)
    }

    var log: [String] { maker.log.calls }

    func state(_ route: Route) -> RouteState? { engine.snapshot.status(of: route.id)?.state }

    /// Sets the routes, starts the engine and waits until it is idle.
    func run(_ routes: [Route]) throws {
        engine.setRoutes(routes)
        try engine.start()
        engine.waitUntilIdle()
    }

    func setRoutes(_ routes: [Route]) {
        engine.setRoutes(routes)
        engine.waitUntilIdle()
    }

    /// Changes the device list and lets the quiet period of the device model pass.
    func devices(_ devices: [DeviceInfo]) {
        deviceMonitor.set(devices)
        deviceMonitor.emit(.deviceList)
        deviceClock.advance(by: Self.debounce)
        engine.waitUntilIdle()
    }

    func emit(_ events: ProcessEvent...) {
        for event in events { processes.emit(event) }
        engine.waitUntilIdle()
    }

    /// Moves the engine clock in steps of one second, so each poll can schedule the next.
    func advance(seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(by: 1)
            engine.waitUntilIdle()
        }
    }
}
