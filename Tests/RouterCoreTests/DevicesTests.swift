// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

/// A monitor with a scripted device list. `emit` plays a raw signal to the observer.
final class FakeDeviceMonitor: DeviceMonitoring, @unchecked Sendable {
    struct SnapshotFailure: Error {}

    private let lock = NSLock()
    private var current: [DeviceInfo]
    private var handler: (@Sendable (DeviceSignal) -> Void)?
    private var failing = false
    private var snapshotHook: (@Sendable () -> Void)?
    private(set) var observeCalls = 0
    private(set) var cancelCalls = 0

    init(_ devices: [DeviceInfo]) { current = devices }

    var isObserved: Bool { lock.withLock { handler != nil } }

    func set(_ devices: [DeviceInfo]) { lock.withLock { current = devices } }

    func failSnapshots(_ value: Bool) { lock.withLock { failing = value } }

    /// Plays a signal like a Core Audio listener would. Nothing happens once the observer is cancelled.
    func emit(_ signal: DeviceSignal) { lock.withLock { handler }?(signal) }

    /// Runs inside each `snapshot()` after the list was read, outside the lock. The probe for a
    /// change that lands while the baseline is read.
    func onSnapshot(_ hook: (@Sendable () -> Void)?) { lock.withLock { snapshotHook = hook } }

    func snapshot() throws -> [DeviceInfo] {
        let (result, hook): ([DeviceInfo], (@Sendable () -> Void)?) = try lock.withLock {
            if failing { throw SnapshotFailure() }
            return (current, snapshotHook)
        }
        hook?()
        return result
    }

    func observe(_ handler: @escaping @Sendable (DeviceSignal) -> Void) throws -> any Cancellable {
        lock.withLock {
            observeCalls += 1
            self.handler = handler
        }
        return Observer(monitor: self)
    }

    private struct Observer: Cancellable {
        let monitor: FakeDeviceMonitor
        func cancel() {
            monitor.lock.withLock {
                monitor.cancelCalls += 1
                monitor.handler = nil
            }
        }
    }
}

/// A monitor that keeps every handler it was given, so a test can play a signal of a cancelled
/// observer, like one that was already in flight when `cancel` ran.
final class KeepingDeviceMonitor: DeviceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [DeviceInfo]
    private var kept: [@Sendable (DeviceSignal) -> Void] = []

    init(_ devices: [DeviceInfo]) { current = devices }

    func set(_ devices: [DeviceInfo]) { lock.withLock { current = devices } }

    /// Plays a signal through the handler of the n-th `observe` call, cancelled or not.
    func emit(_ signal: DeviceSignal, throughObserver index: Int) {
        let handler = lock.withLock { kept[index] }
        handler(signal)
    }

    func snapshot() throws -> [DeviceInfo] { lock.withLock { current } }

    func observe(_ handler: @escaping @Sendable (DeviceSignal) -> Void) throws -> any Cancellable {
        lock.withLock { kept.append(handler) }
        return FakeCancellable()
    }
}

/// A clock that only moves when the test says so.
final class FakeDebounceClock: DebounceClock, @unchecked Sendable {
    private struct Job {
        let id: Int
        let due: TimeInterval
        let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var nextID = 0
    private var jobs: [Job] = []
    private(set) var requestedDelays: [TimeInterval] = []
    /// When true, `cancel` does nothing, like a timer that already started to run.
    var ignoresCancel = false

    var pendingCount: Int { lock.withLock { jobs.count } }

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any Cancellable {
        lock.withLock {
            nextID += 1
            let id = nextID
            requestedDelays.append(seconds)
            jobs.append(Job(id: id, due: now + seconds, work: work))
            return Cancel(clock: self, id: id)
        }
    }

    /// Moves time forward and runs every job that falls due, in order.
    func advance(by seconds: TimeInterval) {
        let target = lock.withLock { now + seconds }
        while true {
            let job: Job? = lock.withLock {
                guard let next = jobs.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) else {
                    now = target
                    return nil
                }
                jobs.removeAll { $0.id == next.id }
                now = next.due
                return next
            }
            guard let job else { return }
            job.work()
        }
    }

    private struct Cancel: Cancellable {
        let clock: FakeDebounceClock
        let id: Int
        func cancel() {
            clock.lock.withLock {
                guard !clock.ignoresCancel else { return }
                clock.jobs.removeAll { $0.id == id }
            }
        }
    }
}

/// True on the first call only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func first() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}

final class BatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[DeviceChange]] = []

    var batches: [[DeviceChange]] { lock.withLock { recorded } }

    func record(_ batch: [DeviceChange]) { lock.withLock { recorded.append(batch) } }
}

private func device(
    _ uid: String, channels: [Int] = [2], rate: Double? = 48000, alive: Bool = true, isDefault: Bool = false
) -> DeviceInfo {
    DeviceInfo(
        uid: uid, name: "Name of \(uid)", outputChannelsPerStream: channels, nominalSampleRate: rate,
        isAlive: alive, isDefaultOutput: isDefault)
}

private struct Rig {
    let monitor: FakeDeviceMonitor
    let clock = FakeDebounceClock()
    let recorder = BatchRecorder()
    let model: DeviceModel

    init(_ devices: [DeviceInfo], debounce: TimeInterval = 1.5) {
        monitor = FakeDeviceMonitor(devices)
        model = DeviceModel(monitor: monitor, clock: clock, debounce: debounce)
    }

    func start() throws -> any Cancellable {
        let recorder = recorder
        return try model.start { recorder.record($0) }
    }
}

struct DeviceModelTests {
    @Test func theModelCarriesTheFieldsOfTheIssue() {
        let info = device("uid-a", channels: [2, 30], rate: 96000, alive: false, isDefault: true)
        #expect(info.uid == "uid-a")
        #expect(info.name == "Name of uid-a")
        #expect(info.outputChannelsPerStream == [2, 30])
        #expect(info.outputChannelCount == 32)
        #expect(info.nominalSampleRate == 96000)
        #expect(!info.isAlive)
        #expect(info.isDefaultOutput)
    }

    @Test func startReadsTheBaselineAndEmitsNothing() throws {
        let rig = Rig([device("uid-a", isDefault: true), device("uid-b")])
        _ = try rig.start()
        #expect(rig.model.devices.map(\.uid) == ["uid-a", "uid-b"])
        #expect(rig.model.defaultOutput?.uid == "uid-a")
        rig.clock.advance(by: 10)
        #expect(rig.recorder.batches.isEmpty)
    }

    @Test func anAddedDeviceIsReportedAfterTheQuietPeriod() throws {
        let rig = Rig([device("uid-a")])
        _ = try rig.start()
        rig.monitor.set([device("uid-a"), device("uid-b")])
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 1.4)
        #expect(rig.recorder.batches.isEmpty)
        rig.clock.advance(by: 0.2)
        #expect(rig.recorder.batches == [[.added(device("uid-b"))]])
        #expect(rig.model.devices.map(\.uid) == ["uid-a", "uid-b"])
    }

    @Test func aRemovedDeviceIsReported() throws {
        let rig = Rig([device("uid-a"), device("uid-b")])
        _ = try rig.start()
        rig.monitor.set([device("uid-a")])
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches == [[.removed(device("uid-b"))]])
        #expect(rig.model.devices.map(\.uid) == ["uid-a"])
    }

    @Test func aFlapWithinTheQuietPeriodReportsNothing() throws {
        let rig = Rig([device("uid-a"), device("uid-b")])
        _ = try rig.start()
        rig.monitor.set([device("uid-a")])
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 0.5)
        rig.monitor.set([device("uid-a"), device("uid-b")])
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 5)
        #expect(rig.recorder.batches.isEmpty)
    }

    @Test func aStormGivesOneBatchAfterTheLastSignal() throws {
        let rig = Rig([device("uid-a")])
        _ = try rig.start()
        rig.monitor.set([device("uid-a"), device("uid-b")])
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 1.0)
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 1.0)
        rig.monitor.emit(.alive)
        rig.clock.advance(by: 1.4)
        #expect(rig.recorder.batches.isEmpty)
        #expect(rig.clock.pendingCount == 1)
        rig.clock.advance(by: 0.1)
        #expect(rig.recorder.batches == [[.added(device("uid-b"))]])
        #expect(rig.clock.pendingCount == 0)
    }

    @Test func aSampleRateChangeIsReported() throws {
        let rig = Rig([device("uid-a", rate: 48000)])
        _ = try rig.start()
        rig.monitor.set([device("uid-a", rate: 44100)])
        rig.monitor.emit(.sampleRate)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches == [[.sampleRateChanged(uid: "uid-a", from: 48000, to: 44100)]])
    }

    @Test func aSampleRateThatReturnsWithinTheQuietPeriodReportsNothing() throws {
        let rig = Rig([device("uid-a", rate: 48000)])
        _ = try rig.start()
        rig.monitor.set([device("uid-a", rate: 44100)])
        rig.monitor.emit(.sampleRate)
        rig.clock.advance(by: 0.5)
        rig.monitor.set([device("uid-a", rate: 48000)])
        rig.monitor.emit(.sampleRate)
        rig.clock.advance(by: 5)
        #expect(rig.recorder.batches.isEmpty)
    }

    @Test func aDefaultOutputChangeIsReported() throws {
        let rig = Rig([device("uid-a", isDefault: true), device("uid-b")])
        _ = try rig.start()
        rig.monitor.set([device("uid-a"), device("uid-b", isDefault: true)])
        rig.monitor.emit(.defaultOutput)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches == [[.defaultOutputChanged(from: "uid-a", to: "uid-b")]])
        #expect(rig.model.defaultOutput?.uid == "uid-b")
    }

    @Test func anAliveChangeIsReported() throws {
        let rig = Rig([device("uid-a")])
        _ = try rig.start()
        rig.monitor.set([device("uid-a", alive: false)])
        rig.monitor.emit(.alive)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches == [[.aliveChanged(uid: "uid-a", isAlive: false)]])
    }

    @Test func aNameChangeAloneIsNoChange() {
        let before = [device("uid-a")]
        let after = [
            DeviceInfo(
                uid: "uid-a", name: "Renamed", outputChannelsPerStream: [2], nominalSampleRate: 48000, isAlive: true,
                isDefaultOutput: false)
        ]
        #expect(DeviceChange.diff(old: before, new: after).isEmpty)
    }

    @Test func aChannelLayoutChangeIsReported() {
        let changes = DeviceChange.diff(
            old: [device("uid-a", channels: [2])], new: [device("uid-a", channels: [2, 2])])
        #expect(changes == [.channelsChanged(uid: "uid-a", from: [2], to: [2, 2])])
    }

    @Test func theDefaultLeavingWithItsDeviceIsOneBatch() throws {
        let rig = Rig([device("uid-a", isDefault: true), device("uid-b")])
        _ = try rig.start()
        rig.monitor.set([device("uid-b")])
        rig.monitor.emit(.deviceList)
        rig.monitor.emit(.defaultOutput)
        rig.clock.advance(by: 1.5)
        #expect(
            rig.recorder.batches == [
                [.removed(device("uid-a", isDefault: true)), .defaultOutputChanged(from: "uid-a", to: nil)]
            ])
    }

    @Test func theQuietPeriodIsConfigurable() throws {
        let rig = Rig([device("uid-a")], debounce: 2.0)
        _ = try rig.start()
        rig.monitor.set([])
        rig.monitor.emit(.deviceList)
        #expect(rig.clock.requestedDelays == [2.0])
        rig.clock.advance(by: 1.9)
        #expect(rig.recorder.batches.isEmpty)
        rig.clock.advance(by: 0.1)
        #expect(rig.recorder.batches.count == 1)
    }

    @Test func theDefaultQuietPeriodIsWithinOneToTwoSeconds() {
        #expect((1.0...2.0).contains(DeviceModel.defaultDebounce))
    }

    @Test func cancelRemovesTheListenerAndThePendingTimer() throws {
        let rig = Rig([device("uid-a")])
        let handle = try rig.start()
        #expect(rig.monitor.isObserved)
        rig.monitor.set([])
        rig.monitor.emit(.deviceList)
        #expect(rig.clock.pendingCount == 1)
        handle.cancel()
        #expect(!rig.monitor.isObserved)
        #expect(rig.monitor.cancelCalls == 1)
        #expect(rig.clock.pendingCount == 0)
        rig.clock.advance(by: 10)
        #expect(rig.recorder.batches.isEmpty)
    }

    @Test func cancelTwiceRemovesTheListenerOnce() throws {
        let rig = Rig([device("uid-a")])
        let handle = try rig.start()
        handle.cancel()
        handle.cancel()
        #expect(rig.monitor.cancelCalls == 1)
    }

    @Test func aStartAfterCancelWorksAndAnOldHandleDoesNotStopIt() throws {
        let rig = Rig([device("uid-a")])
        let first = try rig.start()
        first.cancel()
        _ = try rig.start()
        first.cancel()
        #expect(rig.monitor.isObserved)
        rig.monitor.set([])
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches.count == 1)
    }

    @Test func startingAgainWhileRunningThrowsAndKeepsTheFirstConsumer() throws {
        let rig = Rig([device("uid-a")])
        let second = BatchRecorder()
        _ = try rig.start()
        #expect(throws: DeviceModelError.alreadyRunning) { _ = try rig.model.start { second.record($0) } }
        #expect(rig.monitor.observeCalls == 1)
        #expect(rig.monitor.cancelCalls == 0)
        rig.monitor.set([])
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches.count == 1)
        #expect(second.batches.isEmpty)
    }

    @Test func aChangeWhileTheBaselineIsReadLeadsToOneBatch() throws {
        let rig = Rig([device("uid-a")])
        let monitor = rig.monitor
        monitor.onSnapshot {
            monitor.set([device("uid-a"), device("uid-b")])
            monitor.emit(.deviceList)
        }
        _ = try rig.start()
        #expect(rig.clock.pendingCount == 1)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches == [[.added(device("uid-b"))]])
        #expect(rig.model.devices.map(\.uid) == ["uid-a", "uid-b"])
    }

    @Test func droppingTheModelRemovesTheListenerAndTheTimer() throws {
        let monitor = FakeDeviceMonitor([device("uid-a")])
        let clock = FakeDebounceClock()
        var model: DeviceModel? = DeviceModel(monitor: monitor, clock: clock)
        let handle = try model!.start { _ in }
        monitor.set([])
        monitor.emit(.deviceList)
        #expect(clock.pendingCount == 1)
        model = nil
        #expect(!monitor.isObserved)
        #expect(monitor.cancelCalls == 1)
        #expect(clock.pendingCount == 0)
        withExtendedLifetime(handle) {}
    }

    @Test func anUnreadableSampleRateKeepsTheLastKnownRate() throws {
        let rig = Rig([device("uid-a", rate: 48000)])
        _ = try rig.start()
        rig.monitor.set([device("uid-a", rate: nil)])
        rig.monitor.emit(.sampleRate)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches.isEmpty)
        #expect(rig.model.devices.first?.nominalSampleRate == 48000)
        rig.monitor.set([device("uid-a", rate: 44100)])
        rig.monitor.emit(.sampleRate)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches == [[.sampleRateChanged(uid: "uid-a", from: 48000, to: 44100)]])
    }

    @Test func aRateThatBecomesKnownIsNoChange() {
        #expect(DeviceChange.diff(old: [device("uid-a", rate: nil)], new: [device("uid-a", rate: 48000)]).isEmpty)
    }

    @Test func aStaleTimerAfterARestartDoesNothingAndKeepsTheNewTimer() throws {
        let rig = Rig([device("uid-a")])
        rig.clock.ignoresCancel = true
        let first = try rig.start()
        rig.monitor.emit(.deviceList)
        first.cancel()
        _ = try rig.start()
        rig.clock.advance(by: 1.0)
        rig.monitor.set([])
        rig.monitor.emit(.deviceList)
        #expect(rig.clock.pendingCount == 2)
        rig.clock.advance(by: 0.6)
        #expect(rig.recorder.batches.isEmpty)
        #expect(rig.clock.pendingCount == 1)
        rig.clock.advance(by: 1.0)
        #expect(rig.recorder.batches.count == 1)
    }

    @Test func aLateSignalOfACancelledRunDoesNotEatTheNewTimer() throws {
        let monitor = KeepingDeviceMonitor([device("uid-a")])
        let clock = FakeDebounceClock()
        let recorder = BatchRecorder()
        let model = DeviceModel(monitor: monitor, clock: clock)
        try model.start { _ in }.cancel()
        let handle = try model.start { recorder.record($0) }
        monitor.set([])
        monitor.emit(.deviceList, throughObserver: 1)
        clock.advance(by: 1.0)
        // The old observer was cancelled, but a signal of it was still in flight.
        monitor.emit(.deviceList, throughObserver: 0)
        #expect(clock.pendingCount == 1)
        clock.advance(by: 0.6)
        #expect(recorder.batches == [[.removed(device("uid-a"))]])
        handle.cancel()
    }

    @Test func aTimerStartedWhileTheSnapshotIsReadSurvivesTheSettle() throws {
        let rig = Rig([device("uid-a")])
        let handle = try rig.start()
        let monitor = rig.monitor
        let once = Once()
        monitor.set([device("uid-a"), device("uid-b")])
        monitor.onSnapshot { if once.first() { monitor.emit(.alive) } }
        monitor.emit(.deviceList)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches == [[.added(device("uid-b"))]])
        #expect(rig.clock.pendingCount == 1)
        handle.cancel()
        #expect(rig.clock.pendingCount == 0)
    }

    @Test func aFailedBaselineReadRemovesTheListenerAndThrows() {
        let rig = Rig([device("uid-a")])
        rig.monitor.failSnapshots(true)
        #expect(throws: FakeDeviceMonitor.SnapshotFailure.self) { _ = try rig.start() }
        #expect(!rig.monitor.isObserved)
        #expect(rig.monitor.cancelCalls == 1)
    }

    @Test func aFailedReadAfterTheQuietPeriodKeepsTheStateAndTheNextSignalRecovers() throws {
        let rig = Rig([device("uid-a")])
        _ = try rig.start()
        rig.monitor.set([device("uid-a"), device("uid-b")])
        rig.monitor.failSnapshots(true)
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches.isEmpty)
        #expect(rig.model.devices.map(\.uid) == ["uid-a"])
        rig.monitor.failSnapshots(false)
        rig.monitor.emit(.deviceList)
        rig.clock.advance(by: 1.5)
        #expect(rig.recorder.batches == [[.added(device("uid-b"))]])
    }
}
