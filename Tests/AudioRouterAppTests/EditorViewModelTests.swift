// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore
import Testing

@testable import AudioRouterAppCore

@MainActor private struct Rig {
    let store: FakeRouteStore
    let engine: FakeShellEngine
    let provider: FakeDevices
    let model: EditorViewModel

    init(
        stored: [Route] = [], devices: [EditorDevice] = [EditorSamples.mixer, EditorSamples.stereo],
        apps: [EditorApp] = [EditorSamples.musicApp], snapshot: EngineSnapshot = .empty
    ) {
        store = FakeRouteStore(stored)
        engine = FakeShellEngine(snapshot: snapshot)
        provider = FakeDevices(devices: devices, apps: apps)
        model = EditorViewModel(store: store, engine: engine, devices: provider, apps: provider)
    }

    /// A complete valid draft for a new route on the mixer.
    func fillNew(pair: Int = 3) {
        model.beginNew()
        model.draft.appBundleID = "com.example.music"
        model.selectDevice("mixer")
        model.draft.destinationFirst = pair
    }
}

@MainActor @Suite struct EditorViewModelTests {
    // MARK: - Form

    @Test func newRouteStartsWithSourcePairOneTwoAndNoErrors() {
        let rig = Rig()
        rig.model.beginNew()
        #expect(rig.model.isEditing)
        #expect(rig.model.draft.sourceFirst == 1)
        #expect(rig.model.draft.destinationFirst == 1)
        #expect(rig.model.messages(for: .app).isEmpty)
    }

    @Test func pairChoicesFollowTheChannelCount() {
        let rig = Rig()
        rig.model.beginNew()
        rig.model.selectDevice("stereo")
        #expect(rig.model.destinationPairChoices == [1])
        rig.model.selectDevice("mixer")
        #expect(rig.model.destinationPairChoices.count == 16)
        #expect(rig.model.destinationPairChoices.last == 31)
        #expect(EditorViewModel.pairChoices(channelCount: 8, current: 2) == [1, 2, 3, 5, 7])
        #expect(EditorViewModel.pairChoices(channelCount: 0, current: 1) == [1])
    }

    @Test func switchingToASmallerDeviceResetsPairsThatDoNotFit() {
        let rig = Rig()
        rig.fillNew(pair: 9)
        rig.model.draft.sourceFirst = 5
        rig.model.selectDevice("stereo")
        #expect(rig.model.draft.destinationFirst == 1)
        #expect(rig.model.draft.sourceFirst == 1)
    }

    @Test func typedBundleIDOfAnAppThatIsNotRunningGetsANote() {
        let rig = Rig()
        rig.model.beginNew()
        rig.model.draft.appBundleID = "com.example.music"
        #expect(rig.model.appNote == nil)
        rig.model.draft.appBundleID = " com.example.later "
        #expect(rig.model.appNote == EditorText.appNotRunning)
    }

    @Test func hintStatesTheAppMustPlayToTheDevice() {
        #expect(EditorViewModel.destinationHint.contains("must play to this device"))
    }

    @Test func aStoredDeviceThatIsGoneStaysInThePicker() {
        let route = EditorSamples.route(1, name: "Gone", device: "unplugged", pair: 3)
        let rig = Rig(stored: [route])
        rig.model.beginEdit(route.id)
        #expect(rig.model.deviceChoices.map(\.uid) == ["mixer", "stereo", "unplugged"])
        #expect(rig.model.messages(for: .device) == [EditorText.deviceMissing])
    }

    // MARK: - Validation

    @Test func emptyBundleIDShowsInlineAndWritesNothing() {
        let rig = Rig()
        rig.model.beginNew()
        rig.model.selectDevice("mixer")
        #expect(rig.model.save() == false)
        #expect(rig.model.messages(for: .app) == [EditorText.chooseApp])
        #expect(rig.store.saves.isEmpty)
        #expect(rig.engine.routeCalls.isEmpty)
        #expect(rig.model.isEditing)
    }

    @Test func missingDeviceAsksForOne() {
        let rig = Rig()
        rig.model.beginNew()
        rig.model.draft.appBundleID = "com.example.music"
        #expect(rig.model.save() == false)
        #expect(rig.model.messages(for: .device) == [EditorText.chooseDevice])
    }

    @Test func pairBeyondTheChannelCountShowsInline() {
        let rig = Rig()
        rig.fillNew(pair: 2)
        rig.model.draft.destinationUID = "stereo"
        rig.model.draft.destinationFirst = 3
        #expect(rig.model.save() == false)
        #expect(rig.model.messages(for: .destinationPair) == ["This device has 2 output channels."])
    }

    @Test func overlapWithAnotherRouteNamesThatRoute() {
        let other = EditorSamples.route(1, name: "Music", pair: 3)
        let rig = Rig(stored: [other])
        rig.fillNew(pair: 4)
        #expect(rig.model.save() == false)
        #expect(
            rig.model.messages(for: .destinationPair) == ["Shares a channel with \"Music\" (channels 3,4)."])
        #expect(rig.store.saves.isEmpty)
    }

    @Test func aRouteDoesNotClashWithItself() {
        let route = EditorSamples.route(1, name: "Music", pair: 3)
        let rig = Rig(stored: [route])
        rig.model.beginEdit(route.id)
        #expect(rig.model.issues.isEmpty)
    }

    @Test func aProblemOfAnotherRouteDoesNotBlockTheSave() {
        let broken = EditorSamples.route(1, name: "Broken", device: "unplugged", pair: 3)
        let rig = Rig(stored: [broken])
        rig.fillNew(pair: 5)
        #expect(rig.model.save())
        #expect(rig.store.stored.count == 2)
    }

    @Test func aSwitchedOffRouteIsStillChecked() {
        let off = EditorSamples.route(1, name: "Off", pair: 3, enabled: false)
        let rig = Rig(stored: [off])
        rig.model.beginEdit(off.id)
        rig.model.draft.destinationFirst = 40
        #expect(rig.model.messages(for: .destinationPair) == ["This device has 32 output channels."])
    }

    // MARK: - Save

    @Test func saveWritesTheStoreAndTheEngineGetsTheSameRoutes() throws {
        let rig = Rig()
        rig.fillNew(pair: 3)
        rig.model.draft.name = "  Music  "
        rig.model.draft.appBundleID = " com.example.music "
        #expect(rig.model.save())
        let saved = try #require(rig.store.saves.last?.first)
        #expect(saved.name == "Music")
        #expect(saved.appBundleID == "com.example.music")
        #expect(saved.destinationUID == "mixer")
        #expect(saved.destinationPair.first == 3)
        #expect(saved.sourcePair.first == 1)
        #expect(saved.enabled)
        #expect(rig.engine.routeCalls == [[saved]])
        #expect(rig.model.routes == [saved])
        #expect(rig.model.isEditing == false)
    }

    @Test func blankNameFallsBackToTheBundleID() throws {
        let rig = Rig()
        rig.fillNew()
        #expect(rig.model.save())
        #expect(try #require(rig.store.stored.first).name == "com.example.music")
    }

    @Test func editingReplacesTheRouteInPlace() throws {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        let second = EditorSamples.route(2, name: "Two", pair: 3)
        let rig = Rig(stored: [first, second])
        rig.model.beginEdit(first.id)
        rig.model.draft.destinationFirst = 7
        rig.model.draft.sourceFirst = 3
        #expect(rig.model.save())
        let saved = rig.store.stored
        #expect(saved.map(\.id) == [first.id, second.id])
        #expect(saved[0].destinationPair.first == 7)
        #expect(saved[0].sourcePair.first == 3)
        #expect(saved[1] == second)
        #expect(rig.engine.routeCalls == [saved])
    }

    @Test func saveKeepsTheMenuSwitchOfOtherRoutes() {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        var switchedOff = first
        switchedOff.enabled = false
        let snapshot = EngineSnapshot(
            isOn: true,
            routes: [RouteStatus(route: switchedOff, state: .disabled, meter: nil, teardownFailures: [])],
            devices: [], apps: [])
        let rig = Rig(stored: [first], snapshot: snapshot)
        rig.fillNew(pair: 5)
        #expect(rig.model.save())
        #expect(rig.store.stored.first?.enabled == false)
    }

    @Test func failedStoreWriteKeepsTheFormAndLeavesTheEngineAlone() {
        let rig = Rig()
        rig.store.failSaves = true
        rig.fillNew()
        #expect(rig.model.save() == false)
        #expect(rig.model.failure == "disk full")
        #expect(rig.model.isEditing)
        #expect(rig.engine.routeCalls.isEmpty)
        #expect(rig.model.routes.isEmpty)
    }

    @Test func unreadableStoreBlocksTheSave() {
        let rig = Rig()
        let model = EditorViewModel(
            store: EditorUnavailableStore(reason: "no directory"), engine: rig.engine, devices: rig.provider,
            apps: rig.provider)
        #expect(model.failure == "routes file cannot be written: no directory")
        model.beginNew()
        model.draft.appBundleID = "com.example.music"
        model.selectDevice("mixer")
        #expect(model.save() == false)
        #expect(rig.engine.routeCalls.isEmpty)
    }

    // MARK: - Delete

    @Test func deleteRemovesTheRouteFromStoreAndEngine() {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        let second = EditorSamples.route(2, name: "Two", pair: 3)
        let rig = Rig(stored: [first, second])
        #expect(rig.model.delete(first.id))
        #expect(rig.store.stored == [second])
        #expect(rig.engine.routeCalls == [[second]])
        #expect(rig.model.routes == [second])
    }

    @Test func deleteOfTheOpenRouteClosesTheForm() {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        let rig = Rig(stored: [first])
        rig.model.beginEdit(first.id)
        #expect(rig.model.delete(first.id))
        #expect(rig.model.isEditing == false)
    }

    @Test func failedDeleteChangesNothing() {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        let rig = Rig(stored: [first])
        rig.store.failSaves = true
        #expect(rig.model.delete(first.id) == false)
        #expect(rig.model.routes == [first])
        #expect(rig.engine.routeCalls.isEmpty)
        #expect(rig.model.failure == "disk full")
    }

    // MARK: - List and providers

    @Test func rowsNameTheDeviceAndThePair() {
        let rig = Rig(stored: [EditorSamples.route(1, name: "One", pair: 3)])
        #expect(rig.model.rows.map(\.detail) == ["com.example.app1 to Mixer, channels 3,4"])
    }

    @Test func snapshotProviderReadsDevicesAndApps() {
        let devices = [
            DeviceInfo(
                uid: "mixer", name: "Mixer", outputChannelsPerStream: [16, 16], nominalSampleRate: nil,
                isAlive: true, isDefaultOutput: false),
            DeviceInfo(
                uid: "mic", name: "Mic", outputChannelsPerStream: [], nominalSampleRate: nil, isAlive: true,
                isDefaultOutput: false),
        ]
        let process = AudioProcess(objectID: 1, pid: 1, bundleID: "com.example.music", isRunningOutput: true)
        let engine = FakeShellEngine(
            snapshot: EngineSnapshot(
                isOn: true, routes: [], devices: devices,
                apps: [AppGroup(bundleID: "com.example.music", processes: [process])]))
        let provider = EditorSnapshotProvider(engine: engine)
        #expect(
            provider.devices() == [EditorDevice(uid: "mixer", name: "Mixer", channelCount: 32, tapChannelCount: 16)])
        #expect(provider.apps() == [EditorApp(bundleID: "com.example.music", isPlaying: true)])
    }
}
