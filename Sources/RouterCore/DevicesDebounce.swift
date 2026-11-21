// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Runs work once after a delay. Injected so the debounce is testable without waiting.
public protocol DebounceClock: Sendable {
    /// Runs `work` after `seconds` on an arbitrary queue unless the result is cancelled first.
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

/// One live model of the output devices with debounced change events.
///
/// Raw signals from a `DeviceMonitoring` restart a quiet period. When it ends, the model reads a
/// new snapshot and reports the difference to the last reported one. A device that flaps within
/// the period, gone and back with the same state, reports nothing. The engine and the UI read
/// `devices` and react to the batches.
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

    /// The devices as of the last report, or of `start`.
    public var devices: [DeviceInfo] { lock.withLock { known } }

    /// The device that is the default output, if any.
    public var defaultOutput: DeviceInfo? { devices.first { $0.isDefaultOutput } }

    /// Starts listening and reads the baseline. `onChange` gets each non empty batch on an arbitrary
    /// queue. The listeners come first and the baseline second, so a change in between is not lost.
    /// A running model is stopped first. Cancel the result to remove every listener and pending
    /// timer. A batch already on its way when `cancel` runs can still arrive once.
    public func start(_ onChange: @escaping @Sendable ([DeviceChange]) -> Void) throws -> any Cancellable {
        stop()
        let id = lock.withLock {
            generation += 1
            return generation
        }
        let observer = try monitor.observe { [weak self] _ in self?.signal(id) }
        let baseline: [DeviceInfo]
        do {
            baseline = try monitor.snapshot()
        } catch {
            observer.cancel()
            throw error
        }
        lock.withLock {
            known = baseline
            handler = onChange
            self.observer = observer
            running = true
        }
        return Stop(model: self, id: id)
    }

    private func signal(_ id: Int) {
        lock.withLock {
            guard running, generation == id else { return }
            pending?.cancel()
            pending = clock.schedule(after: debounce) { [weak self] in self?.settle(id) }
        }
    }

    private func settle(_ id: Int) {
        guard lock.withLock({ running && generation == id }) else { return }
        // A failed read keeps the last state. The next signal tries again.
        guard let fresh = try? monitor.snapshot() else { return }
        let batch: (changes: [DeviceChange], handler: (@Sendable ([DeviceChange]) -> Void)?)? = lock.withLock {
            guard running, generation == id else { return nil }
            pending = nil
            let changes = DeviceChange.diff(old: known, new: fresh)
            known = fresh
            return (changes, handler)
        }
        if let batch, !batch.changes.isEmpty { batch.handler?(batch.changes) }
    }

    fileprivate func stop(_ id: Int? = nil) {
        let released: (any Cancellable, (any Cancellable)?)? = lock.withLock {
            guard running, id == nil || generation == id else { return nil }
            running = false
            let held = (observer!, pending)
            observer = nil
            pending = nil
            handler = nil
            return held
        }
        released?.0.cancel()
        released?.1?.cancel()
    }

    private struct Stop: Cancellable {
        let model: DeviceModel
        let id: Int
        func cancel() { model.stop(id) }
    }
}
