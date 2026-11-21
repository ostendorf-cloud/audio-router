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
/// new snapshot and reports the difference to the last reported one. A device that flaps within
/// the period, gone and back with the same state, reports nothing.
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

    private let monitor: any DeviceMonitoring
    private let clock: any DebounceClock
    private let debounce: TimeInterval
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
        debounce: TimeInterval = DeviceModel.defaultDebounce
    ) {
        self.monitor = monitor
        self.clock = clock
        self.debounce = debounce
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
            observer = try monitor.observe { [weak self] _ in self?.signal(id) }
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
            known = baseline
            ready = true
            if dirty { scheduleLocked(id) }
        }
        return Stop(model: self, id: id)
    }

    private func signal(_ id: Int) {
        lock.withLock {
            guard running, generation == id else { return }
            if ready {
                scheduleLocked(id)
            } else {
                dirty = true
            }
        }
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
            let merged = Self.keepingKnownRates(old: known, new: fresh)
            let changes = DeviceChange.diff(old: known, new: merged)
            known = merged
            return (changes, handler)
        }
        if let batch, !batch.changes.isEmpty { batch.handler?(batch.changes) }
    }

    /// A rate that could not be read keeps its last known value.
    private static func keepingKnownRates(old: [DeviceInfo], new: [DeviceInfo]) -> [DeviceInfo] {
        let rates = Dictionary(old.compactMap { d in d.nominalSampleRate.map { (d.uid, $0) } }) { first, _ in first }
        return new.map { device in
            guard device.nominalSampleRate == nil, let rate = rates[device.uid] else { return device }
            return DeviceInfo(
                uid: device.uid, name: device.name, outputChannelsPerStream: device.outputChannelsPerStream,
                nominalSampleRate: rate, isAlive: device.isAlive, isDefaultOutput: device.isDefaultOutput)
        }
    }

    /// Stops the run `id`, or any run for nil. The removals happen outside the lock.
    fileprivate func stop(_ id: Int?) {
        let released: (observer: (any Cancellable)?, pending: (any Cancellable)?)? = lock.withLock {
            guard running, id == nil || generation == id else { return nil }
            running = false
            ready = false
            dirty = false
            let held = (observer, pending)
            observer = nil
            pending = nil
            pendingToken = nil
            handler = nil
            return held
        }
        released?.observer?.cancel()
        released?.pending?.cancel()
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
