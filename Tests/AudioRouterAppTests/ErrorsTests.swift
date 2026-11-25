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
    teardown: [String] = [], startError: RouterError? = nil, enabled: Bool = true
) -> EngineSnapshot {
    var route = music
    route.enabled = enabled
    return EngineSnapshot(
        isOn: true,
        routes: [
            RouteStatus(
                route: route, state: state, teardownFailures: teardown, startError: startError)
        ],
        devices: devices, apps: apps)
}

/// The real texts of the tap check, so a reworded check fails the tests.
private func tapCheckText(tap: [Int], device: [Int]) -> String {
    TapCheck.warning(
        tap: tap, device: device, source: .firstPair, buffer: 1, choice: .streamDiff) ?? "no warning"
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
        Fixture("teardown failure, route off", snapshot(.disabled, teardown: ["remove tap"], enabled: false)),
        Fixture(
            "noSignal, tap silent next to device input",
            snapshot(.running(warnings: [.noSignal([tapCheckText(tap: [], device: [3]), "short hint"])]))),
        Fixture(
            "noSignal, signal outside source",
            snapshot(.running(warnings: [.noSignal([tapCheckText(tap: [3], device: [])])]))),
        Fixture(
            "tapCheck, tap silent next to device input",
            snapshot(.running(warnings: [.tapCheck(tapCheckText(tap: [], device: [3]))]))),
        Fixture(
            "tapCheck, signal outside source",
            snapshot(.running(warnings: [.tapCheck(tapCheckText(tap: [3], device: []))]))),
        Fixture(
            "typed error beats the text",
            snapshot(
                .failed(.refused(message: "some other text")),
                startError: .coreAudio(operation: "AudioHardwareCreateProcessTap (create tap)", status: 1))),
        Fixture(
            "usage text that looks like a tap refusal",
            snapshot(
                .failed(.refused(message: "Cannot tell the tap from the input channels of X32 (usage text)")),
                startError: .usage("Cannot tell the tap from the input channels of X32 (usage text)"))),
        Fixture(
            "refusedWithDiff, unsupported format",
            snapshot(
                .failed(.refused(message: "Unsupported audio format: x\nno new stream")),
                startError: .refusedWithDiff(reason: "Unsupported audio format: x", diff: "no new stream"))),
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
            .permissionSilence, .appNotPlaying, .deviceGone, .deviceNotResponding, .deviceNotDefault,
            .sampleRateMismatch, .tapChannelMismatch, .tapSilentDeviceActive, .teardownLeftovers,
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
            isOn: true, routes: [RouteStatus(route: off, state: failed, teardownFailures: [])],
            devices: [], apps: [])
        #expect(RouteIssues.of(disabled.routes[0], in: disabled).isEmpty)
        let globalOff = EngineSnapshot(
            isOn: false, routes: [RouteStatus(route: music, state: failed, teardownFailures: [])],
            devices: [], apps: [])
        #expect(RouteIssues.of(globalOff.routes[0], in: globalOff).isEmpty)
    }
}

// MARK: - Mapping coverage

/// One value per `RouterError` case. `CaseIterable` drives the samples, and two exhaustive switches keep
/// both sides complete: `shapeOf` stops compiling for a new `RouterError` case, `samples(for:)` for a
/// new shape. So no case can lack samples.
private enum ErrorShape: CaseIterable {
    case usage, unknownDevice, channelsOutOfRange, noMatchingProcess, coreAudio, unsupportedFormat
    case ambiguousTapStream, unprovableTapOrder, refusedWithDiff, sessionAlreadyStopped, teardownFailed
}

private func shapeOf(_ error: RouterError) -> ErrorShape {
    switch error {
    case .usage: .usage
    case .unknownDevice: .unknownDevice
    case .channelsOutOfRange: .channelsOutOfRange
    case .noMatchingProcess: .noMatchingProcess
    case .coreAudio: .coreAudio
    case .unsupportedFormat: .unsupportedFormat
    case .ambiguousTapStream: .ambiguousTapStream
    case .unprovableTapOrder: .unprovableTapOrder
    case .refusedWithDiff: .refusedWithDiff
    case .sessionAlreadyStopped: .sessionAlreadyStopped
    case .teardownFailed: .teardownFailed
    }
}

private let ambiguousSample = RouterError.ambiguousTapStream(device: "X32", buffers: [32, 2], tapShape: [2])
private let unprovableSample = RouterError.unprovableTapOrder(device: "X32", buffers: [2, 2], tapShape: [2])
private let unsupportedSample = RouterError.unsupportedFormat("no input buffer of the aggregate device")

private func samples(for shape: ErrorShape) -> [RouterError] {
    switch shape {
    case .usage: [.usage("bad")]
    case .unknownDevice: [.unknownDevice(uid: "dev")]
    case .channelsOutOfRange: [.channelsOutOfRange(first: 3, deviceChannels: 2, deviceName: "X32")]
    case .noMatchingProcess: [.noMatchingProcess(bundleID: "com.example.music")]
    case .coreAudio:
        [
            .coreAudio(operation: "AudioHardwareCreateProcessTap (create tap)", status: 560_947_818),
            .coreAudio(operation: "AudioDeviceStart (start IO)", status: -50),
            .coreAudio(operation: "AudioHardwareCreateAggregateDevice (create aggregate)", status: -50),
        ]
    case .unsupportedFormat: [unsupportedSample]
    case .ambiguousTapStream: [ambiguousSample]
    case .unprovableTapOrder: [unprovableSample]
    case .refusedWithDiff:
        // The reason is the text of any error `chooseTapBuffers` throws (CoreAudioRoutingBackend).
        [ambiguousSample, unprovableSample, unsupportedSample].map {
            .refusedWithDiff(reason: "\($0)", diff: "no new stream")
        }
    case .sessionAlreadyStopped: [.sessionAlreadyStopped]
    case .teardownFailed: [.teardownFailed(["a", "b"])]
    }
}

private let routerErrors: [RouterError] = ErrorShape.allCases.flatMap(samples(for:))

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
        for shape in ErrorShape.allCases {
            let list = samples(for: shape)
            #expect(!list.isEmpty, "\(shape)")
            #expect(list.allSatisfy { shapeOf($0) == shape }, "\(shape)")
        }
    }

    @Test func theTextOfEveryRouterErrorMapsToTheKindOfTheError() {
        for error in routerErrors {
            #expect(
                RouteIssues.kind(ofFailureMessage: "\(error)") == RouteIssues.kind(of: error), "\(error)")
        }
    }

    @Test func aRefusalWithDiffTakesTheKindOfItsReason() {
        #expect(RouteIssues.kind(of: .refusedWithDiff(reason: "\(ambiguousSample)", diff: "d")) == .ambiguousTapBuffer)
        #expect(RouteIssues.kind(of: .refusedWithDiff(reason: "\(unprovableSample)", diff: "d")) == .ambiguousTapBuffer)
        #expect(RouteIssues.kind(of: .refusedWithDiff(reason: "\(unsupportedSample)", diff: "d")) == .startFailed)
    }

    @Test func theTypedErrorOfAStatusDecidesTheKind() {
        // The text says tap refusal, the typed error says usage: the typed error wins.
        let text = "Cannot tell the tap from the input channels of X32 (usage text)"
        let shot = snapshot(.failed(.refused(message: text)), startError: .usage(text))
        #expect(issues(of: shot).map(\.kind) == [.startFailed])
        // Without a typed error the text decides.
        let untyped = snapshot(.failed(.refused(message: text)))
        #expect(issues(of: untyped).map(\.kind) == [.ambiguousTapBuffer])
    }

    @Test func theTextsOfTheTapCheckMapToTheirKinds() {
        func kind(_ warning: RouteWarning) -> RouteIssueKind? {
            issues(of: snapshot(.running(warnings: [warning]))).first?.kind
        }
        let silent = tapCheckText(tap: [], device: [3])
        let outside = tapCheckText(tap: [3], device: [])
        #expect(kind(.noSignal([silent])) == .tapSilentDeviceActive)
        #expect(kind(.noSignal([outside])) == .tapChannelMismatch)
        #expect(kind(.tapCheck(silent)) == .tapSilentDeviceActive)
        #expect(kind(.tapCheck(outside)) == .tapChannelMismatch)
    }

    @Test func aSilentTapAfterASilentWaitKeepsThePermissionHint() {
        let silent = tapCheckText(tap: [], device: [3])
        let shot = snapshot(.running(warnings: [.noSignal([silent])]))
        let issue = issues(of: shot)[0]
        #expect(issue.action == .openAudioCaptureSettings)
        #expect(issue.message.contains("permission may be missing"))
        // After a first signal capture worked, so no permission hint.
        let after = issues(of: snapshot(.running(warnings: [.tapCheck(silent)])))[0]
        #expect(after.action == .none)
        #expect(!after.message.contains("permission"))
    }

    @Test func theStartFailedPermissionTextOnlySaysMay() {
        let shot = snapshot(
            .failed(.refused(message: "x")),
            startError: .coreAudio(operation: "AudioHardwareCreateProcessTap (create tap)", status: 1))
        let issue = issues(of: shot)[0]
        #expect(issue.kind == .permissionStartFailed)
        #expect(issue.message.contains("may be missing"))
        #expect(!issue.message.lowercased().contains("likely"))
    }

    @Test func aFailedTeardownOfASwitchedOffRouteShowsAndWarns() {
        let shot = snapshot(.disabled, teardown: ["remove tap"], enabled: false)
        #expect(issues(of: shot).map(\.kind) == [.teardownLeftovers])
        #expect(ShellStatus.of(shot) == .warning)
        #expect(RouteIssues.worstSeverity(shot) == .warning)
    }

    @Test func aSwitchedOffRouteWithoutATeardownFailureShowsNothing() {
        let shot = snapshot(.failed(.refused(message: "x")), enabled: false)
        #expect(issues(of: shot).isEmpty)
        #expect(ShellStatus.of(shot) == .running)
    }

    @Test func globalOffHidesATeardownFailureOfASwitchedOffRoute() {
        let on = snapshot(.disabled, teardown: ["remove tap"], enabled: false)
        let off = EngineSnapshot(isOn: false, routes: on.routes, devices: [], apps: [])
        #expect(ShellStatus.of(off) == .off)
        #expect(issues(of: off).isEmpty)
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

/// The icon of every fixture, written out so the derivation in `ShellStatus.of` cannot hide a change.
/// Issue 61 changed one line only: a silent app that does not play keeps the icon at `running`.
private let expectedIcons: [String: ShellStatus] = [
    "waitingForApp": .running,
    "waitingForDevice, device gone": .warning,
    "waitingForDevice, not alive": .warning,
    "waitingForDevice, not default": .warning,
    "waitingForDevice, back": .warning,
    "noSignal, app plays": .warning,
    "noSignal, app silent": .running,
    "noSignal, tap check text": .warning,
    "tapCheck": .warning,
    "sampleRateMismatch": .warning,
    "startFailed, other": .error,
    "startFailed, permission text": .error,
    "refused, ambiguous tap": .error,
    "refused, other": .error,
    "refused, app gone": .error,
    "refused, device unknown": .error,
    "refused, channels": .error,
    "retriesExhausted, permission text": .error,
    "retriesExhausted, other": .error,
    "validation": .error,
    "teardown failures": .warning,
    "teardown failure, one": .warning,
    "teardown failure, route off": .warning,
    "noSignal, tap silent next to device input": .warning,
    "noSignal, signal outside source": .warning,
    "tapCheck, tap silent next to device input": .warning,
    "tapCheck, signal outside source": .warning,
    "typed error beats the text": .error,
    "usage text that looks like a tap refusal": .error,
    "refusedWithDiff, unsupported format": .error,
    "two warnings": .warning,
]

@Suite struct ErrorsWorstStateTests {
    @Test func theWorstIssueMatchesTheMenuBarIcon() {
        for fixture in fixtures() {
            let worst = fixture.issues.map(\.severity).max()
            #expect(
                (worst?.shellStatus ?? .running) == ShellStatus.of(fixture.snapshot),
                "\(fixture.name)")
        }
    }

    @Test func everyFixtureHasItsIconWrittenOut() {
        let names = fixtures().map(\.name)
        #expect(Set(names) == Set(expectedIcons.keys))
        for fixture in fixtures() {
            #expect(ShellStatus.of(fixture.snapshot) == expectedIcons[fixture.name], "\(fixture.name)")
        }
    }

    @Test func aFailedEngineStartIsTheWorst() {
        let quiet = snapshot(.running(warnings: []))
        #expect(RouteIssues.worstSeverity(quiet) == nil)
        #expect(RouteIssues.worstSeverity(quiet, startFailed: true) == .error)
        #expect(ShellStatus.of(quiet, startFailed: true) == .error)
    }

    @Test func offBeatsEverything() {
        let off = EngineSnapshot(
            isOn: false,
            routes: [
                RouteStatus(route: music, state: .failed(.refused(message: "x")), teardownFailures: ["t"])
            ], devices: [], apps: [])
        #expect(ShellStatus.of(off, startFailed: true) == .off)
        #expect(RouteIssues.worstSeverity(off) == nil)
    }

    @Test func aPausedAppKeepsTheIconRunningAndASilentPlayingAppWarns() {
        let silence = RouteState.running(warnings: [.noSignal(["warning: no audio arrived"])])
        let paused = snapshot(silence, apps: [app(playing: false)])
        #expect(issues(of: paused).map(\.severity) == [.info])
        #expect(ShellStatus.of(paused) == .running)
        #expect(ShellRowState.of(paused.routes[0], in: paused) == .running)
        // An app without any process in the snapshot plays nothing either.
        let gone = snapshot(silence, apps: [])
        #expect(ShellStatus.of(gone) == .running)
        let playing = snapshot(silence, apps: [app(playing: true)])
        #expect(issues(of: playing).map(\.kind) == [.permissionSilence])
        #expect(ShellStatus.of(playing) == .warning)
        #expect(ShellRowState.of(playing.routes[0], in: playing) == .warning)
    }

    @Test func aPausedAppNextToARealWarningStillWarns() {
        let shot = snapshot(
            .running(warnings: [.noSignal(["warning: no audio arrived"]), .sampleRateMismatch(tap: 1, device: 2)]),
            apps: [app(playing: false)])
        #expect(ShellStatus.of(shot) == .warning)
        #expect(ShellRowState.of(shot.routes[0], in: shot) == .warning)
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
