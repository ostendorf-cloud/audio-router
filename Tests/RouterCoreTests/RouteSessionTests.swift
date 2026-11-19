// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RouterCore

struct RouteSessionTests {
    private let plan = RoutePlan(
        device: Samples.device,
        channels: ChannelPair(first: 3),
        appBundleID: "com.google.Chrome",
        processes: [Samples.process(1, "com.google.Chrome"), Samples.process(2, "com.google.Chrome.helper")],
    )

    private let created = [
        "createTap 1,2", "createAggregate mixer-uid tap-uid", "startIO 20 3,4",
    ]

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
}
