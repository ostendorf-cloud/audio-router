// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Runs work once after a delay. Injected so the debounce is testable without waiting.
public protocol DebounceClock: Sendable {
    /// Runs `work` after `seconds` on an arbitrary queue unless the result is cancelled first.
    /// `work` must not run inside this call.
    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any Cancellable
}

/// The real clock, on a private serial dispatch queue.
public struct DispatchDebounceClock: DebounceClock {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "audio-router.device-debounce")) {
        self.queue = queue
    }

    public func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any Cancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return WorkItemCancel(item: item)
    }
}

private struct WorkItemCancel: Cancellable, @unchecked Sendable {
    let item: DispatchWorkItem
    func cancel() { item.cancel() }
}

public enum DeviceModelError: Error, Equatable, Sendable {
    /// `start` ran on a model that is already running.
    case alreadyRunning
}

/// One live model of the output devices with debounced change events.
///
/// Raw signals from a `DeviceMonitoring` restart a quiet period. When it ends, the model reads a
/// new snapshot and reports the difference to the last reported one.
///
/// A loss does not wait (issue 49). A device list, alive or default output signal reads the devices
/// at once and reports only the losses in it: a device that is gone, a device that is no longer
/// alive, and the old default output that lost its role (`.defaultOutputChanged(from:to: nil)`).
/// Gains wait for the quiet period: an added device, a device alive again and the new default
/// output (`.defaultOutputChanged(from: nil, to:)`), as well as rate and channel changes.
/// A device that flaps within the period reports the loss at once and the return once after it.
///
/// A dead flag and a default that moved to another device are direct reads and go out at once.
/// A device missing from the read, or a read with no default output at all, goes out only when a
/// second read `defaultLossConfirmDelay` later shows it too: one read during device churn can drop
/// a device whose channel or uid read failed, or catch the default in the middle of a switch.
/// An alive flag that cannot be read keeps its last value.
///
/// One model has exactly one consumer: `start` throws `DeviceModelError.alreadyRunning` while it
/// runs. Several consumers, such as the engine and the UI, need a fan out layer above the model:
/// `RouteEngine` is the consumer and publishes the devices in its snapshot for the UI.
/// A model that is dropped without `cancel` removes its listener when it goes away. The handle
/// from `start` holds the model weakly, so `let h = try DeviceModel(...).start {}` without keeping
/// the model stops at once and without an error: keep a reference to the model.
public final class DeviceModel: @unchecked Sendable {
    /// The quiet period the app uses, within the 1 to 2 s of the concept.
    public static let defaultDebounce: TimeInterval = 1.5
    /// How long after a read that misses a device the second read runs. Short, so a removal still
    /// stops its route long before the quiet period would. Not measured on hardware.
    public static let defaultLossConfirmDelay: TimeInterval = 0.05

    private let monitor: any DeviceMonitoring
    private let clock: any DebounceClock
    private let debounce: TimeInterval
    private let lossConfirmDelay: TimeInterval
    /// The planned second read for a missing device, if any. Guarded by `lock`.
    private var confirmation: (any Cancellable)?
    private let lock = NSLock()
    private var known: [DeviceInfo] = []
    private var generation = 0
    private var running = false
    /// True once the baseline is read. Signals before that only set `dirty`.
    private var ready = false
    private var dirty = false
    private var timerCount = 0
    private var pendingToken: Int?
    private var observer: (any Cancellable)?
    private var pending: (any Cancellable)?
    private var handler: (@Sendable ([DeviceChange]) -> Void)?

    public init(
        monitor: any DeviceMonitoring, clock: any DebounceClock = DispatchDebounceClock(),
        debounce: TimeInterval = DeviceModel.defaultDebounce,
        lossConfirmDelay: TimeInterval = DeviceModel.defaultLossConfirmDelay
    ) {
        self.monitor = monitor
        self.clock = clock
        self.debounce = debounce
        self.lossConfirmDelay = lossConfirmDelay
    }

    deinit { stop(nil) }

    /// The devices as of the last report, or of `start`.
    public var devices: [DeviceInfo] { lock.withLock { known } }

    /// The device that is the default output, if any.
    public var defaultOutput: DeviceInfo? { devices.first { $0.isDefaultOutput } }

    /// Starts listening and reads the baseline. `onChange` gets each non empty batch on an arbitrary
    /// queue. The listeners come first and the baseline second. The model is already running while
    /// the baseline is read, so a change in between is not lost: it leads to one batch after the
    /// quiet period. Throws `DeviceModelError.alreadyRunning` while a start is active. Cancel the
    /// result to remove every listener and the pending timer. A batch already on its way when
    /// `cancel` runs can still arrive once.
    public func start(_ onChange: @escaping @Sendable ([DeviceChange]) -> Void) throws -> any Cancellable {
        let id: Int = try lock.withLock {
            guard !running else { throw DeviceModelError.alreadyRunning }
            generation += 1
            running = true
            ready = false
            dirty = false
            known = []
            handler = onChange
            return generation
        }
        let observer: any Cancellable
        do {
            observer = try monitor.observe { [weak self] kind in self?.signal(id, kind) }
        } catch {
            stop(id)
            throw error
        }
        lock.withLock { self.observer = observer }
        let baseline: [DeviceInfo]
        do {
            baseline = try monitor.snapshot()
        } catch {
            stop(id)
            throw error
        }
        lock.withLock {
            guard running, generation == id else { return }
            known = Self.mergingUnknowns(old: [], new: baseline)
            ready = true
            if dirty { scheduleLocked(id) }
        }
        return Stop(model: self, id: id)
    }

    private func signal(_ id: Int, _ kind: DeviceSignal) {
        let isReady: Bool = lock.withLock {
            guard running, generation == id else { return false }
            if ready {
                scheduleLocked(id)
            } else {
                dirty = true
            }
            return ready
        }
        // A sample rate signal cannot lose a device or the default role.
        guard isReady, kind != .sampleRate else { return }
        checkLoss(id, confirmed: false)
    }

    private typealias Batch = (changes: [DeviceChange], handler: (@Sendable ([DeviceChange]) -> Void)?)

    /// Reads the devices at once and reports the losses in it: gone, no longer alive, or no longer
    /// the default output. A loss must not wait for the quiet period: a route on that device still
    /// holds the tap, and the app stays muted until the route stops. Gains stay for the quiet period,
    /// so a flap stops a route at once and starts it once after.
    ///
    /// A dead flag and a default that moved to another device are direct reads and go out at once.
    /// A missing device, or no default output at all, goes out only when a second read
    /// `lossConfirmDelay` later shows it too. One read during device churn can drop a device whose
    /// channel or uid read failed, or catch the default in the middle of a switch.
    private func checkLoss(_ id: Int, confirmed: Bool) {
        // A failed read reports nothing. The quiet period that the signal started tries again.
        guard let fresh = try? monitor.snapshot() else { return }
        let batch: Batch? = lock.withLock {
            guard running, ready, generation == id else { return nil }
            let merged = Self.mergingUnknowns(old: known, new: fresh)
            let afterLosses = Self.applyingLossesOnly(old: known, new: merged)
            let changes = DeviceChange.diff(old: known, new: afterLosses)
            guard changes.contains(where: \.isLoss) else { return nil }
            let missing = changes.contains { if case .removed = $0 { true } else { false } }
            let noDefault = !merged.contains(where: \.isDefaultOutput)
            let defaultLost = changes.contains { if case .defaultOutputChanged = $0 { true } else { false } }
            if (missing || (defaultLost && noDefault)) && !confirmed {
                if confirmation == nil {
                    confirmation = clock.schedule(after: lossConfirmDelay) { [weak self] in self?.confirm(id) }
                }
                return nil
            }
            known = afterLosses
            // The quiet period may have ended while the devices were read, with a settle that saw
            // the older list. A new period makes sure a device that is back by now is reported.
            if pendingToken == nil { scheduleLocked(id) }
            return (changes, handler)
        }
        if let batch { batch.handler?(batch.changes) }
    }

    /// The second read for a missing device. A signal during the read may plan another one.
    private func confirm(_ id: Int) {
        let current: Bool = lock.withLock {
            guard running, ready, generation == id else { return false }
            confirmation = nil
            return true
        }
        guard current else { return }
        checkLoss(id, confirmed: true)
    }

    /// Restarts the quiet period. The caller holds the lock.
    private func scheduleLocked(_ id: Int) {
        pending?.cancel()
        timerCount += 1
        let token = timerCount
        pendingToken = token
        pending = clock.schedule(after: debounce) { [weak self] in self?.settle(id, token) }
    }

    private func settle(_ id: Int, _ token: Int) {
        guard lock.withLock({ running && ready && generation == id }) else { return }
        // A failed read keeps the last state. The next signal tries again.
        let fresh = try? monitor.snapshot()
        let batch: (changes: [DeviceChange], handler: (@Sendable ([DeviceChange]) -> Void)?)? = lock.withLock {
            guard running, generation == id else { return nil }
            // A newer signal may have started another timer while the snapshot was read. Keep it.
            if pendingToken == token {
                pending = nil
                pendingToken = nil
            }
            guard let fresh else { return nil }
            let merged = Self.mergingUnknowns(old: known, new: fresh)
            let changes = DeviceChange.diff(old: known, new: merged)
            known = merged
            return (changes, handler)
        }
        if let batch, !batch.changes.isEmpty { batch.handler?(batch.changes) }
    }

    /// `old` with only the losses of `new` applied: a device that is gone is dropped, a device that
    /// died is dead, the old default output loses its role. Nothing is added or gained.
    private static func applyingLossesOnly(old: [DeviceInfo], new: [DeviceInfo]) -> [DeviceInfo] {
        let byUID = Dictionary(new.map { ($0.uid, $0) }) { first, _ in first }
        return old.compactMap { before in
            guard let after = byUID[before.uid] else { return nil }
            let alive = before.isAlive && after.isAlive
            let isDefault = before.isDefaultOutput && after.isDefaultOutput
            guard alive != before.isAlive || isDefault != before.isDefaultOutput else { return before }
            return DeviceInfo(
                uid: before.uid, name: before.name, outputChannelsPerStream: before.outputChannelsPerStream,
                nominalSampleRate: before.nominalSampleRate, isAlive: alive, isDefaultOutput: isDefault)
        }
    }

    /// A rate or an alive flag that could not be read keeps its last known value. A new device
    /// whose alive flag could not be read counts as not alive until a read succeeds.
    private static func mergingUnknowns(old: [DeviceInfo], new: [DeviceInfo]) -> [DeviceInfo] {
        let byUID = Dictionary(old.map { ($0.uid, $0) }) { first, _ in first }
        return new.map { device in
            let before = byUID[device.uid]
            guard device.nominalSampleRate == nil || !device.isAliveKnown else { return device }
            return DeviceInfo(
                uid: device.uid, name: device.name, outputChannelsPerStream: device.outputChannelsPerStream,
                nominalSampleRate: device.nominalSampleRate ?? before?.nominalSampleRate,
                isAlive: device.isAliveKnown ? device.isAlive : (before?.isAlive ?? false),
                isDefaultOutput: device.isDefaultOutput)
        }
    }

    /// Stops the run `id`, or any run for nil. The removals happen outside the lock.
    fileprivate func stop(_ id: Int?) {
        let released: [(any Cancellable)?]? = lock.withLock {
            guard running, id == nil || generation == id else { return nil }
            running = false
            ready = false
            dirty = false
            let held = [observer, pending, confirmation]
            observer = nil
            pending = nil
            pendingToken = nil
            confirmation = nil
            handler = nil
            return held
        }
        for item in released ?? [] { item?.cancel() }
    }

    private final class Stop: Cancellable, @unchecked Sendable {
        weak var model: DeviceModel?
        let id: Int

        init(model: DeviceModel, id: Int) {
            self.model = model
            self.id = id
        }

        func cancel() { model?.stop(id) }
    }
}
