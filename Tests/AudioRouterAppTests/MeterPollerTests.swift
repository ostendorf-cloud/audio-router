// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore
import Testing

@testable import AudioRouterAppCore

/// A clock that only ticks when the test says so. Runs on the main actor like the real one.
final class FakeMeterClock: MeterClock, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var next = 0
    private(set) var intervals: [TimeInterval] = []

    var activeTimers: Int { lock.withLock { handlers.count } }

    func every(_ interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) -> any Cancellable {
        lock.withLock {
            next += 1
            handlers[next] = tick
            intervals.append(interval)
            return Cancel(clock: self, id: next)
        }
    }

    /// Fires every timer that is not cancelled.
    func fire() {
        let all = lock.withLock { Array(handlers.values) }
        for handler in all { handler() }
    }

    private struct Cancel: Cancellable {
        let clock: FakeMeterClock
        let id: Int
        func cancel() { clock.lock.withLock { _ = clock.handlers.removeValue(forKey: id) } }
    }
}

/// Counts reads and hands out scripted readings.
final class MeterSource: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var script: [UUID: MeterReading] = [:]

    var reads: Int { lock.withLock { count } }

    func set(_ readings: [UUID: MeterReading]) { lock.withLock { script = readings } }

    func read() -> [UUID: MeterReading] {
        lock.withLock {
            count += 1
            return script
        }
    }
}

/// Holds the off main jobs until the test runs them.
final class HeldJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []

    func hold(_ job: @escaping @Sendable () -> Void) { lock.withLock { jobs.append(job) } }

    func runAll() {
        let all = lock.withLock {
            let taken = jobs
            jobs = []
            return taken
        }
        for job in all { job() }
    }
}

private let routeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!

private func reading(peak: Double, rms: Double) -> MeterReading {
    let level = LevelReading(peak: peak, rms: rms, samples: 100)
    return MeterReading(input: level, output: level, frames: 50)
}

/// Offloading and hopping run inline, so a tick finishes inside `fire`.
@MainActor private func makePoller(_ source: MeterSource, _ clock: FakeMeterClock) -> MeterPoller {
    MeterPoller(
        read: { source.read() }, interval: 0.1, clock: clock, offMain: { $0() },
        mainHop: { work in MainActor.assumeIsolated { work() } })
}

@MainActor @Suite struct MeterPollerTests {
    @Test func nothingRunsBeforeTheFirstClientIsVisible() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let poller = makePoller(source, clock)
        #expect(!poller.isPolling)
        #expect(clock.activeTimers == 0)
        clock.fire()
        #expect(source.reads == 0)
    }

    @Test func theFirstClientStartsPollingAndEveryTickReads() {
        let source = MeterSource()
        source.set([routeID: reading(peak: 0.1, rms: 0.05)])
        let clock = FakeMeterClock()
        let poller = makePoller(source, clock)
        poller.start(.menu)
        #expect(poller.isPolling)
        #expect(clock.intervals == [0.1])
        clock.fire()
        clock.fire()
        #expect(source.reads == 2)
        #expect(poller.levels[routeID]?.peakDBFS == MeterLevel.dBFS(0.1))
    }

    @Test func pollingStopsWhenTheLastClientIsGone() {
        let source = MeterSource()
        source.set([routeID: reading(peak: 0.1, rms: 0.05)])
        let clock = FakeMeterClock()
        let poller = makePoller(source, clock)
        poller.start(.menu)
        clock.fire()
        poller.stop(.menu)
        #expect(!poller.isPolling)
        #expect(clock.activeTimers == 0)
        #expect(poller.levels.isEmpty)
        clock.fire()
        #expect(source.reads == 1)
    }

    @Test func twoClientsKeepPollingUntilBothAreGone() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let poller = makePoller(source, clock)
        poller.start(.menu)
        poller.start(.settings)
        #expect(clock.intervals.count == 1)
        poller.stop(.menu)
        #expect(poller.isPolling)
        clock.fire()
        #expect(source.reads == 1)
        poller.stop(.settings)
        #expect(!poller.isPolling)
        clock.fire()
        #expect(source.reads == 1)
    }

    @Test func aClientCountsOnceHoweverOftenItAppears() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let poller = makePoller(source, clock)
        poller.start(.menu)
        poller.start(.menu)
        poller.stop(.menu)
        #expect(!poller.isPolling)
        poller.stop(.menu)
        #expect(!poller.isPolling)
        #expect(clock.activeTimers == 0)
    }

    @Test func pollingStartsAgainAfterAStop() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let poller = makePoller(source, clock)
        poller.start(.settings)
        poller.stop(.settings)
        poller.start(.settings)
        #expect(poller.isPolling)
        clock.fire()
        #expect(source.reads == 1)
        #expect(clock.intervals.count == 2)
    }

    @Test func stopAllEndsPollingForEveryClient() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let poller = makePoller(source, clock)
        poller.start(.menu)
        poller.start(.settings)
        poller.stopAll()
        #expect(!poller.isPolling)
        clock.fire()
        #expect(source.reads == 0)
    }

    @Test func aRouteThatStopsRunningLosesItsLevel() {
        let source = MeterSource()
        source.set([routeID: reading(peak: 0.5, rms: 0.25)])
        let clock = FakeMeterClock()
        let poller = makePoller(source, clock)
        poller.start(.menu)
        clock.fire()
        #expect(poller.levels[routeID] != nil)
        source.set([:])
        clock.fire()
        #expect(poller.levels.isEmpty)
    }

    @Test func aReadThatEndsAfterTheLastStopIsDropped() {
        let source = MeterSource()
        source.set([routeID: reading(peak: 0.5, rms: 0.25)])
        let clock = FakeMeterClock()
        let jobs = HeldJobs()
        let poller = MeterPoller(
            read: { source.read() }, interval: 0.1, clock: clock, offMain: { jobs.hold($0) },
            mainHop: { work in MainActor.assumeIsolated { work() } })
        poller.start(.menu)
        clock.fire()
        poller.stop(.menu)
        jobs.runAll()
        #expect(poller.levels.isEmpty)
    }

    @Test func aTickWhileAReadIsRunningIsSkipped() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let jobs = HeldJobs()
        let poller = MeterPoller(
            read: { source.read() }, interval: 0.1, clock: clock, offMain: { jobs.hold($0) },
            mainHop: { work in MainActor.assumeIsolated { work() } })
        poller.start(.menu)
        clock.fire()
        clock.fire()
        jobs.runAll()
        #expect(source.reads == 1)
        clock.fire()
        jobs.runAll()
        #expect(source.reads == 2)
    }
}

@Suite struct MeterLevelTests {
    @Test func fullScaleIsZeroDecibels() {
        #expect(MeterLevel.dBFS(1) == 0)
    }

    @Test func aTenthIsMinusTwentyDecibels() {
        #expect(abs(MeterLevel.dBFS(0.1) - -20) < 1e-9)
    }

    @Test func silenceAndTinyValuesStopAtTheFloor() {
        #expect(MeterLevel.dBFS(0) == -60)
        #expect(MeterLevel.dBFS(-1) == -60)
        #expect(MeterLevel.dBFS(.nan) == -60)
        #expect(MeterLevel.dBFS(1e-9) == -60)
        #expect(MeterLevel.dBFS(0.001) == -60)
        #expect(MeterLevel.dBFS(0.002) > -60)
    }

    @Test func aSignalOverFullScaleShowsAboveZeroButFillsTheBarOnly() {
        let level = MeterLevel(peak: 2, rms: 1)
        #expect(level.peakDBFS > 0)
        #expect(level.peakFraction == 1)
        #expect(level.rmsFraction == 1)
    }

    @Test func theBarRunsFromMinusSixtyToZero() {
        #expect(MeterLevel.fraction(dBFS: -60) == 0)
        #expect(MeterLevel.fraction(dBFS: -30) == 0.5)
        #expect(MeterLevel.fraction(dBFS: 0) == 1)
        #expect(MeterLevel.fraction(dBFS: -90) == 0)
        #expect(MeterLevel(peak: 0, rms: 0).peakFraction == 0)
    }

    @Test func aSineAtMinusTwentyShowsPeakAndRms() {
        // Amplitude 0.1 is -20 dBFS peak. The RMS of a sine is the peak over the root of two.
        let level = MeterLevel(peak: 0.1, rms: 0.1 / 2.0.squareRoot())
        #expect(level.peakText == "-20.0")
        #expect(abs(level.rmsDBFS - -23.0103) < 1e-3)
    }

    @Test func theLevelIsTheTapInput() {
        let tap = LevelReading(peak: 0.5, rms: 0.25, samples: 10)
        let out = LevelReading(peak: 0.9, rms: 0.9, samples: 10)
        let level = MeterLevel(MeterReading(input: tap, output: out, frames: 5))
        #expect(level == MeterLevel(peak: 0.5, rms: 0.25))
    }
}
