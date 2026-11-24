// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore
import Testing

@testable import AudioRouterAppCore

// MARK: - Fixtures

private let music = ShellSamples.music
private let routeID = music.id

private func device(alive: Bool = true, isDefault: Bool = true) -> DeviceInfo {
    DeviceInfo(
        uid: "dev", name: "X32", outputChannelsPerStream: [32], nominalSampleRate: 48000, isAlive: alive,
        isDefaultOutput: isDefault)
}

private func app(playing: Bool) -> AppGroup {
    AppGroup(
        bundleID: music.appBundleID,
        processes: [AudioProcess(objectID: 1, pid: 10, bundleID: music.appBundleID, isRunningOutput: playing)])
}

private func snapshot(
    _ state: RouteState, devices: [DeviceInfo] = [device()], apps: [AppGroup] = [app(playing: true)],
    teardown: [String] = []
) -> EngineSnapshot {
    EngineSnapshot(
        isOn: true,
        routes: [RouteStatus(route: music, state: state, meter: nil, teardownFailures: teardown)],
        devices: devices, apps: apps)
}

private func issues(of snapshot: EngineSnapshot) -> [RouteIssue] {
    RouteIssues.of(snapshot.routes[0], in: snapshot)
}

private let permissionText = "AudioHardwareCreateProcessTap (create tap) failed with OSStatus 560947818 (!hog)."
private let ambiguousText =
    "Cannot tell the tap from the input channels of X32: input buffers are [32, 2], the tap is [2]."

private struct Fixture {
    let name: String
    let snapshot: EngineSnapshot
    let issues: [RouteIssue]

    init(_ name: String, _ snapshot: EngineSnapshot) {
        self.name = name
        self.snapshot = snapshot
        issues = RouteIssues.of(snapshot.routes[0], in: snapshot)
    }
}

private func fixtures() -> [Fixture] {
    let other = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    var list = [
        Fixture("waitingForApp", snapshot(.waitingForApp)),
        Fixture("waitingForDevice, device gone", snapshot(.waitingForDevice, devices: [])),
        Fixture("waitingForDevice, not alive", snapshot(.waitingForDevice, devices: [device(alive: false)])),
        Fixture("waitingForDevice, not default", snapshot(.waitingForDevice, devices: [device(isDefault: false)])),
        Fixture("waitingForDevice, back", snapshot(.waitingForDevice)),
        Fixture("noSignal, app plays", snapshot(.running(warnings: [.noSignal(["warning: no audio arrived"])]))),
        Fixture(
            "noSignal, app silent",
            snapshot(.running(warnings: [.noSignal(["warning: no audio arrived"])]), apps: [app(playing: false)])),
        Fixture(
            "noSignal, tap check text",
            snapshot(.running(warnings: [.noSignal(["warning: tap buffer 1 was picked by stream id diff: x"])]))),
        Fixture("tapCheck", snapshot(.running(warnings: [.tapCheck("warning: tap buffer 1 was picked: x")]))),
        Fixture(
            "sampleRateMismatch", snapshot(.running(warnings: [.sampleRateMismatch(tap: 44100, device: 48000)]))),
        Fixture(
            "startFailed, other",
            snapshot(.failed(.startFailed(message: "boom", attempt: 2, retryIn: 1.5)))),
        Fixture(
            "startFailed, permission text",
            snapshot(.failed(.startFailed(message: permissionText, attempt: 1, retryIn: 1)))),
        Fixture("refused, ambiguous tap", snapshot(.failed(.refused(message: ambiguousText)))),
        Fixture("refused, other", snapshot(.failed(.refused(message: "Unsupported audio format: x")))),
        Fixture(
            "refused, app gone",
            snapshot(.failed(.refused(message: "No audio process with bundle id com.example.music. Start it.")))),
        Fixture(
            "refused, device unknown",
            snapshot(.failed(.refused(message: "No output device with uid dev. Run the devices command.")))),
        Fixture(
            "refused, channels",
            snapshot(.failed(.refused(message: "Channels 3,4 do not fit: X32 has 2 output channels.")))),
        Fixture(
            "retriesExhausted, permission text",
            snapshot(.failed(.retriesExhausted(message: permissionText, attempts: 8)))),
        Fixture("retriesExhausted, other", snapshot(.failed(.retriesExhausted(message: "boom", attempts: 8)))),
        Fixture(
            "validation",
            snapshot(
                .failed(
                    .validation([
                        .emptyBundleID(route: routeID), .unknownDevice(route: routeID, uid: "dev"),
                        .pairOutOfRange(route: routeID, first: 5, deviceChannels: 4),
                        .duplicateDestinationPair(route: routeID, first: 3, other: other, otherFirst: 4, uid: "dev"),
                        .duplicateRouteID(route: routeID),
                    ])))),
        Fixture("teardown failures", snapshot(.running(warnings: []), teardown: ["remove tap", "remove aggregate"])),
        Fixture("teardown failure, one", snapshot(.waitingForApp, teardown: ["remove tap"])),
    ]
    list.append(
        Fixture(
            "two warnings",
            snapshot(
                .running(warnings: [
                    .sampleRateMismatch(tap: 44100, device: 48000), .tapCheck("warning: tap buffer 1 x"),
                ]))))
    return list
}

/// One line per issue: fixture, kind, severity, action, message.
private func table() -> String {
    var lines = fixtures().flatMap { fixture in
        fixture.issues.map {
            "\(fixture.name) | \($0.kind.rawValue) | \($0.severity) | \($0.action) | \($0.message)"
        }
    }
    let engine = RouteIssues.engineStartFailure("boom")
    lines.append(
        "engine start failed | \(engine.kind.rawValue) | \(engine.severity) | \(engine.action) | \(engine.message)")
    return lines.joined(separator: "\n") + "\n"
}

private func golden(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Errors").appendingPathComponent("Golden").appendingPathComponent(name)
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Messages

@Suite struct ErrorsMessageTests {
    @Test func everyMessageMatchesTheGoldenFile() throws {
        let actual = table()
        let expected = try golden("messages.txt")
        #expect(actual == expected, "actual table:\n\(actual)")
    }

    @Test func everyKindHasAFixture() {
        var seen = Set(fixtures().flatMap(\.issues).map(\.kind))
        seen.insert(RouteIssues.engineStartFailure("x").kind)
        #expect(seen == Set(RouteIssueKind.allCases))
    }

    @Test func inferredCausesSayLikely() {
        let inferred: Set<RouteIssueKind> = [
            .permissionSilence, .permissionStartFailed, .appNotPlaying, .deviceGone, .deviceNotResponding,
            .deviceNotDefault, .sampleRateMismatch, .tapChannelMismatch, .teardownLeftovers,
        ]
        for fixture in fixtures() {
            for issue in fixture.issues where inferred.contains(issue.kind) {
                #expect(issue.message.lowercased().contains("likely"), "\(fixture.name): \(issue.message)")
            }
        }
    }

    @Test func noMessageIsEmptyAndTheDetailStaysOutOfIt() {
        for fixture in fixtures() {
            for issue in fixture.issues {
                #expect(!issue.message.isEmpty)
                if let detail = issue.detail { #expect(!issue.message.contains(detail)) }
            }
        }
    }

    @Test func deviceLossNamesWhichCause() {
        let kinds = fixtures().filter { $0.name.hasPrefix("waitingForDevice") }.map { $0.issues[0].kind }
        #expect(kinds == [.deviceGone, .deviceNotResponding, .deviceNotDefault, .deviceReturning])
    }

    @Test func permissionActionsOpenTheSettings() {
        for fixture in fixtures() {
            for issue in fixture.issues
            where issue.kind == .permissionSilence || issue.kind == .permissionStartFailed {
                #expect(issue.action == .openAudioCaptureSettings, "\(fixture.name)")
            }
        }
    }

    @Test func failedStartsOfRetryableCausesOfferRetry() {
        let retry = fixtures().filter { $0.name == "startFailed, other" || $0.name == "retriesExhausted, other" }
        #expect(retry.flatMap(\.issues).allSatisfy { $0.action == .retry })
    }

    @Test func aDisabledRouteAndGlobalOffShowNothing() {
        var off = music
        off.enabled = false
        let failed = RouteState.failed(.refused(message: "x"))
        let disabled = EngineSnapshot(
            isOn: true, routes: [RouteStatus(route: off, state: failed, meter: nil, teardownFailures: [])],
            devices: [], apps: [])
        #expect(RouteIssues.of(disabled.routes[0], in: disabled).isEmpty)
        let globalOff = EngineSnapshot(
            isOn: false, routes: [RouteStatus(route: music, state: failed, meter: nil, teardownFailures: [])],
            devices: [], apps: [])
        #expect(RouteIssues.of(globalOff.routes[0], in: globalOff).isEmpty)
    }
}

// MARK: - Mapping coverage

private let routerErrorLabels = [
    "usage", "unknownDevice", "channelsOutOfRange", "noMatchingProcess", "coreAudio", "unsupportedFormat",
    "ambiguousTapStream", "unprovableTapOrder", "refusedWithDiff", "sessionAlreadyStopped", "teardownFailed",
]

/// Exhaustive on purpose: a new `RouterError` case does not compile until it is listed here.
private func label(_ error: RouterError) -> String {
    switch error {
    case .usage: "usage"
    case .unknownDevice: "unknownDevice"
    case .channelsOutOfRange: "channelsOutOfRange"
    case .noMatchingProcess: "noMatchingProcess"
    case .coreAudio: "coreAudio"
    case .unsupportedFormat: "unsupportedFormat"
    case .ambiguousTapStream: "ambiguousTapStream"
    case .unprovableTapOrder: "unprovableTapOrder"
    case .refusedWithDiff: "refusedWithDiff"
    case .sessionAlreadyStopped: "sessionAlreadyStopped"
    case .teardownFailed: "teardownFailed"
    }
}

private let routerErrors: [RouterError] = [
    .usage("bad"), .unknownDevice(uid: "dev"), .channelsOutOfRange(first: 3, deviceChannels: 2, deviceName: "X32"),
    .noMatchingProcess(bundleID: "com.example.music"),
    .coreAudio(operation: "AudioHardwareCreateProcessTap (create tap)", status: 560_947_818),
    .coreAudio(operation: "AudioDeviceStart (start IO)", status: -50),
    .coreAudio(operation: "AudioHardwareCreateAggregateDevice (create aggregate)", status: -50),
    .unsupportedFormat("x"),
    .ambiguousTapStream(device: "X32", buffers: [32, 2], tapShape: [2]),
    .unprovableTapOrder(device: "X32", buffers: [2, 2], tapShape: [2]),
    .refusedWithDiff(
        reason: "\(RouterError.ambiguousTapStream(device: "X32", buffers: [2, 2], tapShape: [2]))",
        diff: "no new stream"),
    .sessionAlreadyStopped, .teardownFailed(["a", "b"]),
]

/// Exhaustive on purpose, see `label`.
private func expectsIssue(_ state: RouteState) -> Bool {
    switch state {
    case .disabled, .starting: false
    case .running(let warnings): !warnings.isEmpty
    case .waitingForDevice, .waitingForApp, .failed: true
    }
}

private func failureSamples(_ failure: RouteFailure) -> RouteFailure {
    switch failure {
    case .validation, .startFailed, .refused, .retriesExhausted: failure
    }
}

private func warningSamples(_ warning: RouteWarning) -> RouteWarning {
    switch warning {
    case .noSignal, .tapCheck, .sampleRateMismatch: warning
    }
}

@Suite struct ErrorsCoverageTests {
    @Test func everyRouterErrorCaseHasASample() {
        #expect(Set(routerErrors.map(label)) == Set(routerErrorLabels))
    }

    @Test func theTextOfEveryRouterErrorMapsToTheKindOfTheError() {
        for error in routerErrors {
            #expect(
                RouteIssues.kind(ofFailureMessage: "\(error)") == RouteIssues.kind(of: error),
                "\(label(error)): \(error)")
        }
    }

    @Test func routerErrorKinds() {
        #expect(RouteIssues.kind(of: .coreAudio(operation: "x (create tap)", status: 1)) == .permissionStartFailed)
        #expect(RouteIssues.kind(of: .coreAudio(operation: "x (start IO)", status: 1)) == .startFailed)
        let ambiguous = RouterError.ambiguousTapStream(device: "d", buffers: [], tapShape: [])
        let unprovable = RouterError.unprovableTapOrder(device: "d", buffers: [], tapShape: [])
        #expect(RouteIssues.kind(of: ambiguous) == .ambiguousTapBuffer)
        #expect(RouteIssues.kind(of: unprovable) == .ambiguousTapBuffer)
        #expect(RouteIssues.kind(of: .noMatchingProcess(bundleID: "a")) == .appNotRunning)
    }

    @Test func everyEngineStateShowsAnIssueOrIsQuiet() {
        let states: [RouteState] = [
            .disabled, .starting, .waitingForDevice, .waitingForApp, .running(warnings: []),
            .running(warnings: [.noSignal(["x"])]), .running(warnings: [.tapCheck("x")]),
            .running(warnings: [.sampleRateMismatch(tap: 1, device: 2)]),
            .failed(.validation([.emptyBundleID(route: routeID)])),
            .failed(.startFailed(message: "x", attempt: 1, retryIn: 1)), .failed(.refused(message: "x")),
            .failed(.retriesExhausted(message: "x", attempts: 3)),
        ]
        for state in states {
            let shot = snapshot(state)
            #expect(issues(of: shot).isEmpty == !expectsIssue(state), "\(state)")
            if case .failed(let failure) = state { _ = failureSamples(failure) }
            if case .running(let warnings) = state {
                for warning in warnings { _ = warningSamples(warning) }
            }
        }
    }

    @Test func everyActionHasATitleExceptNone() {
        for action in RouteAction.allCases {
            #expect((action.title == nil) == (action == .none), "\(action)")
        }
    }
}

// MARK: - Worst state

@Suite struct ErrorsWorstStateTests {
    @Test func theWorstIssueMatchesTheMenuBarIcon() {
        for fixture in fixtures() {
            let worst = fixture.issues.map(\.severity).max()
            #expect(
                (worst?.shellStatus ?? .running) == ShellStatus.of(fixture.snapshot),
                "\(fixture.name)")
        }
    }

    @Test func aFailedEngineStartIsTheWorst() {
        let quiet = snapshot(.running(warnings: []))
        #expect(RouteIssues.worstSeverity(quiet) == nil)
        #expect(RouteIssues.worstSeverity(quiet, startFailure: "x") == .error)
        #expect(ShellStatus.of(quiet, startFailed: true) == .error)
    }

    @Test func offBeatsEverything() {
        let off = EngineSnapshot(
            isOn: false,
            routes: [
                RouteStatus(route: music, state: .failed(.refused(message: "x")), meter: nil, teardownFailures: ["t"])
            ], devices: [], apps: [])
        #expect(ShellStatus.of(off, startFailed: true) == .off)
        #expect(RouteIssues.worstSeverity(off) == nil)
    }

    @Test func aFailedTeardownIsAWarningOnTheIcon() {
        #expect(ShellStatus.of(snapshot(.running(warnings: []), teardown: ["t"])) == .warning)
        #expect(ShellStatus.of(snapshot(.failed(.refused(message: "x")), teardown: ["t"])) == .error)
    }

    @Test func severityOrder() {
        #expect(IssueSeverity.info < .warning)
        #expect(IssueSeverity.warning < .error)
    }
}

// MARK: - Actions

private final class FakeOpener: SettingsOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []
    var urls: [URL] { lock.withLock { opened } }
    func open(_ url: URL) { lock.withLock { opened.append(url) } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var all: [String] { lock.withLock { events } }
    func add(_ event: String) { lock.withLock { events.append(event) } }
}

@MainActor private func makeModel(_ engine: FakeShellEngine) -> ShellViewModel {
    ShellViewModel(engine: engine, offMain: { $0() }, mainHop: { work in Task { @MainActor in work() } })
}

@Suite struct ErrorsActionTests {
    private func runner(_ opener: FakeOpener, _ recorder: Recorder) -> IssueActionRunner {
        IssueActionRunner(
            opener: opener, retry: { recorder.add("retry \($0?.uuidString ?? "engine")") },
            chooseDevice: { recorder.add("chooseDevice") })
    }

    @Test func theSettingsActionOpensThePrivacyPane() {
        let opener = FakeOpener()
        runner(opener, Recorder()).perform(.openAudioCaptureSettings, routeID: routeID)
        #expect(opener.urls == [ErrorsSettings.audioCapturePane])
        #expect(
            ErrorsSettings.audioCapturePane.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy")
    }

    @Test func retryPassesTheRouteOrNilForTheEngine() {
        let recorder = Recorder()
        let run = runner(FakeOpener(), recorder)
        run.perform(.retry, routeID: routeID)
        run.perform(.retry, routeID: nil)
        #expect(recorder.all == ["retry \(routeID.uuidString)", "retry engine"])
    }

    @Test func chooseDeviceAndNoneDoNotOpenSettings() {
        let opener = FakeOpener()
        let recorder = Recorder()
        let run = runner(opener, recorder)
        run.perform(.chooseDevice, routeID: routeID)
        run.perform(.none, routeID: routeID)
        #expect(recorder.all == ["chooseDevice"])
        #expect(opener.urls.isEmpty)
    }

    @MainActor @Test func theViewModelRetriesTheRouteThroughTheEngine() {
        let engine = FakeShellEngine(snapshot: snapshot(.failed(.refused(message: "x"))))
        let model = makeModel(engine)
        model.retry(routeID: routeID)
        #expect(engine.calls == ["retryNow(\(routeID.uuidString))"])
    }

    @MainActor @Test func theViewModelOffersTheIssuesOfARoute() {
        let engine = FakeShellEngine(snapshot: snapshot(.failed(.refused(message: ambiguousText))))
        let model = makeModel(engine)
        #expect(model.issues(for: routeID).map(\.kind) == [.ambiguousTapBuffer])
        #expect(model.issues(for: UUID()).isEmpty)
        #expect(model.engineIssue == nil)
    }
}
