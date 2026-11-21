// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

private let a = EngineSamples.a
private let b = EngineSamples.b
private let mixer = EngineSamples.mixer()
private let player = EngineSamples.player

private func transient(_ status: Int32 = 1) -> RouterError {
    RouterError.coreAudio(operation: "AudioDeviceStart (start IO)", status: status)
}

/// One test per transition of the state machine, driven by scripted events.
@Suite struct EngineTransitionTests {
    @Test func aRouteIsDisabledUntilTheEngineStarts() {
        let rig = EngineRig()
        rig.setRoutes([a])
        #expect(rig.state(a) == .disabled)
        #expect(rig.log.isEmpty)
    }

    @Test func deviceAndAppPresentGoesThroughStartingToRunning() throws {
        let rig = EngineRig()
        rig.setRoutes([a])
        let recorder = StateRecorder(a.id)
        let handle = rig.engine.observe { recorder.record($0) }
        try rig.engine.start()
        rig.engine.waitUntilIdle()
        #expect(recorder.states == [.disabled, .starting, .running(warnings: [])])
        #expect(rig.log == ["start a 101,102"])
        handle.cancel()
    }

    @Test func aMissingDeviceWaitsThenTheAppThenRuns() throws {
        let rig = EngineRig(devices: [], apps: [])
        try rig.run([a])
        #expect(rig.state(a) == .waitingForDevice)
        rig.devices([mixer])
        #expect(rig.state(a) == .waitingForApp)
        rig.emit(.appStarted(player))
        #expect(rig.state(a) == .running(warnings: []))
        #expect(rig.log == ["start a 101,102"])
    }

    @Test func appQuitTearsDownAndWaitsThenAppStartRunsAgain() throws {
        let rig = EngineRig()
        try rig.run([a])
        rig.emit(.appQuit(bundleID: EngineSamples.playerID))
        #expect(rig.state(a) == .waitingForApp)
        rig.emit(.appStarted(AppGroup(bundleID: EngineSamples.playerID, processes: [EngineSamples.process(105)])))
        #expect(rig.state(a) == .running(warnings: []))
        #expect(rig.log == ["start a 101,102", "stop a", "start a 105"])
    }

    @Test func deviceGoneTearsDownAndTheReturnRestartsAfterTheSettleTime() throws {
        let rig = EngineRig()
        try rig.run([a])
        rig.devices([])
        #expect(rig.state(a) == .waitingForDevice)
        #expect(rig.log == ["start a 101,102", "stop a"])

        rig.deviceMonitor.set([mixer])
        rig.deviceMonitor.emit(.deviceList)
        rig.deviceClock.advance(by: 1.0)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .waitingForDevice)
        rig.deviceClock.advance(by: 0.5)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102"])
    }

    @Test func aDeviceThatIsNotAliveCountsAsGone() throws {
        let rig = EngineRig()
        try rig.run([a])
        rig.devices([EngineSamples.mixer(alive: false)])
        #expect(rig.state(a) == .waitingForDevice)
        #expect(rig.log.last == "stop a")
    }

    @Test func disablingARunningRouteTearsItDown() throws {
        let rig = EngineRig()
        try rig.run([a])
        var off = a
        off.enabled = false
        rig.setRoutes([off])
        #expect(rig.state(a) == .disabled)
        #expect(rig.log == ["start a 101,102", "stop a"])
        rig.setRoutes([a])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aWaitingRouteGoesToDisabled() throws {
        let rig = EngineRig(devices: [])
        try rig.run([a])
        #expect(rig.state(a) == .waitingForDevice)
        var off = a
        off.enabled = false
        rig.setRoutes([off])
        #expect(rig.state(a) == .disabled)
    }

    @Test func removingARunningRouteTearsItDownAndDropsIt() throws {
        let rig = EngineRig()
        try rig.run([a, b])
        rig.emit(.appStarted(EngineSamples.other))
        rig.setRoutes([b])
        #expect(rig.engine.snapshot.status(of: a.id) == nil)
        #expect(rig.state(b) == .running(warnings: []))
        #expect(rig.log.filter { $0.hasSuffix(" a") || $0.contains(" a ") } == ["start a 101,102", "stop a"])
    }

    @Test func aRenameDoesNotRestartButAnyOtherChangeDoes() throws {
        let rig = EngineRig()
        try rig.run([a])
        var renamed = a
        renamed.name = "renamed"
        rig.setRoutes([renamed])
        #expect(rig.log == ["start a 101,102"])
        #expect(rig.engine.snapshot.status(of: a.id)?.route.name == "renamed")
        var moved = renamed
        moved.destinationPair = Samples.pair(7)
        rig.setRoutes([moved])
        // A session logs under the name it was made with.
        #expect(rig.log == ["start a 101,102", "stop a", "start renamed 101,102"])
        #expect(rig.engine.snapshot.status(of: a.id)?.route.destinationPair == Samples.pair(7))
    }

    @Test func helperStartedRestartsTheRouteWithTheHelperInTheTap() throws {
        let rig = EngineRig()
        try rig.run([a])
        rig.emit(.helperStarted(bundleID: EngineSamples.playerID, process: EngineSamples.process(103)))
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102,103"])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func helperStoppedAndOtherAppsDoNotRestart() throws {
        let rig = EngineRig()
        try rig.run([a])
        rig.emit(
            .helperStopped(bundleID: EngineSamples.playerID, process: EngineSamples.process(102)),
            .appStarted(EngineSamples.other),
            .helperStarted(bundleID: EngineSamples.otherID, process: EngineSamples.process(202, EngineSamples.otherID)))
        #expect(rig.log == ["start a 101,102"])
        #expect(rig.engine.snapshot.apps.map(\.bundleID) == [EngineSamples.otherID, EngineSamples.playerID])
    }

    @Test func aSampleRateChangeRestartsAndAPersistingMismatchIsAWarning() throws {
        let rig = EngineRig()
        rig.maker.update { $0.info = EngineSamples.matchingRates }
        try rig.run([a])
        #expect(rig.state(a) == .running(warnings: []))
        rig.maker.update { $0.info = EngineSamples.mismatchedRates }
        rig.devices([EngineSamples.mixer(rate: 44100)])
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102"])
        #expect(rig.state(a) == .running(warnings: [.sampleRateMismatch(tap: 48000, device: 44100)]))
    }

    @Test func fewerChannelsFailValidationAndMoreChannelsRunAgain() throws {
        let rig = EngineRig()
        let high = EngineSamples.route("a", number: 1, pair: 31)
        try rig.run([high])
        rig.devices([EngineSamples.mixer(channels: [2])])
        #expect(
            rig.state(high)
                == .failed(.validation([.pairOutOfRange(route: high.id, first: 31, deviceChannels: 2)])))
        #expect(rig.log == ["start a 101,102", "stop a"])
        rig.devices([mixer])
        #expect(rig.state(high) == .running(warnings: []))
    }

    @Test func anInvalidRouteFailsValidationWithoutASession() throws {
        let rig = EngineRig()
        let empty = EngineSamples.route("e", number: 3, app: " ")
        try rig.run([empty])
        #expect(rig.state(empty) == .failed(.validation([.emptyBundleID(route: empty.id)])))
        #expect(rig.maker.sessionsMade == 0)
    }

    @Test func duplicateRouteIDsHoldTheIDAndRunTheOthers() throws {
        let rig = EngineRig()
        let twin = EngineSamples.route("twin", number: 1, pair: 9)
        try rig.run([a, twin, b])
        rig.emit(.appStarted(EngineSamples.other))
        #expect(rig.engine.snapshot.routes.map(\.route.id) == [a.id, b.id])
        #expect(rig.state(a) == .failed(.validation([.duplicateRouteID(route: a.id)])))
        #expect(rig.state(b) == .running(warnings: []))
        #expect(rig.log == ["start b 201"])
    }

    @Test func theLaterOfTwoOverlappingRoutesFailsValidation() throws {
        let rig = EngineRig()
        let overlap = EngineSamples.route("c", number: 3, pair: 4)
        try rig.run([a, overlap])
        #expect(rig.state(a) == .running(warnings: []))
        #expect(
            rig.state(overlap)
                == .failed(
                    .validation([
                        .duplicateDestinationPair(
                            route: overlap.id, first: 4, other: a.id, otherFirst: 3, uid: EngineSamples.mixerUID)
                    ])))
    }

    @Test func globalOffTearsEverythingDownBeforeItReturnsAndOnStartsAgain() throws {
        let rig = EngineRig(apps: [player, EngineSamples.other])
        try rig.run([a, b])
        rig.engine.setOn(false)
        // No wait: off returns only when every route is down.
        #expect(rig.log == ["start a 101,102", "start b 201", "stop a", "stop b"])
        #expect(rig.state(a) == .disabled)
        #expect(rig.state(b) == .disabled)
        #expect(rig.engine.snapshot.isOn == false)
        rig.engine.setOn(true)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
        #expect(rig.state(b) == .running(warnings: []))
    }
}

@Suite struct EngineWarningTests {
    @Test func silenceIsAWarningAndNeverAStop() throws {
        let rig = EngineRig()
        rig.maker.update { $0.silentWarnings = ["no audio arrived"] }
        try rig.run([a])
        rig.advance(seconds: 9)
        #expect(rig.state(a) == .running(warnings: []))
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .running(warnings: [.noSignal(["no audio arrived"])]))
        rig.advance(seconds: 30)
        #expect(rig.log == ["start a 101,102"])
    }

    @Test func aSignalClearsTheSilenceAndTheTapCheckAddsItsWarning() throws {
        let rig = EngineRig()
        rig.maker.update {
            $0.silentWarnings = ["no audio arrived"]
            $0.tapWarning = "warning: tap buffer 1 was picked by stream id diff"
        }
        try rig.run([a])
        rig.advance(seconds: 10)
        #expect(rig.state(a) == .running(warnings: [.noSignal(["no audio arrived"])]))
        rig.maker.update { $0.signal = true }
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .running(warnings: []))
        rig.advance(seconds: 2)
        #expect(rig.state(a) == .running(warnings: [.tapCheck("warning: tap buffer 1 was picked by stream id diff")]))
        rig.advance(seconds: 10)
        #expect(rig.log == ["start a 101,102"])
    }

    @Test func aConsistentTapCheckAddsNothing() throws {
        let rig = EngineRig()
        rig.maker.update { $0.signal = true }
        try rig.run([a])
        rig.advance(seconds: 5)
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func meterReadingsArePublished() throws {
        let rig = EngineRig()
        let reading = MeterReading(
            input: LevelReading(peak: 0.5, rms: 0.25, samples: 96000),
            output: LevelReading(peak: 0.5, rms: 0.25, samples: 96000), frames: 48000)
        rig.maker.update { $0.meter = reading }
        try rig.run([a])
        #expect(rig.engine.snapshot.status(of: a.id)?.meter == nil)
        rig.advance(seconds: 1)
        #expect(rig.engine.snapshot.status(of: a.id)?.meter == reading)
        rig.emit(.appQuit(bundleID: EngineSamples.playerID))
        #expect(rig.engine.snapshot.status(of: a.id)?.meter == nil)
    }

    @Test func observersGetEveryChangeUntilTheyCancel() throws {
        let rig = EngineRig()
        rig.setRoutes([a])
        let recorder = StateRecorder(a.id)
        let handle = rig.engine.observe { recorder.record($0) }
        rig.engine.waitUntilIdle()
        handle.cancel()
        try rig.engine.start()
        rig.engine.waitUntilIdle()
        #expect(recorder.states == [.disabled])
        #expect(rig.state(a) == .running(warnings: []))
    }
}

@Suite struct EngineRetryTests {
    @Test func theRetryDelayDoublesUpToTheCap() {
        let config = EngineConfiguration(retryBase: 1, retryCap: 30)
        #expect((1...7).map { config.retryDelay(afterAttempt: $0) } == [1, 2, 4, 8, 16, 30, 30])
        #expect(config.retryDelay(afterAttempt: 1000) == 30)
    }

    @Test func failedStartsRetryWithBackoffAndThenRun() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 4, maxAttempts: 10))
        rig.maker.fail("a", with: [transient(), transient(), transient(), transient()])
        try rig.run([a])
        let message = "\(transient())"
        #expect(rig.state(a) == .failed(.startFailed(message: message, attempt: 1, retryIn: 1)))
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .failed(.startFailed(message: message, attempt: 2, retryIn: 2)))
        rig.advance(seconds: 1)
        #expect(rig.log.count == 2)
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .failed(.startFailed(message: message, attempt: 3, retryIn: 4)))
        rig.advance(seconds: 4)
        #expect(rig.state(a) == .failed(.startFailed(message: message, attempt: 4, retryIn: 4)))
        rig.advance(seconds: 3)
        #expect(rig.log.count == 4)
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .running(warnings: []))
        #expect(rig.log.count == 5)
    }

    @Test func aTransientErrorStopsRetryingAfterTheLastAttemptUntilRetryNow() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 2, maxAttempts: 3))
        rig.maker.fail("a", with: [transient(), transient(), transient()])
        try rig.run([a])
        rig.advance(seconds: 3)
        #expect(rig.state(a) == .failed(.retriesExhausted(message: "\(transient())", attempts: 3)))
        rig.advance(seconds: 120)
        #expect(rig.log.count == 3)
        #expect(rig.clock.pendingCount == 0)
        rig.engine.retryNow(a.id)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aPermanentErrorIsNotRetriedUntilTheRouteChanges() throws {
        let rig = EngineRig()
        let refusal = RouterError.ambiguousTapStream(device: "Mixer", buffers: [2, 2], tapShape: [2])
        rig.maker.fail("a", with: [refusal])
        try rig.run([a])
        #expect(rig.state(a) == .failed(.refused(message: "\(refusal)")))
        rig.advance(seconds: 300)
        #expect(rig.log == ["start a 101,102"])
        var changed = a
        changed.sourcePair = Samples.pair(3)
        rig.setRoutes([changed])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aHeldFailureWaitsForDeviceAndAppButDoesNotStart() throws {
        let rig = EngineRig()
        let refusal = RouterError.unsupportedFormat("tap format is not float")
        rig.maker.fail("a", with: [refusal])
        try rig.run([a])
        rig.emit(.appQuit(bundleID: EngineSamples.playerID))
        #expect(rig.state(a) == .waitingForApp)
        rig.emit(.appStarted(player))
        #expect(rig.state(a) == .failed(.refused(message: "\(refusal)")))
        #expect(rig.log == ["start a 101,102"])
    }

    @Test func globalOffAndOnClearsAHeldFailure() throws {
        let rig = EngineRig()
        rig.maker.fail("a", with: [RouterError.teardownFailed(["destroy tap: busy"])])
        try rig.run([a])
        #expect(rig.state(a) == .failed(.refused(message: "\(RouterError.teardownFailed(["destroy tap: busy"]))")))
        rig.engine.setOn(false)
        rig.engine.setOn(true)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aDeviceLostDuringTheBackoffWaitsAndStartsWhenItIsBack() throws {
        let rig = EngineRig()
        rig.maker.fail("a", with: [transient()])
        try rig.run([a])
        rig.devices([])
        #expect(rig.state(a) == .waitingForDevice)
        #expect(rig.clock.pendingCount == 0)
        rig.devices([mixer])
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func theDefaultClassesFollowTheErrorsOfTheCode() {
        let permanent: [RouterError] = [
            .usage("bad"), .channelsOutOfRange(first: 31, deviceChannels: 2, deviceName: "Mixer"),
            .unsupportedFormat("16 bit"), .ambiguousTapStream(device: "Mixer", buffers: [2], tapShape: [2]),
            .unprovableTapOrder(device: "Mixer", buffers: [2, 2], tapShape: [2]),
            .refusedWithDiff(reason: "refused", diff: "diff"), .teardownFailed(["destroy tap: busy"]),
        ]
        let transientErrors: [RouterError] = [
            .unknownDevice(uid: EngineSamples.mixerUID), .noMatchingProcess(bundleID: EngineSamples.playerID),
            .coreAudio(operation: "AudioHardwareCreateProcessTap (create tap)", status: 1),
            .sessionAlreadyStopped,
        ]
        #expect(permanent.allSatisfy { StartErrorClass.of($0) == .permanent })
        #expect(transientErrors.allSatisfy { StartErrorClass.of($0) == .transient })
        #expect(StartErrorClass.of(FakeFailure(step: "other")) == .transient)
    }

    @Test func anInjectedClassifierCanMakeAnErrorPermanent() throws {
        let config = EngineConfiguration(classify: { _ in .permanent })
        let rig = EngineRig(configuration: config)
        rig.maker.fail("a", with: [transient(7)])
        try rig.run([a])
        #expect(rig.state(a) == .failed(.refused(message: "\(transient(7))")))
    }
}
