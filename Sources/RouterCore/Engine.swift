// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RouteEngineError: Error, Equatable, Sendable {
    /// `start` ran on an engine that is already running.
    case alreadyRunning
}

/// Runs the stored routes and keeps them alive through device and app changes.
///
/// One serial owner: every piece of state lives on one private serial dispatch queue, never on the
/// audio thread. A queue and not an actor, because `RouteSession.start` and `stop` block on Core
/// Audio, possibly for seconds while a permission prompt is open, and a blocking call must not park
/// a thread of the Swift concurrency pool. The monitors call back on their own queues and the engine
/// hops onto its queue. `setOn(false)` and `stopAll` wait on the queue, so they return only when
/// every route is down.
///
/// The engine is the one consumer of its `DeviceModel` and of its `ProcessMonitoring`. The UI does
/// not start a second monitor: it reads `snapshot` or `observe`s it, and that snapshot carries the
/// devices and apps too.
///
/// Per route, in this order of precedence (see `RouteState`):
/// - engine stopped, global off or route switched off: `disabled`;
/// - the route does not validate against the devices (`RouteValidator`): `failed(.validation)`;
///   an unknown device is not a failure, the route waits in `waitingForDevice`;
/// - the destination device missing, not alive, or left by the default output: `waitingForDevice`;
/// - no process of the app: `waitingForApp`;
/// - a permanent failure or exhausted retries: `failed`, see below;
/// - otherwise the route starts (`starting`) and runs (`running`), or fails and retries with
///   exponential backoff up to a cap (`failed(.startFailed)`). Other events during the backoff do not
///   cut it short.
///
/// Held failures: `refused` (permanent class) stays until `retryNow`, a change of that route in
/// `setRoutes`, global off and on, or a new run (`stopAll`, then `start`). `retriesExhausted` and the
/// attempt count clear on the same actions, and also when the destination device comes back after it
/// was gone and when the app starts again after it quit.
///
/// Validation decisions: a route whose id appears more than once is held in `failed(.validation)`
/// as a whole and none of its entries runs. Of two enabled routes that share a channel of a device,
/// the earlier one in the list runs and the later one fails validation.
///
/// Restarts: a running route restarts on `helperStarted` of its app, because a helper that started
/// after the tap was built is not tapped otherwise (see `ProcessMonitoring`). It also restarts on any
/// change the device model reports for its destination: removed and added again, alive, sample rate
/// or channels. A burst of such events that the queue holds at once leads to one restart.
/// `helperStopped` does not restart the route: the tap keeps the process object of the gone helper,
/// whether that matters is not measured.
///
/// Device loss and recovery (issues 42 and 49): the destination counts as lost when it is gone, no
/// longer alive, or when the default output moved away from it (the concept's rule). The
/// `DeviceModel` reports a dead device and a default that moved to another device at once, a
/// missing device or a read without any default after a short confirm read. The route stops in
/// the fixed order and releases the tap. The tap mutes the app only while it is read, so the app
/// plays on the current default output while the route waits in `waitingForDevice`.
/// The return waits for the quiet period of the model: a device that is back, or the default back
/// on the destination. A device that is gone and back within it stops its routes at once and
/// starts them once after the period. The engine adds no second debounce. A default change that
/// does not leave the destination, for example to the destination itself, leaves the route alone.
/// A route whose destination is not the default when the engine starts runs: only the default
/// moving away counts, and a new run forgets it.
///
/// Known limits:
/// - Several routes at once on one device (two aggregates on one device) are not measured. The
///   engine does not claim that it works. The hardware checklist (issue 15) covers it.
/// - The single serial queue blocks every other route while one start blocks, for example while a
///   permission prompt is open.
/// - `setOn(false)` and `stopAll` block the caller's thread until every route is down. The app must
///   call `stopAll` off the main thread on quit: answer `applicationShouldTerminate` with
///   `terminateLater` and reply when `stopAll` returned.
/// - `observe` handlers run on the engine queue and must not call `start`, `setOn` or `stopAll`.
/// - A destination that comes back while the default stays elsewhere keeps the route waiting
///   until the default returns to it.
/// - The session reports no runtime error of the IO proc, so `running` only leaves through events.
/// - A flapping device with a failing start retries without end and never reaches
///   `retriesExhausted`, because every replug clears the attempt count. The pace is bounded by the
///   quiet period of the `DeviceModel` plus the first backoff delay. A possible follow up: clear the
///   count only after the device stayed present for a while.
public final class RouteEngine: @unchecked Sendable {
    /// The serial owner. Internal so tests can hold it to deliver a burst of events at once.
    let queue = DispatchQueue(label: "audio-router.engine")

    private let deviceModel: DeviceModel
    private let processMonitor: any ProcessMonitoring
    private let sessions: any EngineSessionMaking
    private let clock: any EngineClock
    private let config: EngineConfiguration

    // Everything below until the lock is owned by `queue`.
    /// The generation of the monitor run. A callback of an older run is ignored.
    private var run = 0
    private var running = false
    private var deviceHandle: (any Cancellable)?
    private var processHandle: (any Cancellable)?
    private var isOn = true
    private var routes: [Route] = []
    private var order: [UUID] = []
    private var records: [UUID: Record] = [:]
    private var devices: [DeviceInfo] = []
    private var apps: [String: AppGroup] = [:]
    private var reconcilePending = false
    private var pollTimer: (any Cancellable)?
    private var pollGeneration = 0

    private let lock = NSLock()
    private var latest = EngineSnapshot.empty
    private var observers: [Int: @Sendable (EngineSnapshot) -> Void] = [:]
    private var nextObserver = 0

    public init(
        deviceModel: DeviceModel, processMonitor: any ProcessMonitoring, sessions: any EngineSessionMaking,
        clock: any EngineClock = DispatchEngineClock(), configuration: EngineConfiguration = EngineConfiguration()
    ) {
        self.deviceModel = deviceModel
        self.processMonitor = processMonitor
        self.sessions = sessions
        self.clock = clock
        self.config = configuration
    }

    /// Without `stopAll` the listeners, timers and sessions go here, in the fixed teardown order.
    /// Nothing else holds the engine by then, so the state is touched directly.
    deinit {
        deviceHandle?.cancel()
        processHandle?.cancel()
        pollTimer?.cancel()
        for record in records.values {
            record.retry?.cancel()
            record.session?.stop()
        }
    }

    // MARK: - Public API

    /// The last published snapshot. Any thread.
    public var snapshot: EngineSnapshot { lock.withLock { latest } }

    /// Calls `handler` with the current snapshot and then with every changed one, on the engine
    /// queue. The handler must return fast and must not call `start`, `setOn` or `stopAll`, which
    /// wait on that queue. Cancel the result to stop the calls.
    public func observe(_ handler: @escaping @Sendable (EngineSnapshot) -> Void) -> any Cancellable {
        let id: Int = lock.withLock {
            nextObserver += 1
            observers[nextObserver] = handler
            return nextObserver
        }
        queue.async { [weak self] in
            guard let self, let current = self.lock.withLock({ self.observers[id] != nil ? self.latest : nil })
            else { return }
            handler(current)
        }
        return ObserverHandle(engine: self, id: id)
    }

    /// Installs the device and process listeners and starts the routes that can run. Throws
    /// `RouteEngineError.alreadyRunning` while running, or the error of a monitor. A start that
    /// throws leaves no listener installed.
    public func start() throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard !running else { throw RouteEngineError.alreadyRunning }
            run += 1
            let id = run
            let model = deviceModel
            let devicesHandle = try model.start(deviceBatchHandler(run: id))
            let processHandle: any Cancellable
            do {
                processHandle = try processMonitor.start { [weak self] event in
                    self?.queue.async { [weak self] in self?.processEvent(run: id, event) }
                }
            } catch {
                devicesHandle.cancel()
                run += 1
                throw error
            }
            deviceHandle = devicesHandle
            self.processHandle = processHandle
            running = true
            devices = model.devices
            apps = [:]
            // A new run is a fresh chance: every held failure, `refused` included, is cleared.
            // The devices are read fresh, so a default that moved away in the last run is forgotten.
            for record in records.values {
                record.clearFailures()
                record.awayFromDefault = false
            }
            validate()
            scheduleReconcile()
            publish()
        }
    }

    /// Replaces the desired routes, for example with `RouteStore.load()`. Returns at once. A route
    /// that changed in more than its name restarts and loses a held failure. A removed route is
    /// torn down.
    public func setRoutes(_ newRoutes: [Route]) {
        queue.async { [weak self] in self?.applyRoutes(newRoutes) }
    }

    /// Global on and off. Off tears every route down in the fixed order and returns only when that is
    /// done. On returns at once and starts the routes on the queue. On clears every held failure.
    public func setOn(_ on: Bool) {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard isOn != on else { return }
            isOn = on
            if on {
                for record in records.values { record.clearFailures() }
                scheduleReconcile()
            } else {
                reconcileAll()
            }
            publish()
        }
    }

    /// Clears a held failure of the route `id` and tries again at once.
    public func retryNow(_ id: UUID) {
        queue.async { [weak self] in
            guard let self, let record = self.records[id] else { return }
            record.clearFailures()
            record.cancelRetry()
            self.scheduleReconcile()
        }
    }

    /// Removes the listeners, stops every timer and tears every route down in the fixed order (IO
    /// proc, aggregate device, tap). Returns only when every route is down, also when a start was
    /// running: it waits for that start and then tears it down. Every route is `disabled` after it.
    /// `start` runs the engine again. Returns the failed teardown steps per route.
    @discardableResult
    public func stopAll() -> [UUID: [String]] {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            run += 1
            running = false
            let handles = (deviceHandle, processHandle)
            deviceHandle = nil
            processHandle = nil
            handles.0?.cancel()
            handles.1?.cancel()
            stopPolling()
            apps = [:]
            var leftovers: [UUID: [String]] = [:]
            for id in order {
                guard let record = records[id] else { continue }
                record.cancelRetry()
                if teardown(record), !record.teardownFailures.isEmpty {
                    leftovers[id] = record.teardownFailures
                }
                record.state = .disabled
            }
            publish()
            return leftovers
        }
    }

    /// The levels of the last full interval of every running route, keyed by route id. A route that does
    /// not run, or whose meter is still priming, has no entry.
    ///
    /// Reader driven: each call reads and clears the meter memory of every running session, and a reading
    /// covers the interval before the last read, see `MeterBlock`. So the caller may poll at any rate.
    /// The engine itself never reads the meter, so nothing is measured while nobody asks. Only one caller
    /// may poll, a second one would take intervals away from the first. The call blocks until the engine
    /// queue answers, so call it off the main thread.
    public func meterReadings() -> [UUID: MeterReading] {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            var readings: [UUID: MeterReading] = [:]
            for id in order {
                guard let record = records[id], let session = record.session, case .running = record.state,
                    let reading = session.meterReading()
                else { continue }
                readings[id] = reading
            }
            return readings
        }
    }

    /// Returns when the queue has no work left. For tests.
    func waitUntilIdle() {
        while queue.sync(execute: { reconcilePending }) {}
    }

    /// The generation of the current monitor run. For tests.
    var currentRun: Int { queue.sync { run } }

    /// What the device model of run `id` calls with each batch. It runs on the model's queue and hops
    /// onto the engine queue, where `devicesChanged` drops a batch of an older run. Internal so a test
    /// can play a batch that was still in flight across `stopAll` and `start`.
    func deviceBatchHandler(run id: Int) -> @Sendable ([DeviceChange]) -> Void {
        let model = deviceModel
        return { [weak self, weak model] changes in
            let devices = model?.devices ?? []
            self?.queue.async { [weak self] in self?.devicesChanged(run: id, changes: changes, devices: devices) }
        }
    }

    // MARK: - Inputs on the queue

    private func applyRoutes(_ newRoutes: [Route]) {
        routes = newRoutes
        var newOrder: [UUID] = []
        var firstByID: [UUID: Route] = [:]
        for route in newRoutes where firstByID[route.id] == nil {
            firstByID[route.id] = route
            newOrder.append(route.id)
        }
        for id in order where firstByID[id] == nil {
            if let record = records.removeValue(forKey: id) {
                record.cancelRetry()
                teardown(record)
            }
        }
        for id in newOrder {
            guard let route = firstByID[id] else { continue }
            if let record = records[id] {
                if !Self.sameExceptName(record.route, route) {
                    record.clearFailures()
                    record.cancelRetry()
                    if record.session != nil { record.needsRestart = true }
                }
                if record.route.destinationUID != route.destinationUID { record.awayFromDefault = false }
                record.route = route
            } else {
                records[id] = Record(route: route)
            }
        }
        order = newOrder
        validate()
        scheduleReconcile()
        publish()
    }

    private func devicesChanged(run id: Int, changes: [DeviceChange], devices newDevices: [DeviceInfo]) {
        guard running, run == id else { return }
        devices = newDevices
        // A session on a device that went away is dead even when the device is back by the time the
        // coalesced reconcile runs, so every change of the destination restarts a running route.
        // A device that comes back (added, or alive again) gives its routes a fresh chance: the attempt
        // count and an exhausted retry are cleared. A `refused` hold stays.
        for change in changes {
            switch change {
            case .added(let info):
                markRestart { $0.destinationUID == info.uid }
                clearTransientFailures { $0.destinationUID == info.uid }
            case .removed(let info):
                markRestart { $0.destinationUID == info.uid }
            case .aliveChanged(let uid, let isAlive):
                markRestart { $0.destinationUID == uid }
                if isAlive { clearTransientFailures { $0.destinationUID == uid } }
            case .sampleRateChanged(let uid, _, _), .channelsChanged(let uid, _, _):
                markRestart { $0.destinationUID == uid }
            case .defaultOutputChanged(let from, let to):
                // Concept and issue 42: the default output moving away from the target counts as
                // device lost. The app follows the default, so the tap on the target would stay
                // silent. The default returning to the target is a fresh chance, like a replug.
                if let from, from != to {
                    for record in records.values where record.route.destinationUID == from {
                        record.awayFromDefault = true
                    }
                }
                if let to {
                    for record in records.values where record.route.destinationUID == to {
                        record.awayFromDefault = false
                    }
                    clearTransientFailures { $0.destinationUID == to }
                }
            }
        }
        validate()
        scheduleReconcile()
        publish()
    }

    private func processEvent(run id: Int, _ event: ProcessEvent) {
        guard running, run == id else { return }
        switch event {
        case .appStarted(let group):
            apps[group.bundleID] = group
            // The app started again: a fresh chance, like a device that is back. `refused` stays.
            clearTransientFailures { $0.appBundleID == group.bundleID }
        case .helperStarted(let bundleID, let process):
            let known = apps[bundleID]?.processes ?? []
            apps[bundleID] = AppGroup(bundleID: bundleID, processes: known + [process])
            markRestart { $0.appBundleID == bundleID }
        case .helperStopped(let bundleID, let process):
            if let group = apps[bundleID] {
                apps[bundleID] = AppGroup(
                    bundleID: bundleID, processes: group.processes.filter { $0.objectID != process.objectID })
            }
        case .appQuit(let bundleID):
            apps[bundleID] = nil
        }
        scheduleReconcile()
        publish()
    }

    // MARK: - Reconcile

    private func clearTransientFailures(where matches: (Route) -> Bool) {
        for record in records.values where matches(record.route) {
            record.clearTransientFailures()
        }
    }

    private func markRestart(where matches: (Route) -> Bool) {
        for record in records.values where record.session != nil && matches(record.route) {
            record.needsRestart = true
        }
    }

    /// Checks all routes against the alive devices. An unknown device is left to `reconcile`.
    private func validate() {
        let present = devices.filter(\.isAlive).map {
            OutputDevice(objectID: 0, uid: $0.uid, name: $0.name, channelCount: $0.outputChannelCount)
        }
        let errors = RouteValidator.validate(routes, devices: present, processes: [])
        for record in records.values {
            record.validation = errors.filter { error in
                guard error.routeID == record.route.id else { return false }
                if case .unknownDevice = error { return false }
                return true
            }
        }
    }

    /// Coalesces: every input marks what changed, one pass decides.
    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        queue.async { [weak self] in
            guard let self else { return }
            self.reconcilePending = false
            self.reconcileAll()
            self.publish()
        }
    }

    private func reconcileAll() {
        for id in order {
            if let record = records[id] { reconcile(record) }
        }
    }

    private func reconcile(_ record: Record) {
        let route = record.route
        guard running, isOn, route.enabled else { return settle(record, .disabled) }
        guard record.validation.isEmpty else { return settle(record, .failed(.validation(record.validation))) }
        guard let device = devices.first(where: { $0.uid == route.destinationUID && $0.isAlive }),
            !record.awayFromDefault
        else {
            return settle(record, .waitingForDevice)
        }
        guard let app = apps[route.appBundleID], !app.processes.isEmpty else {
            return settle(record, .waitingForApp)
        }
        if let held = record.held { return settle(record, .failed(held)) }
        if record.session != nil && !record.needsRestart { return }
        if record.retry != nil { return }  // the backoff timer decides
        start(record, request: SessionRequest(route: route, device: device, app: app))
    }

    /// Puts a route into a state where it does not run.
    private func settle(_ record: Record, _ state: RouteState) {
        record.cancelRetry()
        teardown(record)
        record.state = state
    }

    private func start(_ record: Record, request: SessionRequest) {
        teardown(record)
        record.state = .starting
        publish()
        let session: any EngineSession
        do {
            session = try sessions.makeSession(for: request)
            try session.start()
        } catch {
            fail(record, error)
            return
        }
        record.session = session
        record.attempts = 0
        record.startedAt = clock.now()
        record.rateWarnings = Self.rateWarnings(session.routeInfo())
        record.state = .running(warnings: record.warnings)
        startPolling()
    }

    private func fail(_ record: Record, _ error: Error) {
        let message = "\(error)"
        record.attempts += 1
        switch config.classify(error) {
        case .permanent:
            record.held = .refused(message: message)
        case .transient where record.attempts >= config.maxAttempts:
            record.held = .retriesExhausted(message: message, attempts: record.attempts)
        case .transient:
            let delay = config.retryDelay(afterAttempt: record.attempts)
            let (id, epoch, runID) = (record.route.id, record.epoch, run)
            record.retry = clock.schedule(after: delay) { [weak self] in
                self?.queue.async { [weak self] in self?.retryFired(id: id, epoch: epoch, run: runID) }
            }
            record.state = .failed(.startFailed(message: message, attempt: record.attempts, retryIn: delay))
            return
        }
        record.state = .failed(record.held ?? .refused(message: message))
    }

    /// A late timer of a route that left the backoff since, or of an older run, does nothing.
    private func retryFired(id: UUID, epoch: Int, run runID: Int) {
        guard running, run == runID, let record = records[id], record.epoch == epoch, record.retry != nil else {
            return
        }
        record.retry = nil
        reconcile(record)
        publish()
    }

    /// Stops the session in the fixed order, if there is one. True when there was one.
    @discardableResult
    private func teardown(_ record: Record) -> Bool {
        record.epoch += 1
        record.needsRestart = false
        record.resetRunState()
        guard let session = record.session else { return false }
        record.session = nil
        record.teardownFailures = session.stop()
        return true
    }

    // MARK: - Polling of running routes

    private func startPolling() {
        guard pollTimer == nil else { return }
        let generation = pollGeneration
        pollTimer = clock.schedule(after: config.pollInterval) { [weak self] in
            self?.queue.async { [weak self] in self?.poll(generation) }
        }
    }

    private func stopPolling() {
        pollGeneration += 1
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func poll(_ generation: Int) {
        guard generation == pollGeneration else { return }
        pollGeneration += 1
        pollTimer = nil
        var any = false
        for id in order {
            guard let record = records[id], let session = record.session, case .running = record.state else {
                continue
            }
            any = true
            update(record, session)
        }
        publish()
        if any { startPolling() }
    }

    /// Silence and the tap check. They only ever change warnings, never the state. The meter is not read
    /// here, see `meterReadings`.
    private func update(_ record: Record, _ session: any EngineSession) {
        let now = clock.now()
        switch session.signalState(elapsed: now - record.startedAt, silenceAfter: config.silenceAfter) {
        case .waiting:
            break
        case .silent:
            if record.silence == nil { record.silence = session.silentWaitOutput().warnings }
        case .present:
            record.silence = nil
            let since = record.presentSince ?? now
            record.presentSince = since
            if !record.tapChecked, now - since >= config.tapCheckDelay {
                record.tapChecked = true
                record.tapWarning = session.tapReport(for: .present)?.warning
            }
        }
        record.state = .running(warnings: record.warnings)
    }

    private static func rateWarnings(_ info: RouteInfo?) -> [RouteWarning] {
        guard let info, let device = info.deviceSampleRate, device > 0, info.tap.sampleRate > 0,
            info.tap.sampleRate != device
        else { return [] }
        return [.sampleRateMismatch(tap: info.tap.sampleRate, device: device)]
    }

    private static func sameExceptName(_ lhs: Route, _ rhs: Route) -> Bool {
        var renamed = rhs
        renamed.name = lhs.name
        return lhs == renamed
    }

    // MARK: - Publishing

    private func publish() {
        let statuses = order.compactMap { id in
            records[id].map {
                RouteStatus(route: $0.route, state: $0.state, teardownFailures: $0.teardownFailures)
            }
        }
        let next = EngineSnapshot(
            isOn: isOn, routes: statuses, devices: devices,
            apps: apps.values.sorted { $0.bundleID < $1.bundleID })
        let handlers: [@Sendable (EngineSnapshot) -> Void]? = lock.withLock {
            guard next != latest else { return nil }
            latest = next
            return observers.keys.sorted().compactMap { observers[$0] }
        }
        for handler in handlers ?? [] { handler(next) }
    }

    /// The handler is released after the lock. It may own another handle of this engine, whose
    /// `deinit` removes that observer and takes the lock again: inside the lock that deadlocks.
    fileprivate func removeObserver(_ id: Int) {
        let removed = lock.withLock { observers.removeValue(forKey: id) }
        withExtendedLifetime(removed) {}
    }

    private final class ObserverHandle: Cancellable, @unchecked Sendable {
        weak var engine: RouteEngine?
        let id: Int

        init(engine: RouteEngine, id: Int) {
            self.engine = engine
            self.id = id
        }

        /// A dropped handle stops the calls like `cancel`.
        deinit { cancel() }

        func cancel() { engine?.removeObserver(id) }
    }

    /// The engine's view of one route id. Only touched on the queue.
    private final class Record {
        var route: Route
        var state: RouteState = .disabled
        var session: (any EngineSession)?
        /// Changes with every teardown and every new backoff. A timer of an older epoch does nothing.
        var epoch = 0
        var retry: (any Cancellable)?
        var attempts = 0
        /// A failure that stops the retries until the user acts.
        var held: RouteFailure?
        var needsRestart = false
        /// The default output moved away from the destination and has not come back. The route
        /// waits in `waitingForDevice` like for a lost device. Cleared by the default returning to
        /// the destination, a new destination, or a new run.
        var awayFromDefault = false
        var validation: [RouteValidationError] = []
        var teardownFailures: [String] = []
        // The run state of the current session.
        var startedAt: TimeInterval = 0
        var presentSince: TimeInterval?
        var tapChecked = false
        var rateWarnings: [RouteWarning] = []
        var silence: [String]?
        var tapWarning: String?

        init(route: Route) { self.route = route }

        var warnings: [RouteWarning] {
            rateWarnings + (silence.map { [.noSignal($0)] } ?? []) + (tapWarning.map { [.tapCheck($0)] } ?? [])
        }

        /// The user acted: `retryNow`, a changed route, global on, or a new run.
        func clearFailures() {
            attempts = 0
            held = nil
        }

        /// The device or the app came back. A `refused` hold stays, it needs the user.
        func clearTransientFailures() {
            attempts = 0
            if case .retriesExhausted = held { held = nil }
        }

        func cancelRetry() {
            epoch += 1
            retry?.cancel()
            retry = nil
        }

        func resetRunState() {
            startedAt = 0
            presentSince = nil
            tapChecked = false
            rateWarnings = []
            silence = nil
            tapWarning = nil
        }
    }
}
