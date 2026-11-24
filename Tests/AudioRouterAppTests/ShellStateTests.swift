// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore
import Testing

@testable import AudioRouterAppCore

private let music = ShellSamples.music
private let video = ShellSamples.video

@Suite struct ShellStatusTests {
    @Test func globalOffIsOffWhateverTheRoutesSay() {
        let snapshot = ShellSamples.snapshot(isOn: false, [(music, .failed(.refused(message: "x")))])
        #expect(ShellStatus.of(snapshot) == .off)
    }

    @Test func noRoutesIsRunning() {
        #expect(ShellStatus.of(.empty) == .running)
    }

    @Test func runningRoutesAndWaitingForAppAreRunning() {
        let snapshot = ShellSamples.snapshot([(music, .running(warnings: [])), (video, .waitingForApp)])
        #expect(ShellStatus.of(snapshot) == .running)
    }

    @Test func aWarningOnARunningRouteIsWarning() {
        let snapshot = ShellSamples.snapshot([
            (music, .running(warnings: [.tapCheck("t")])), (video, .running(warnings: [])),
        ])
        #expect(ShellStatus.of(snapshot) == .warning)
    }

    @Test func waitingForTheDeviceIsWarning() {
        #expect(ShellStatus.of(ShellSamples.snapshot([(music, .waitingForDevice)])) == .warning)
    }

    @Test func aFailedRouteIsErrorAndBeatsWarnings() {
        let snapshot = ShellSamples.snapshot([
            (music, .running(warnings: [.tapCheck("t")])),
            (video, .failed(.retriesExhausted(message: "m", attempts: 3))),
        ])
        #expect(ShellStatus.of(snapshot) == .error)
    }

    @Test func aFailedRouteBeatsWaitingForTheDevice() {
        let failed = (video, RouteState.failed(.refused(message: "x")))
        #expect(ShellStatus.of(ShellSamples.snapshot([(music, .waitingForDevice), failed])) == .error)
        #expect(ShellStatus.of(ShellSamples.snapshot([failed, (music, .waitingForDevice)])) == .error)
    }

    @Test func aFailedRouteListedAfterAWarningRouteIsStillError() {
        let snapshot = ShellSamples.snapshot([
            (music, .running(warnings: [.tapCheck("t")])), (video, .failed(.refused(message: "x"))),
        ])
        #expect(ShellStatus.of(snapshot) == .error)
    }

    @Test func aSwitchedOffRouteDoesNotCount() {
        var off = video
        off.enabled = false
        let snapshot = ShellSamples.snapshot([(off, .failed(.refused(message: "x")))])
        #expect(ShellStatus.of(snapshot) == .running)
    }

    @Test func aFailedEngineStartIsError() {
        #expect(ShellStatus.of(.empty, startFailed: true) == .error)
    }

    @Test func globalOffBeatsAFailedEngineStart() {
        let snapshot = ShellSamples.snapshot(isOn: false, [])
        #expect(ShellStatus.of(snapshot, startFailed: true) == .off)
    }

    @Test func everyStatusHasADistinctSymbol() {
        let all: [ShellStatus] = [.off, .running, .warning, .error]
        #expect(Set(all.map(\.symbolName)).count == 4)
    }

    @Test func rowStatesMapFromRouteStates() {
        #expect(ShellRowState.of(.disabled) == .disabled)
        #expect(ShellRowState.of(.starting) == .starting)
        #expect(ShellRowState.of(.running(warnings: [])) == .running)
        #expect(ShellRowState.of(.running(warnings: [.noSignal([])])) == .warning)
        #expect(ShellRowState.of(.failed(.refused(message: "x"))) == .failed)
    }
}

@Suite struct ShellAboutTests {
    @Test func usesTheBundleVersion() {
        #expect(ShellAbout.version(info: ["CFBundleShortVersionString": "1.2.3"]) == "1.2.3")
    }

    @Test func fallsBackWithoutABundleVersion() {
        #expect(ShellAbout.version(info: nil) == ShellAbout.developmentVersion)
        #expect(ShellAbout.version(info: [:]) == ShellAbout.developmentVersion)
        #expect(ShellAbout.version(info: ["CFBundleShortVersionString": ""]) == ShellAbout.developmentVersion)
    }
}
