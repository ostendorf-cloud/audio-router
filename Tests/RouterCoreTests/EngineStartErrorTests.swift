// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

private let a = EngineSamples.a

private struct OtherError: Error {}

private func transient() -> RouterError {
    RouterError.coreAudio(operation: "AudioHardwareCreateProcessTap (create tap)", status: 1)
}

/// `RouteStatus.startError` carries the typed error of a failed start, so the UI needs no text parsing.
@Suite struct EngineStartErrorTests {
    private func startError(_ rig: EngineRig) -> RouterError? {
        rig.engine.snapshot.status(of: a.id)?.startError
    }

    @Test func aStatusWithoutAFailedStartHasNone() throws {
        let rig = EngineRig()
        try rig.run([a])
        #expect(rig.state(a) == .running(warnings: []))
        #expect(startError(rig) == nil)
        let status = RouteStatus(route: a, state: .waitingForApp, teardownFailures: [])
        #expect(status.startError == nil)
    }

    @Test func aRetryingStartCarriesTheTypedError() throws {
        let rig = EngineRig()
        rig.maker.fail("a", with: [transient()])
        try rig.run([a])
        #expect(startError(rig) == transient())
    }

    @Test func aRefusedStartCarriesTheTypedError() throws {
        let rig = EngineRig()
        let refusal = RouterError.ambiguousTapStream(device: "Mixer", buffers: [2, 2], tapShape: [2])
        rig.maker.fail("a", with: [refusal])
        try rig.run([a])
        #expect(startError(rig) == refusal)
    }

    @Test func exhaustedRetriesCarryTheTypedError() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 2, maxAttempts: 2))
        rig.maker.fail("a", with: [transient(), transient()])
        try rig.run([a])
        rig.advance(seconds: 2)
        guard case .failed(.retriesExhausted) = rig.state(a) else {
            Issue.record("expected retriesExhausted, got \(String(describing: rig.state(a)))")
            return
        }
        #expect(startError(rig) == transient())
    }

    @Test func anErrorOfAnotherTypeLeavesItNil() throws {
        let rig = EngineRig()
        rig.maker.fail("a", with: [OtherError()])
        try rig.run([a])
        guard case .failed = rig.state(a) else {
            Issue.record("expected failed, got \(String(describing: rig.state(a)))")
            return
        }
        #expect(startError(rig) == nil)
    }

    @Test func aSuccessfulStartClearsIt() throws {
        let rig = EngineRig(configuration: EngineConfiguration(retryBase: 1, retryCap: 2, maxAttempts: 5))
        rig.maker.fail("a", with: [transient()])
        try rig.run([a])
        #expect(startError(rig) != nil)
        rig.advance(seconds: 1)
        #expect(rig.state(a) == .running(warnings: []))
        #expect(startError(rig) == nil)
    }

    @Test func retryNowClearsAHeldFailureAndItsError() throws {
        let rig = EngineRig()
        let refusal = RouterError.unsupportedFormat("x")
        rig.maker.fail("a", with: [refusal])
        try rig.run([a])
        #expect(startError(rig) == refusal)
        rig.engine.retryNow(a.id)
        rig.engine.waitUntilIdle()
        #expect(rig.state(a) == .running(warnings: []))
        #expect(startError(rig) == nil)
    }

    @Test func globalOffClearsIt() throws {
        let rig = EngineRig()
        rig.maker.fail("a", with: [RouterError.unsupportedFormat("x")])
        try rig.run([a])
        #expect(startError(rig) != nil)
        rig.engine.setOn(false)
        #expect(rig.state(a) == .disabled)
        #expect(startError(rig) == nil)
    }
}
