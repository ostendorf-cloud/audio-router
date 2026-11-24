// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore
import Testing

@testable import AudioRouterAppCore

/// The menu and the editor share one `DesiredRoutesEngine`, over an engine that applies late.
@MainActor private struct RaceRig {
    let store: FakeRouteStore
    let late: LateApplyEngine
    let shell: ShellViewModel
    let editor: EditorViewModel

    init(stored: [Route]) {
        store = FakeRouteStore(stored)
        late = LateApplyEngine(routes: stored)
        let engine = DesiredRoutesEngine(late)
        let provider = FakeDevices(devices: [EditorSamples.mixer], apps: [])
        shell = ShellViewModel(engine: engine)
        editor = EditorViewModel(store: store, engine: engine, devices: provider, apps: provider)
    }
}

@MainActor @Suite struct EditorRaceTests {
    @Test func editingARouteSwitchedOffInTheMenuKeepsItOff() throws {
        let route = EditorSamples.route(1, name: "One", pair: 1)
        let rig = RaceRig(stored: [route])
        rig.shell.setRouteEnabled(route.id, false)
        rig.late.flush()
        rig.editor.beginEdit(route.id)
        #expect(rig.editor.draft.enabled == false)
        rig.editor.draft.name = "Renamed"
        rig.editor.draft.destinationFirst = 5
        #expect(rig.editor.save())
        let saved = try #require(rig.store.stored.first)
        #expect(saved.name == "Renamed")
        #expect(saved.enabled == false)
        #expect(try #require(rig.late.sentLists.last?.first).enabled == false)
    }

    @Test func aMenuSwitchWhileTheFormIsOpenSurvivesTheSave() throws {
        let route = EditorSamples.route(1, name: "One", pair: 1)
        let rig = RaceRig(stored: [route])
        rig.editor.beginEdit(route.id)
        rig.shell.setRouteEnabled(route.id, false)
        rig.late.flush()
        #expect(rig.editor.save())
        #expect(try #require(rig.store.stored.first).enabled == false)
    }

    @Test func aMenuToggleRightAfterASaveKeepsTheSavedRoute() throws {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        let rig = RaceRig(stored: [first])
        rig.editor.beginNew()
        rig.editor.draft.appBundleID = "com.example.new"
        rig.editor.selectDevice("mixer")
        rig.editor.draft.destinationFirst = 5
        #expect(rig.editor.save())
        // The engine has not applied the save yet.
        rig.shell.setRouteEnabled(first.id, false)
        let last = try #require(rig.late.sentLists.last)
        #expect(last.map(\.appBundleID) == ["com.example.app1", "com.example.new"])
        #expect(last[0].enabled == false)
    }

    @Test func aMenuToggleRightAfterADeleteDoesNotBringTheRouteBack() throws {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        let second = EditorSamples.route(2, name: "Two", pair: 3)
        let rig = RaceRig(stored: [first, second])
        #expect(rig.editor.delete(first.id))
        rig.shell.setRouteEnabled(second.id, false)
        let last = try #require(rig.late.sentLists.last)
        #expect(last.map(\.id) == [second.id])
        #expect(last[0].enabled == false)
    }

    @Test func aSaveRightAfterAMenuToggleKeepsTheToggle() throws {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        let second = EditorSamples.route(2, name: "Two", pair: 3)
        let rig = RaceRig(stored: [first, second])
        rig.shell.setRouteEnabled(second.id, false)
        rig.editor.beginEdit(first.id)
        rig.editor.draft.name = "Renamed"
        #expect(rig.editor.save())
        let last = try #require(rig.late.sentLists.last)
        #expect(last.map(\.enabled) == [true, false])
    }

    @Test func twoQuickToggleChangesBothApply() throws {
        let first = EditorSamples.route(1, name: "One", pair: 1)
        let second = EditorSamples.route(2, name: "Two", pair: 3)
        let rig = RaceRig(stored: [first, second])
        rig.shell.setRouteEnabled(first.id, false)
        rig.shell.setRouteEnabled(second.id, false)
        #expect(try #require(rig.late.sentLists.last).map(\.enabled) == [false, false])
    }
}

@MainActor @Suite struct EditorTapChannelTests {
    @Test func sourcePairsFollowOutputStreamZeroNotTheWholeDevice() {
        let split = EditorDevice(uid: "split", name: "Split", channelCount: 16, tapChannelCount: 4)
        let provider = FakeDevices(devices: [split])
        let model = EditorViewModel(
            store: FakeRouteStore(), engine: FakeShellEngine(), devices: provider, apps: provider)
        model.beginNew()
        model.selectDevice("split")
        #expect(model.sourcePairChoices == [1, 3])
        #expect(model.destinationPairChoices.count == 8)
        #expect(model.sourceNote == EditorText.tapLimit)
    }

    @Test func switchingDeviceResetsASourcePairBeyondTheTap() {
        let split = EditorDevice(uid: "split", name: "Split", channelCount: 16, tapChannelCount: 4)
        let provider = FakeDevices(devices: [split])
        let model = EditorViewModel(
            store: FakeRouteStore(), engine: FakeShellEngine(), devices: provider, apps: provider)
        model.beginNew()
        model.draft.sourceFirst = 9
        model.selectDevice("split")
        #expect(model.draft.sourceFirst == 1)
    }

    @Test func providerTakesTheFirstBufferAsTheTapAndFallsBackForOneChannelBuffers() {
        func device(_ uid: String, _ streams: [Int]) -> DeviceInfo {
            DeviceInfo(
                uid: uid, name: uid, outputChannelsPerStream: streams, nominalSampleRate: nil, isAlive: true,
                isDefaultOutput: false)
        }
        let engine = FakeShellEngine(
            snapshot: EngineSnapshot(
                isOn: true, routes: [], devices: [device("multi", [4, 12]), device("mono", [1, 1, 1, 1])], apps: []))
        let found = EditorSnapshotProvider(engine: engine).devices()
        #expect(found.map(\.tapChannelCount) == [4, 4])
        #expect(found.map(\.channelCount) == [16, 4])
    }
}
