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

/// Issue 49: a lost destination must let the app play on its default output at once, a returned one
/// must bring the route back by itself, and a default output change must leave the route alone.
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

    /// Plays a raw signal and lets the engine work, without any time passing on the device model.
    private func signal(_ rig: EngineRig, _ devices: [DeviceInfo], _ kind: DeviceSignal = .deviceList) {
        rig.deviceMonitor.set(devices)
        rig.deviceMonitor.emit(kind)
        rig.engine.waitUntilIdle()
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

    @Test func aDefaultOutputChangeLeavesTheRouteAndItsTapAlone() throws {
        let backend = FakeBackend()
        // The mixer is the default output, then headphones connect and macOS makes them the default.
        let rig = makeRig(backend, devices: [mixer(isDefault: true), output(speakers, isDefault: false)])
        try rig.run([a])
        rig.deviceMonitor.set([mixer(), output(speakers, isDefault: false), output(headphones, isDefault: true)])
        rig.deviceMonitor.emit(.deviceList)
        rig.deviceMonitor.emit(.defaultOutput)
        rig.deviceClock.advance(by: EngineRig.debounce)
        rig.engine.waitUntilIdle()
        #expect(rig.model.defaultOutput?.uid == headphones)
        // Then the default moves to the speakers and back to the mixer.
        rig.devices([mixer(), output(speakers, isDefault: true), output(headphones, isDefault: false)])
        rig.devices([mixer(isDefault: true), output(speakers, isDefault: false), output(headphones, isDefault: false)])
        rig.advance(seconds: 3)
        #expect(backend.calls == Self.create)
        #expect(rig.state(a) == .running(warnings: []))
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
