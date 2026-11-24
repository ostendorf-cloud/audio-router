// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import RouterCore

/// Calls a closure again and again. Injected, so tests move time by hand.
public protocol MeterClock: Sendable {
    /// Calls `tick` every `interval` seconds, on the main queue, until the result is cancelled.
    /// `tick` must not run inside this call.
    func every(_ interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) -> any Cancellable
}

/// The real clock: a timer on the main queue.
public struct DispatchMeterClock: MeterClock {
    public init() {}

    public func every(_ interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) -> any Cancellable {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: tick)
        timer.resume()
        return TimerCancel(timer: timer)
    }

    private struct TimerCancel: Cancellable, @unchecked Sendable {
        let timer: any DispatchSourceTimer
        func cancel() { timer.cancel() }
    }
}

/// A part of the UI that shows meters. Each one tells the poller when it is visible.
public enum MeterClient: Hashable, Sendable {
    case menu
    case settings
}

/// Polls the engine for meter readings while a client is visible.
///
/// Polling runs from the first `start` to the last `stop`. Two clients, the menu and the settings
/// window, count as a set: polling stops only when both are gone. A client is in the set or not, so a
/// second `start` of the same client, or a `stop` without a `start`, changes nothing. A menu that
/// reports its appearance twice cannot leave the poller running.
///
/// While nothing is visible no timer runs and the engine meter is not read. The engine keeps the
/// meter memory in the IO proc either way, which costs the audio thread nothing extra.
///
/// Each tick reads the engine off the main thread, because the read waits on the engine queue, and
/// delivers the result on the main actor. A tick while a read is still running is skipped. An answer
/// that arrives after the last `stop` is dropped.
///
/// A reading covers the interval before the last read (`MeterBlock`), so the rate only sets how often
/// the display moves. The default is about 15 Hz.
@MainActor @Observable
public final class MeterPoller {
    public static let defaultInterval: TimeInterval = 1.0 / 15

    @ObservationIgnored private let read: @Sendable () -> [UUID: MeterReading]
    @ObservationIgnored private let clock: any MeterClock
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private let offMain: ShellOffMain
    @ObservationIgnored private let mainHop: ShellMainHop
    @ObservationIgnored private var timer: (any Cancellable)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var visible: Set<MeterClient> = []

    /// The last levels per route id. A route that does not run or is still priming has no entry.
    /// Empty while nothing is polled.
    public private(set) var levels: [UUID: MeterLevel] = [:]

    public init(
        read: @escaping @Sendable () -> [UUID: MeterReading],
        interval: TimeInterval = MeterPoller.defaultInterval,
        clock: any MeterClock = DispatchMeterClock(),
        offMain: @escaping ShellOffMain = ShellViewModel.backgroundOffMain,
        mainHop: @escaping ShellMainHop = ShellViewModel.mainQueueHop
    ) {
        self.read = read
        self.interval = interval
        self.clock = clock
        self.offMain = offMain
        self.mainHop = mainHop
    }

    /// True while the timer runs.
    public var isPolling: Bool { timer != nil }

    /// The client became visible. The first one starts the timer.
    public func start(_ client: MeterClient) {
        visible.insert(client)
        guard timer == nil else { return }
        timer = clock.every(interval) { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The client is gone. The last one stops the timer and clears the levels.
    public func stop(_ client: MeterClient) {
        visible.remove(client)
        if visible.isEmpty { halt() }
    }

    /// Forgets every client and stops. For the quit path.
    public func stopAll() {
        visible.removeAll()
        halt()
    }

    private func halt() {
        timer?.cancel()
        timer = nil
        generation += 1
        levels = [:]
    }

    private func tick() {
        guard timer != nil, !reading else { return }
        reading = true
        let generation = generation
        let read = read
        let mainHop = mainHop
        offMain { [weak self] in
            let readings = read()
            mainHop { self?.deliver(readings, generation: generation) }
        }
    }

    private func deliver(_ readings: [UUID: MeterReading], generation: Int) {
        reading = false
        guard generation == self.generation, timer != nil else { return }
        levels = readings.mapValues(MeterLevel.init)
    }
}
