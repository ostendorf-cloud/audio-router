// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

private let a = EngineSamples.a
private let b = EngineSamples.b
private let mixer = EngineSamples.mixer()

private func transient() -> RouterError {
    RouterError.coreAudio(operation: "AudioDeviceStart (start IO)", status: 1)
}

private let refusal = RouterError.ambiguousTapStream(device: "Mixer", buffers: [2, 2], tapShape: [2])

private func otherDevice(rate: Double = 48000) -> DeviceInfo {
    DeviceInfo(
        uid: "other-uid", name: "Other", outputChannelsPerStream: [2], nominalSampleRate: rate, isAlive: true,
        isDefaultOutput: false)
}

/// What clears a held failure and what does not.
@Suite struct EngineHoldTests {
    @Test func aReplugStartsTheAttemptCountOver() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 30, maxAttempts: 3))
        rig.maker.fail("a", with: [transient(), transient(), transient()])
        try rig.run([a])
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .failed(.startFailed(message: "\(transient())", attempt: 2, retryIn: 2)))
        rig.devices([])
        rig.devices([mixer])
        #expect(rig.state(a) == .failed(.startFailed(message: "\(transient())", attempt: 1, retryIn: 1)))
    }

    @Test func exhaustedRetriesClearWhenTheDeviceIsBack() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 30, maxAttempts: 2))
        rig.maker.fail("a", with: [transient(), transient()])
        try rig.run([a])
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .failed(.retriesExhausted(message: "\(transient())", attempts: 2)))
        rig.devices([])
        rig.devices([mixer])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func exhaustedRetriesClearWhenTheDeviceIsAliveAgain() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 30, maxAttempts: 1))
        rig.maker.fail("a", with: [transient()])
        try rig.run([a])
        #expect(rig.state(a) == .failed(.retriesExhausted(message: "\(transient())", attempts: 1)))
        rig.devices([EngineSamples.mixer(alive: false)])
        rig.devices([mixer])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func exhaustedRetriesClearWhenTheAppStartsAgain() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 30, maxAttempts: 2))
        rig.maker.fail("a", with: [transient(), transient()])
        try rig.run([a])
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .failed(.retriesExhausted(message: "\(transient())", attempts: 2)))
        rig.emit(.appQuit(bundleID: EngineSamples.playerID), .appStarted(EngineSamples.player))
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func refusedSurvivesAReplugAndAnAppRestart() throws {
        let rig = EngineRig()
        rig.maker.fail("a", with: [refusal])
        try rig.run([a])
        rig.devices([])
        rig.devices([mixer])
        rig.emit(.appQuit(bundleID: EngineSamples.playerID), .appStarted(EngineSamples.player))
        #expect(rig.state(a) == .failed(.refused(message: "\(refusal)")))
        #expect(rig.log == ["start a 101,102"])
    }

    @Test func refusedClearsOnANewRun() throws {
        let rig = EngineRig()
        rig.maker.fail("a", with: [refusal])
        try rig.run([a])
        rig.engine.stopAll()
        try rig.engine.start()
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func refusedClearsOnRetryNow() throws {
        let rig = EngineRig()
        rig.maker.fail("a", with: [refusal])
        try rig.run([a])
        rig.engine.retryNow(a.id)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func otherEventsDoNotCutTheBackoffShort() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 10, retryCap: 30))
        rig.maker.fail("a", with: [transient()])
        try rig.run([a])
        let waiting = RouteState.failed(.startFailed(message: "\(transient())", attempt: 1, retryIn: 10))
        #expect(rig.state(a) == waiting)
        rig.setRoutes([a, b])
        rig.emit(
            .appStarted(EngineSamples.other),
            .helperStopped(bundleID: EngineSamples.playerID, process: EngineSamples.process(102)))
        rig.devices([mixer, otherDevice()])
        #expect(rig.state(a) == waiting)
        #expect(rig.log == ["start a 101,102", "start b 201"])
        rig.advance(seconds: 9)
        #expect(rig.log.count == 2)
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aChangeOfAnUnrelatedDeviceLeavesARunningRouteAlone() throws {
        let rig = EngineRig(devices: [mixer, otherDevice()])
        try rig.run([a])
        rig.devices([mixer])
        rig.devices([mixer, otherDevice()])
        rig.devices([mixer, otherDevice(rate: 44100)])
        #expect(rig.log == ["start a 101,102"])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aDeviceBatchInFlightAcrossStopAllAndStartIsDropped() throws {
        let rig = EngineRig()
        try rig.run([a])
        // The handler the old run's device model would still call.
        let late = rig.engine.deviceBatchHandler(run: rig.engine.currentRun)
        rig.engine.stopAll()
        try rig.engine.start()
        rig.engine.waitUntilIdle()
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102"])
        late([.removed(mixer)])
        rig.engine.waitUntilIdle()
        #expect(rig.log.count == 3)
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aDroppedObserverHandleStopsTheCalls() throws {
        let rig = EngineRig()
        rig.setRoutes([a])
        let recorder = StateRecorder(a.id)
        do {
            _ = rig.engine.observe { recorder.record($0) }
        }
        try rig.engine.start()
        rig.engine.waitUntilIdle()
        #expect(recorder.states.isEmpty)
        #expect(rig.state(a) == .running(warnings: []))
    }
}
