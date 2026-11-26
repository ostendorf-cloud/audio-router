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

    @Test func everyStatusHasADistinctImage() {
        let all: [ShellStatus] = [.off, .running, .warning, .error]
        #expect(Set(all.map(\.imageName)).count == 4)
    }

    /// `scripts/bundle.sh` copies these files into the app. A renamed status or a missing render fails here.
    @Test(arguments: [ShellStatus.off, .running, .warning, .error])
    func everyStatusImageExistsAtOneAndTwoTimes(status: ShellStatus) {
        let branding = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Branding")
            .standardizedFileURL
        for file in ["\(status.imageName).png", "\(status.imageName)@2x.png", "\(status.imageName).svg"] {
            let path = branding.appendingPathComponent(file).path
            #expect(FileManager.default.fileExists(atPath: path), "missing \(path)")
        }
    }

    @Test func rowStatesMapFromRouteStates() {
        func row(_ state: RouteState) -> ShellRowState {
            let snapshot = ShellSamples.snapshot([(music, state)])
            return ShellRowState.of(snapshot.routes[0], in: snapshot)
        }
        #expect(row(.disabled) == .disabled)
        #expect(row(.starting) == .starting)
        #expect(row(.waitingForApp) == .waitingForApp)
        #expect(row(.waitingForDevice) == .waitingForDevice)
        #expect(row(.running(warnings: [])) == .running)
        #expect(row(.running(warnings: [.tapCheck("t")])) == .warning)
        #expect(row(.running(warnings: [.sampleRateMismatch(tap: 1, device: 2)])) == .warning)
        // The sample snapshot lists no app, so the app plays nothing: likely paused, not a warning.
        #expect(row(.running(warnings: [.noSignal([])])) == .running)
        #expect(row(.failed(.refused(message: "x"))) == .failed)
    }
}

@Suite struct ShellAboutTests {
    @Test func usesTheBundleVersion() {
        #expect(ShellAbout.version(info: ["ARFullVersion": "1.2.3"]) == "1.2.3")
    }

    @Test func showsTheFullPreReleaseVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "ARFullVersion": "0.1.0-rc.2"]
        #expect(ShellAbout.version(info: info) == "0.1.0-rc.2")
    }

    @Test func ignoresTheAppleVersionKeys() {
        #expect(ShellAbout.version(info: ["CFBundleShortVersionString": "0.1.0"]) == ShellAbout.developmentVersion)
    }

    @Test func fallsBackWithoutABundleVersion() {
        #expect(ShellAbout.version(info: nil) == ShellAbout.developmentVersion)
        #expect(ShellAbout.version(info: [:]) == ShellAbout.developmentVersion)
        #expect(ShellAbout.version(info: ["ARFullVersion": ""]) == ShellAbout.developmentVersion)
    }
}
