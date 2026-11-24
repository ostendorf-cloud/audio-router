// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

private let a = EngineSamples.a
private let mixer = EngineSamples.mixer()

private func transient() -> RouterError {
    RouterError.coreAudio(operation: "AudioDeviceStart (start IO)", status: 1)
}

/// Waits for a gate of a fake session. A semaphore, not a sleep: the timeout only ends a hung test.
private func entered(_ gate: Gate) -> Bool {
    gate.entered.wait(timeout: .now() + 10) == .success
}

/// Events that land while a start runs, the teardown order and the lifetimes of listeners and timers.
@Suite struct EngineRecoveryTests {
    @Test func aDeviceFlapDuringStartingTearsDownAfterTheStartAndStartsAgain() throws {
        let rig = EngineRig()
        let gate = rig.maker.gate("a")
        rig.engine.setRoutes([a])
        try rig.engine.start()
        #expect(entered(gate))
        #expect(rig.state(a) == .starting)
        // Gone and back, each after the quiet period, while the start still runs.
        rig.deviceMonitor.set([])
        rig.deviceMonitor.emit(.deviceList)
        rig.deviceClock.advance(by: EngineRig.debounce)
        rig.deviceMonitor.set([mixer])
        rig.deviceMonitor.emit(.deviceList)
        rig.deviceClock.advance(by: EngineRig.debounce)
        gate.release.signal()
        rig.engine.waitUntilIdle()
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102"])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aDeviceFlapWithinTheQuietPeriodStopsAtOnceAndStartsOnce() throws {
        // The session on the device that went away is dead, even when the device is back within
        // the quiet period. The loss stops it at once, the return starts it after the period.
        let rig = EngineRig()
        try rig.run([a])
        rig.deviceMonitor.set([])
        rig.deviceMonitor.emit(.deviceList)
        rig.engine.waitUntilIdle()
        #expect(rig.log == ["start a 101,102", "stop a"])
        rig.deviceClock.advance(by: 1.0)
        rig.deviceMonitor.set([mixer])
        rig.deviceMonitor.emit(.deviceList)
        rig.deviceClock.advance(by: EngineRig.debounce)
        rig.engine.waitUntilIdle()
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102"])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func anAppQuitDuringStartingTearsDownAfterTheStart() throws {
        let rig = EngineRig()
        let gate = rig.maker.gate("a")
        rig.engine.setRoutes([a])
        try rig.engine.start()
        #expect(entered(gate))
        rig.processes.emit(.appQuit(bundleID: EngineSamples.playerID))
        gate.release.signal()
        rig.engine.waitUntilIdle()
        #expect(rig.log == ["start a 101,102", "stop a"])
        #expect(rig.state(a) == .waitingForApp)
    }

    @Test func stopAllDuringStartingWaitsForTheStartThenTearsDown() throws {
        let rig = EngineRig()
        let gate = rig.maker.gate("a")
        rig.engine.setRoutes([a])
        try rig.engine.start()
        #expect(entered(gate))
        let returned = Flag()
        let done = DispatchSemaphore(value: 0)
        let engine = rig.engine
        DispatchQueue.global().async {
            engine.stopAll()
            returned.set()
            done.signal()
        }
        #expect(!returned.isSet)
        gate.release.signal()
        #expect(done.wait(timeout: .now() + 10) == .success)
        // stopAll returned, so the teardown has happened.
        #expect(rig.log == ["start a 101,102", "stop a"])
        #expect(rig.state(a) == .disabled)
        #expect(!rig.deviceMonitor.isObserved)
        #expect(!rig.processes.isActive)
    }

    @Test func stopAllTearsEveryRouteDownAndReportsWhatWasLeftBehind() throws {
        let rig = EngineRig(apps: [EngineSamples.player, EngineSamples.other])
        rig.maker.leaveBehind("b", ["destroy tap: busy"])
        try rig.run([a, EngineSamples.b])
        rig.clock.ignoreCancel(true)
        let leftovers = rig.engine.stopAll()
        #expect(rig.log == ["start a 101,102", "start b 201", "stop a", "stop b"])
        #expect(leftovers == [EngineSamples.b.id: ["destroy tap: busy"]])
        #expect(rig.engine.snapshot.status(of: EngineSamples.b.id)?.teardownFailures == ["destroy tap: busy"])
        // A poll timer that fires after stopAll changes nothing.
        rig.advance(seconds: 3)
        #expect(rig.state(a) == .disabled)
        #expect(rig.log.count == 4)
        // A second stopAll has nothing left to do.
        #expect(rig.engine.stopAll().isEmpty)
        #expect(rig.log.count == 4)
    }

    @Test func aRestartStormLeadsToOneRestart() throws {
        let rig = EngineRig()
        try rig.run([a])
        // Hold the queue so the burst lands at once, like one read of the process list.
        rig.engine.queue.suspend()
        for id: ObjectID in 103...107 {
            rig.processes.emit(.helperStarted(bundleID: EngineSamples.playerID, process: EngineSamples.process(id)))
        }
        rig.engine.queue.resume()
        rig.engine.waitUntilIdle()
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102,103,104,105,106,107"])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aLateEventOfACancelledRunDoesNothing() throws {
        let rig = EngineRig()
        try rig.run([a])
        rig.engine.stopAll()
        try rig.engine.start()
        rig.engine.waitUntilIdle()
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102"])
        rig.processes.emit(.appQuit(bundleID: EngineSamples.playerID), throughRun: 0)
        rig.processes.emit(
            .helperStarted(bundleID: EngineSamples.playerID, process: EngineSamples.process(103)), throughRun: 0)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
        #expect(rig.log.count == 3)
        // The handler of the current run still works.
        rig.emit(.appQuit(bundleID: EngineSamples.playerID))
        #expect(rig.state(a) == .waitingForApp)
    }

    @Test func aLateRetryTimerOfAnOlderBackoffDoesNothing() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 30))
        rig.clock.ignoreCancel(true)
        rig.maker.fail("a", with: [transient(), transient(), transient()])
        try rig.run([a])
        // First backoff: due at 1 s. Half a second later the app quit leaves it and the app start
        // begins a second one (the attempt count starts over), due at 1.5 s.
        rig.clock.advance(by: 0.5)
        rig.emit(.appQuit(bundleID: EngineSamples.playerID))
        rig.emit(.appStarted(EngineSamples.player))
        #expect(rig.state(a) == .failed(.startFailed(message: "\(transient())", attempt: 1, retryIn: 1)))
        // The first timer still fires at 1 s, its cancel was too late. It must not start the route.
        rig.clock.advance(by: 0.5)
        rig.engine.waitUntilIdle()
        #expect(rig.log.count == 2)
        rig.clock.advance(by: 0.5)
        rig.engine.waitUntilIdle()
        #expect(rig.log.count == 3)
        #expect(rig.state(a) == .failed(.startFailed(message: "\(transient())", attempt: 2, retryIn: 2)))
    }

    @Test func aStartThatThrowsLeavesNoListenerInstalled() throws {
        let rig = EngineRig()
        rig.processes.failStart(true)
        rig.engine.setRoutes([a])
        #expect(throws: ScriptedProcessMonitor.StartFailure.self) { try rig.engine.start() }
        #expect(!rig.deviceMonitor.isObserved)
        #expect(rig.deviceMonitor.cancelCalls == 1)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .disabled)
        rig.processes.failStart(false)
        try rig.engine.start()
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func theEngineIsTheOnlyConsumerOfItsDeviceModel() throws {
        let rig = EngineRig()
        let other = try rig.model.start { _ in }
        #expect(throws: DeviceModelError.alreadyRunning) { try rig.engine.start() }
        #expect(!rig.processes.isActive)
        other.cancel()
        try rig.engine.start()
        #expect(throws: RouteEngineError.alreadyRunning) { try rig.engine.start() }
    }

    @Test func droppingTheEngineTearsDownAndRemovesTheListeners() throws {
        let deviceMonitor = FakeDeviceMonitor([mixer])
        let model = DeviceModel(monitor: deviceMonitor, clock: FakeDebounceClock())
        let processes = ScriptedProcessMonitor(initial: [.appStarted(EngineSamples.player)])
        let maker = FakeSessionMaker()
        do {
            let engine = RouteEngine(
                deviceModel: model, processMonitor: processes, sessions: maker, clock: FakeEngineClock())
            engine.setRoutes([a])
            try engine.start()
            engine.waitUntilIdle()
            #expect(maker.log.calls == ["start a 101,102"])
        }
        #expect(maker.log.calls == ["start a 101,102", "stop a"])
        #expect(!deviceMonitor.isObserved)
        #expect(!processes.isActive)
    }
}

/// The real `RouteSession` on the fake backend: the engine keeps the fixed order.
@Suite struct EngineTeardownOrderTests {
    private static let create = ["createTap 101,102", "createAggregate mixer-uid tap-uid", "startIO 20 3,4"]
    private static let teardown = ["stopIO 20 30", "destroyAggregate 20", "destroyTap 10"]

    private func makeRig(_ backend: FakeBackend) -> EngineRig {
        backend.setInfo(FakeBackend.wideInfo)
        let devices = FakeDevices(devices: [Samples.device])
        return EngineRig(sessions: BackendSessionMaker(backend: backend, devices: devices))
    }

    @Test func stopAllTearsDownInTheFixedOrder() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend)
        try rig.run([a])
        #expect(backend.calls == Self.create)
        #expect(rig.state(a) == .running(warnings: []))
        #expect(backend.meterRequested)
        rig.engine.stopAll()
        #expect(backend.calls == Self.create + Self.teardown)
    }

    @Test func aLostDeviceAndARestartTearDownInTheFixedOrder() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend)
        try rig.run([a])
        rig.emit(.helperStarted(bundleID: EngineSamples.playerID, process: EngineSamples.process(103)))
        let restarted = ["createTap 101,102,103", "createAggregate mixer-uid tap-uid", "startIO 20 3,4"]
        #expect(backend.calls == Self.create + Self.teardown + restarted)
        rig.devices([])
        #expect(backend.calls == Self.create + Self.teardown + restarted + Self.teardown)
    }

    @Test func aFailedStartRollsBackAndRetries() throws {
        let backend = FakeBackend(failing: ["createAggregate"])
        let rig = makeRig(backend)
        try rig.run([a])
        #expect(backend.calls == ["createTap 101,102", "createAggregate mixer-uid tap-uid", "destroyTap 10"])
        guard case .failed(.startFailed(_, let attempt, let retryIn)) = rig.state(a) else {
            Issue.record("expected a failed start, got \(String(describing: rig.state(a)))")
            return
        }
        #expect(attempt == 1)
        #expect(retryIn == 1)
    }

    @Test func anUnknownDeviceInTheProviderIsATransientFailure() throws {
        let backend = FakeBackend()
        let rig = EngineRig(sessions: BackendSessionMaker(backend: backend, devices: FakeDevices(devices: [])))
        try rig.run([a])
        #expect(backend.calls.isEmpty)
        guard case .failed(.startFailed(let message, _, _)) = rig.state(a) else {
            Issue.record("expected a failed start, got \(String(describing: rig.state(a)))")
            return
        }
        #expect(message == "\(RouterError.unknownDevice(uid: EngineSamples.mixerUID))")
    }
}
