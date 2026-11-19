// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

struct RouteSessionTests {
    private let plan = RoutePlan(
        device: Samples.device,
        channels: Samples.pair(3),
        appBundleID: "com.google.Chrome",
        processes: [Samples.process(1, "com.google.Chrome"), Samples.process(2, "com.google.Chrome.helper")]
    )

    private let created = [
        "createTap 1,2", "createAggregate mixer-uid tap-uid", "startIO 20 3,4",
    ]

    /// Runs `body` on its own thread and returns a flag that is set when it finished.
    private func background(_ body: @escaping @Sendable () -> Void) -> (done: Flag, finished: DispatchSemaphore) {
        let done = Flag()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.set()
            finished.signal()
        }
        thread.start()
        return (done, finished)
    }

    @Test func startCreatesTapThenAggregateThenIO() throws {
        let backend = FakeBackend()
        try RouteSession(backend: backend, plan: plan).start()
        #expect(backend.calls == created)
    }

    @Test func stopTearsDownInReverseOrder() throws {
        let backend = FakeBackend()
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        #expect(session.stop().isEmpty)
        #expect(
            backend.calls == created + ["stopIO 20 30", "destroyAggregate 20", "destroyTap 10"])
    }

    @Test func stopRunsOnce() throws {
        let backend = FakeBackend()
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        session.stop()
        session.stop()
        #expect(backend.calls.count == created.count + 3)
    }

    @Test func failedTapCreationCreatesNothingElse() {
        let backend = FakeBackend(failing: ["createTap"])
        #expect(throws: FakeFailure.self) { try RouteSession(backend: backend, plan: plan).start() }
        #expect(backend.calls == ["createTap 1,2"])
    }

    @Test func failedAggregateDestroysTheTap() {
        let backend = FakeBackend(failing: ["createAggregate"])
        #expect(throws: FakeFailure.self) { try RouteSession(backend: backend, plan: plan).start() }
        #expect(
            backend.calls == [
                "createTap 1,2", "createAggregate mixer-uid tap-uid", "destroyTap 10",
            ])
    }

    @Test func failedIOStartDestroysAggregateThenTap() {
        let backend = FakeBackend(failing: ["startIO"])
        #expect(throws: FakeFailure.self) { try RouteSession(backend: backend, plan: plan).start() }
        #expect(
            backend.calls == [
                "createTap 1,2", "createAggregate mixer-uid tap-uid", "startIO 20 3,4",
                "destroyAggregate 20", "destroyTap 10",
            ])
    }

    @Test func aFailingStepDoesNotSkipTheRest() throws {
        let backend = FakeBackend(failing: ["stopIO", "destroyAggregate"])
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        let failures = session.stop()
        #expect(failures.count == 2)
        #expect(backend.calls.suffix(3) == ["stopIO 20 30", "destroyAggregate 20", "destroyTap 10"])
    }

    @Test func rollbackFailureIsReportedWithTheOriginalError() {
        let backend = FakeBackend(failing: ["createAggregate", "destroyTap"])
        do {
            try RouteSession(backend: backend, plan: plan).start()
            Issue.record("start should have thrown")
        } catch let error as RouterError {
            guard case .teardownFailed(let messages) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(messages.count == 2)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    // MARK: Concurrency

    @Test func aSecondStopWaitsUntilTheFirstTeardownFinished() throws {
        let backend = FakeBackend(gating: ["stopIO"])
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        let gate = try #require(backend.gates["stopIO"])

        let first = background { session.stop() }
        gate.entered.wait()  // the first stop is inside the teardown, held at stopIO
        let second = background { session.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!second.done.isSet, "the second stop returned while the teardown was still running")
        #expect(!backend.calls.contains("destroyTap 10"))

        gate.release.signal()
        first.finished.wait()
        second.finished.wait()
        #expect(backend.calls.suffix(3) == ["stopIO 20 30", "destroyAggregate 20", "destroyTap 10"])
        #expect(backend.calls.count == created.count + 3)
    }

    @Test func stopDuringStartWaitsForStartAndThenTearsDown() throws {
        let backend = FakeBackend(gating: ["createAggregate"])
        let session = RouteSession(backend: backend, plan: plan)
        let gate = try #require(backend.gates["createAggregate"])

        let starting = background { try? session.start() }
        gate.entered.wait()  // start is held inside createAggregate
        let stopping = background { session.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!stopping.done.isSet, "stop returned while start was still running")

        gate.release.signal()
        starting.finished.wait()
        stopping.finished.wait()
        #expect(
            backend.calls == created + ["stopIO 20 30", "destroyAggregate 20", "destroyTap 10"])
    }

    @Test func startAfterStopFailsAndCreatesNothing() {
        let backend = FakeBackend()
        let session = RouteSession(backend: backend, plan: plan)
        session.stop()
        #expect(throws: RouterError.sessionAlreadyStopped) { try session.start() }
        #expect(backend.calls.isEmpty)
    }

    // MARK: Tap check in the live gate

    /// The live sequence for a buffer that is silent on the source pair: the IO proc flags device
    /// input channel 1 as active, but `render` copies only zeros, so the signal flag stays off. The
    /// wait then ends in `.silent`, never in `.present`.
    @Test func aBufferSilentOnThePairStillGetsTheSpecificWarning() throws {
        let backend = FakeBackend()
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        backend.setActive([0])  // device input 1 active, the tap buffer shows nothing
        #expect(session.signalState(elapsed: 1) == .waiting)
        #expect(session.tapReport(for: .waiting) == nil)
        let state = session.signalState(elapsed: 10)
        #expect(state == .silent)
        let report = try #require(session.tapReport(for: state))
        let warning = try #require(report.warning)
        #expect(warning.contains("no signal on the tap, but on device input channels 1"))
        #expect(warning.contains("--tap-buffer <n>"))
    }

    @Test func aSilentWaitWithNothingActiveHasNoSpecificWarning() throws {
        let backend = FakeBackend()
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        let report = try #require(session.tapReport(for: .silent))
        #expect(report.warning == nil)
    }

    @Test func theSignalPathStillReports() throws {
        let backend = FakeBackend()
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        backend.setSignal(true)
        backend.setActive([32, 33])
        let report = try #require(session.tapReport(for: session.signalState(elapsed: 0)))
        #expect(report.warning == nil)
        session.stop()
        #expect(session.tapReport(for: .present) == nil, "stopped")
    }

    // MARK: Silent wait output, the live flow of run 3

    private func silentOutput(active: [Int]) throws -> TapCheck.SilentWaitOutput {
        let backend = FakeBackend()
        backend.setInfo(FakeBackend.wideInfo)
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        backend.setActive(active)
        #expect(session.signalState(elapsed: 10) == .silent)
        return session.silentWaitOutput()
    }

    /// The app plays on tap channels 3,4 while --source-channels is 1,2: the wait ends silent, the
    /// capture works. The permission hint would name a wrong cause.
    @Test func silentWaitWithAnotherPairActivePrintsTheSpecificWarningOnly() throws {
        let output = try silentOutput(active: [34, 35])
        #expect(output.activity != nil)
        #expect(output.warnings.count == 1)
        #expect(output.warnings[0].contains("signal on tap channels 3,4, outside --source-channels 1,2"))
        #expect(!output.warnings.joined().contains("permission"))
    }

    @Test func silentWaitWithNothingActivePrintsThePermissionWarningOnly() throws {
        let output = try silentOutput(active: [])
        #expect(output.warnings.count == 1)
        #expect(output.warnings[0].contains("no audio arrived in 10 seconds"))
        #expect(output.warnings[0].contains("permission may be missing"))
        #expect(!output.warnings[0].contains("tap buffer"))
    }

    @Test func silentWaitWithOnlyADeviceInputActivePrintsTheSpecificWarningThenTheShortHint() throws {
        let output = try silentOutput(active: [0])
        try #require(output.warnings.count == 2)
        #expect(output.warnings[0].contains("no signal on the tap, but on device input channels 1"))
        #expect(output.warnings[1] == Formatting.permissionHint)
        #expect(!output.warnings.joined().contains("no audio arrived"))
    }

    @Test func theSignalPathNeverPrintsThePermissionHint() throws {
        let backend = FakeBackend()
        backend.setInfo(FakeBackend.wideInfo)
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        backend.setSignal(true)
        backend.setActive([34, 35])
        #expect(session.signalState(elapsed: 0) == .present)
        let report = try #require(session.tapReport(for: .present))
        #expect(report.warning?.contains("outside --source-channels") == true)
        #expect(!(report.warning ?? "").contains("permission"))
    }

    @Test func aStoppedSessionFallsBackToThePermissionWarning() throws {
        let backend = FakeBackend()
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        session.stop()
        let output = session.silentWaitOutput()
        #expect(output.activity == nil)
        #expect(output.warnings.count == 1)
        #expect(output.warnings[0].contains("no audio arrived"))
    }

    // MARK: Silence

    @Test func signalStateFollowsTheBackend() throws {
        let backend = FakeBackend()
        let session = RouteSession(backend: backend, plan: plan)
        #expect(session.signalState(elapsed: 100) == .waiting, "not started yet")
        try session.start()
        #expect(session.signalState(elapsed: 9.9) == .waiting)
        #expect(session.signalState(elapsed: 10) == .silent)
        backend.setSignal(true)
        #expect(session.signalState(elapsed: 100) == .present)
        #expect(session.signalState(elapsed: 0) == .present)
        session.stop()
        #expect(session.signalState(elapsed: 100) == .waiting, "stopped")
    }
}
