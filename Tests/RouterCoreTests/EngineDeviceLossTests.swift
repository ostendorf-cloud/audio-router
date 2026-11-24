// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

private let a = EngineSamples.a

private func output(_ uid: String, isDefault: Bool, channels: [Int] = [2], alive: Bool = true) -> DeviceInfo {
    DeviceInfo(
        uid: uid, name: "Name of \(uid)", outputChannelsPerStream: channels, nominalSampleRate: 48000,
        isAlive: alive, isDefaultOutput: isDefault)
}

private func mixer(isDefault: Bool = false, alive: Bool = true) -> DeviceInfo {
    output(EngineSamples.mixerUID, isDefault: isDefault, channels: [32], alive: alive)
}

private let speakers = "speakers-uid"
private let headphones = "headphones-uid"

/// Issues 42 and 49: a destination that is gone, dead or left by the default output must let the
/// app play on the current default at once, and its return must bring the route back by itself.
/// The real `RouteSession` runs on the fake backend, so every Core Audio step is visible.
@Suite struct EngineDeviceLossTests {
    private static let create = ["createTap 101,102", "createAggregate mixer-uid tap-uid", "startIO 20 3,4"]
    private static let teardown = ["stopIO 20 30", "destroyAggregate 20", "destroyTap 10"]

    private func makeRig(_ backend: FakeBackend, devices: [DeviceInfo]) -> EngineRig {
        backend.setInfo(FakeBackend.wideInfo)
        // The app plays while the route runs.
        backend.setSignal(true)
        let provider = FakeDevices(devices: [Samples.device])
        return EngineRig(devices: devices, sessions: BackendSessionMaker(backend: backend, devices: provider))
    }

    /// Plays a raw signal and lets the engine work. A device list signal also lets the short read
    /// that confirms a missing device pass, never the quiet period. Other signals let no time pass.
    private func signal(_ rig: EngineRig, _ devices: [DeviceInfo], _ kind: DeviceSignal = .deviceList) {
        rig.deviceMonitor.set(devices)
        rig.deviceMonitor.emit(kind)
        if kind == .deviceList { rig.deviceClock.advance(by: DeviceModel.defaultLossConfirmDelay) }
        rig.engine.waitUntilIdle()
    }

    @Test func aDeviceMissingFromOneReadOnlyKeepsTheRoute() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(), output(speakers, isDefault: true)])
        try rig.run([a])
        // One read during device churn misses the mixer, the confirm read finds it again.
        rig.deviceMonitor.set([output(speakers, isDefault: true)])
        rig.deviceMonitor.emit(.deviceList)
        rig.deviceMonitor.set([mixer(), output(speakers, isDefault: true)])
        rig.deviceClock.advance(by: 5)
        rig.engine.waitUntilIdle()
        #expect(backend.calls == Self.create)
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aFailedAliveReadKeepsTheRoute() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(), output(speakers, isDefault: true)])
        try rig.run([a])
        let unreadable = DeviceInfo(
            uid: EngineSamples.mixerUID, name: "Name of mixer", outputChannelsPerStream: [32], nominalSampleRate: 48000,
            isAlive: false, isDefaultOutput: false, isAliveKnown: false)
        signal(rig, [unreadable, output(speakers, isDefault: true)], .alive)
        rig.deviceClock.advance(by: 5)
        rig.engine.waitUntilIdle()
        #expect(backend.calls == Self.create)
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aRemovedDeviceStopsTheIOAndReleasesTheTapWithoutWaitingForTheQuietPeriod() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(), output(speakers, isDefault: true)])
        try rig.run([a])
        #expect(backend.calls == Self.create)
        signal(rig, [output(speakers, isDefault: true)])
        // No time passed: the quiet period is for the way back, not for the loss.
        #expect(backend.calls == Self.create + Self.teardown)
        #expect(rig.state(a) == .waitingForDevice)
        #expect(rig.engine.snapshot.status(of: a.id)?.teardownFailures == [])
    }

    @Test func aDeviceThatIsNoLongerAliveStopsTheRouteAtOnce() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(), output(speakers, isDefault: true)])
        try rig.run([a])
        signal(rig, [mixer(alive: false), output(speakers, isDefault: true)], .alive)
        #expect(backend.calls == Self.create + Self.teardown)
        #expect(rig.state(a) == .waitingForDevice)
    }

    @Test func theReturnedDeviceStartsTheRouteAgainAfterTheQuietPeriod() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(), output(speakers, isDefault: true)])
        try rig.run([a])
        signal(rig, [output(speakers, isDefault: true)])
        #expect(rig.state(a) == .waitingForDevice)
        signal(rig, [mixer(), output(speakers, isDefault: true)])
        rig.deviceClock.advance(by: EngineRig.debounce - 0.1)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .waitingForDevice)
        // The bound: one quiet period after the last signal, no user action.
        rig.deviceClock.advance(by: 0.1)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
        #expect(backend.calls == Self.create + Self.teardown + Self.create)
    }

    @Test func aFlapWithinTheQuietPeriodStopsAtOnceAndStartsOnceAfterIt() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(), output(speakers, isDefault: true)])
        try rig.run([a])
        signal(rig, [output(speakers, isDefault: true)])
        rig.deviceClock.advance(by: 0.5)
        signal(rig, [mixer(), output(speakers, isDefault: true)])
        #expect(backend.calls == Self.create + Self.teardown)
        rig.deviceClock.advance(by: EngineRig.debounce)
        rig.engine.waitUntilIdle()
        #expect(backend.calls == Self.create + Self.teardown + Self.create)
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func theDefaultMovingAwayFromTheTargetStopsTheRouteAtOnce() throws {
        // Concept and issue 42: the mixer is the default, then headphones connect and macOS makes
        // them the default. The app follows the default, so the target counts as lost. The tap is
        // released and the app plays on the headphones.
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(isDefault: true), output(speakers, isDefault: false)])
        try rig.run([a])
        signal(
            rig, [mixer(), output(speakers, isDefault: false), output(headphones, isDefault: true)], .defaultOutput)
        // No time passed on the device model.
        #expect(backend.calls == Self.create + Self.teardown)
        #expect(rig.state(a) == .waitingForDevice)
        // The new default arrives after the quiet period and changes nothing for the route.
        rig.deviceClock.advance(by: EngineRig.debounce)
        rig.engine.waitUntilIdle()
        #expect(rig.model.defaultOutput?.uid == headphones)
        #expect(backend.calls == Self.create + Self.teardown)
        #expect(rig.state(a) == .waitingForDevice)
    }

    @Test func theDefaultReturningToTheTargetStartsTheRouteAfterTheQuietPeriod() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(isDefault: true), output(speakers, isDefault: false)])
        try rig.run([a])
        signal(rig, [mixer(), output(speakers, isDefault: true)], .defaultOutput)
        rig.deviceClock.advance(by: 5)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .waitingForDevice)
        signal(rig, [mixer(isDefault: true), output(speakers, isDefault: false)], .defaultOutput)
        rig.deviceClock.advance(by: EngineRig.debounce - 0.1)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .waitingForDevice)
        rig.deviceClock.advance(by: 0.1)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
        #expect(backend.calls == Self.create + Self.teardown + Self.create)
    }

    @Test func aDefaultChangeThatDoesNotLeaveTheTargetKeepsTheRoute() throws {
        // The route runs while the speakers are the default. The default moves to the headphones,
        // then to the mixer itself. Neither leaves the target.
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(), output(speakers, isDefault: true)])
        try rig.run([a])
        signal(rig, [mixer(), output(speakers, isDefault: false), output(headphones, isDefault: true)], .defaultOutput)
        signal(rig, [mixer(isDefault: true), output(speakers, isDefault: false), output(headphones, isDefault: false)])
        rig.deviceClock.advance(by: 5)
        rig.engine.waitUntilIdle()
        rig.advance(seconds: 3)
        #expect(backend.calls == Self.create)
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aDefaultMovingAwayStopsOnlyTheRouteOnThatTarget() throws {
        let other = EngineSamples.route("b", number: 2, pair: 5, app: EngineSamples.otherID, device: "other-uid")
        let rig = EngineRig(
            devices: [mixer(isDefault: true), output("other-uid", isDefault: false, channels: [8])],
            apps: [EngineSamples.player, EngineSamples.other])
        try rig.run([a, other])
        #expect(rig.log == ["start a 101,102", "start b 201"])
        signal(rig, [mixer(), output("other-uid", isDefault: true, channels: [8])], .defaultOutput)
        #expect(rig.log == ["start a 101,102", "start b 201", "stop a"])
        #expect(rig.state(a) == .waitingForDevice)
        #expect(rig.state(other) == .running(warnings: []))
    }

    @Test func anUnplugThatAlsoMovesTheDefaultTearsDownOnce() throws {
        // The X32 case: the mixer goes away and macOS makes the speakers the default.
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(isDefault: true), output(speakers, isDefault: false)])
        try rig.run([a])
        rig.deviceMonitor.set([output(speakers, isDefault: true)])
        rig.deviceMonitor.emit(.deviceList)
        rig.deviceMonitor.emit(.defaultOutput)
        rig.deviceClock.advance(by: 5)
        rig.engine.waitUntilIdle()
        #expect(backend.calls == Self.create + Self.teardown)
        #expect(rig.state(a) == .waitingForDevice)
        // Plugged in again and the default again: one start after the quiet period.
        signal(rig, [mixer(isDefault: true), output(speakers, isDefault: false)])
        rig.deviceClock.advance(by: EngineRig.debounce)
        rig.engine.waitUntilIdle()
        #expect(backend.calls == Self.create + Self.teardown + Self.create)
        #expect(rig.state(a) == .running(warnings: []))
    }

    @Test func aTargetThatIsBackButNotTheDefaultKeepsWaiting() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(isDefault: true), output(speakers, isDefault: false)])
        try rig.run([a])
        signal(rig, [output(speakers, isDefault: true)])
        signal(rig, [mixer(), output(speakers, isDefault: true)])
        rig.deviceClock.advance(by: 5)
        rig.engine.waitUntilIdle()
        #expect(backend.calls == Self.create + Self.teardown)
        #expect(rig.state(a) == .waitingForDevice)
    }

    @Test func aNewRunForgetsThatTheDefaultMovedAway() throws {
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(isDefault: true), output(speakers, isDefault: false)])
        try rig.run([a])
        signal(rig, [mixer(), output(speakers, isDefault: true)], .defaultOutput)
        #expect(rig.state(a) == .waitingForDevice)
        rig.engine.stopAll()
        // The mixer is the default again before the new run. The new run reads it as its baseline,
        // so no default change arrives that could clear the mark.
        rig.deviceMonitor.set([mixer(isDefault: true), output(speakers, isDefault: false)])
        try rig.engine.start()
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
        #expect(backend.calls == Self.create + Self.teardown + Self.create)
    }

    @Test func aNewDestinationForgetsThatTheDefaultMovedAway() throws {
        let rig = EngineRig(devices: [mixer(isDefault: true), output("other-uid", isDefault: false, channels: [8])])
        try rig.run([a])
        signal(rig, [mixer(), output("other-uid", isDefault: true, channels: [8])], .defaultOutput)
        rig.deviceClock.advance(by: 5)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .waitingForDevice)
        // The route moves to the device that is the default now. It must not inherit the mark.
        let moved = EngineSamples.route("a", number: 1, pair: 3, device: "other-uid")
        rig.setRoutes([moved])
        #expect(rig.state(moved) == .running(warnings: []))
        #expect(rig.log == ["start a 101,102", "stop a", "start a 101,102"])
    }

    @Test func aDefaultFlipAwayAndBackWithinTheQuietPeriodStopsOnceAndStartsOnce() throws {
        // The X32 is the default, the AirPods take it for half a second, then the X32 again.
        let backend = FakeBackend()
        let rig = makeRig(backend, devices: [mixer(isDefault: true), output(headphones, isDefault: false)])
        try rig.run([a])
        signal(rig, [mixer(), output(headphones, isDefault: true)], .defaultOutput)
        #expect(backend.calls == Self.create + Self.teardown)
        rig.deviceClock.advance(by: 0.5)
        signal(rig, [mixer(isDefault: true), output(headphones, isDefault: false)], .defaultOutput)
        rig.deviceClock.advance(by: EngineRig.debounce - 0.1)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .waitingForDevice)
        rig.deviceClock.advance(by: 0.1)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
        // No stale mark and no second start later.
        rig.deviceClock.advance(by: 5)
        rig.engine.waitUntilIdle()
        rig.advance(seconds: 3)
        #expect(rig.state(a) == .running(warnings: []))
        #expect(backend.calls == Self.create + Self.teardown + Self.create)
    }

    @Test func aLossWhileAStopStepFailsStillReleasesTheTap() throws {
        // A device that vanished may refuse to stop its IO. The tap must go anyway, so the app
        // is not muted by a tap that nobody reads.
        let backend = FakeBackend(failing: ["stopIO", "destroyAggregate"])
        let rig = makeRig(backend, devices: [mixer(), output(speakers, isDefault: true)])
        try rig.run([a])
        signal(rig, [output(speakers, isDefault: true)])
        #expect(backend.calls == Self.create + Self.teardown)
        #expect(backend.calls.last == "destroyTap 10")
        #expect(rig.state(a) == .waitingForDevice)
        #expect(rig.engine.snapshot.status(of: a.id)?.teardownFailures.count == 2)
    }
}
