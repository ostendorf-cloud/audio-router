// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore
import Testing

@testable import AudioRouterAppCore

private let music = ShellSamples.music
private let video = ShellSamples.video

/// The main hop runs inline on the main thread and hops for real from any other thread.
@MainActor private func makeModel(_ engine: FakeShellEngine) -> ShellViewModel {
    ShellViewModel(
        engine: engine, offMain: { work in DispatchQueue.global().async(execute: work) },
        mainHop: { work in
            if Thread.isMainThread {
                MainActor.assumeIsolated { work() }
            } else {
                DispatchQueue.main.async { work() }
            }
        })
}

@MainActor @Suite struct ShellViewModelTests {
    @Test func followsEngineSnapshotsIntoStatusAndRows() {
        let engine = FakeShellEngine()
        let model = makeModel(engine)
        #expect(model.status == .running)
        #expect(model.rows.isEmpty)

        engine.emit(ShellSamples.snapshot([(music, .running(warnings: [.tapCheck("t")])), (video, .waitingForApp)]))
        #expect(model.status == .warning)
        #expect(model.rows.map(\.title) == ["Music: Running with warning", "Video: Waiting for app"])

        engine.emit(ShellSamples.snapshot([(music, .failed(.refused(message: "x")))]))
        #expect(model.status == .error)
    }

    @Test func globalToggleReachesTheEngineAndTheStatus() async {
        let engine = FakeShellEngine(snapshot: ShellSamples.snapshot([(music, .running(warnings: []))]))
        let model = makeModel(engine)
        await model.setGlobalOn(false)
        #expect(engine.calls == ["setOn(false)"])
        #expect(model.isOn == false)
        #expect(model.status == .off)
        await model.setGlobalOn(true)
        #expect(engine.calls == ["setOn(false)", "setOn(true)"])
        #expect(model.status == .running)
    }

    @Test func routeToggleSendsAllRoutesWithOneFlipped() {
        let engine = FakeShellEngine(snapshot: ShellSamples.snapshot([(music, .disabled), (video, .disabled)]))
        let model = makeModel(engine)
        model.setRouteEnabled(video.id, false)
        let sent = engine.routeCalls.last
        #expect(sent?.map(\.id) == [music.id, video.id])
        #expect(sent?.map(\.enabled) == [true, false])
    }

    @Test func startSetsRoutesAndStartsTheEngine() async {
        let engine = FakeShellEngine()
        let model = makeModel(engine)
        await model.start(routes: [music])
        #expect(engine.calls == ["setRoutes", "start"])
        #expect(model.startFailure == nil)
    }

    @Test func aFailedEngineStartShowsError() async {
        let engine = FakeShellEngine()
        engine.startError = FakeShellEngine.StartFailure()
        let model = makeModel(engine)
        await model.start(routes: [])
        #expect(model.startFailure != nil)
        #expect(model.status == .error)
    }

    @Test func quitRepliesOnlyAfterStopAllReturned() async {
        let gate = DispatchSemaphore(value: 0)
        let engine = FakeShellEngine(gate: gate)
        let model = makeModel(engine)
        var finishedAtReply: Bool?
        model.shutdown { finishedAtReply = engine.stopAllFinished }
        // stopAll is blocked on the gate: no reply may arrive yet.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(finishedAtReply == nil)
        gate.signal()
        while finishedAtReply == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(finishedAtReply == true)
        #expect(engine.calls == ["stopAll"])
    }

    @Test func aSecondQuitRequestDoesNotStopTwice() async {
        let engine = FakeShellEngine()
        let model = makeModel(engine)
        var replies = 0
        model.shutdown { replies += 1 }
        model.shutdown { replies += 1 }
        while replies == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(replies == 1)
        #expect(engine.calls == ["stopAll"])
    }
}
