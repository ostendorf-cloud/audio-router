// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore

/// Maps the engine states and the errors to messages with an action. Pure, no SwiftUI.
///
/// A message says `likely` where the cause is inferred. The permission is always inferred: no public
/// API to query the status is verified, and whether a denied tap fails or delivers silence is not
/// measured (`docs/prototype-findings.md` section 1).
public enum RouteIssues {
    // MARK: - Kinds

    /// The cause of a start error. Exhaustive on purpose: a new `RouterError` case does not compile
    /// until it is mapped here.
    public static func kind(of error: RouterError) -> RouteIssueKind {
        switch error {
        case .usage, .unsupportedFormat, .sessionAlreadyStopped, .teardownFailed:
            return .startFailed
        case .unknownDevice:
            return .deviceGone
        case .channelsOutOfRange:
            return .invalidRouteChannels
        case .noMatchingProcess:
            return .appNotRunning
        case .coreAudio(let operation, _):
            return permissionOperation(operation) ? .permissionStartFailed : .startFailed
        case .ambiguousTapStream, .unprovableTapOrder, .refusedWithDiff:
            return .ambiguousTapBuffer
        }
    }

    /// The cause of a failed route. The engine keeps only the text of the error, so this reads the
    /// text. A test pins every `RouterError` text to `kind(of:)`, so a reworded text fails there.
    public static func kind(ofFailureMessage message: String) -> RouteIssueKind {
        if message.hasPrefix("Cannot tell the tap from the input channels of") { return .ambiguousTapBuffer }
        if message.hasPrefix("No audio process with bundle id") { return .appNotRunning }
        if message.hasPrefix("No output device with uid") { return .deviceGone }
        if message.hasPrefix("Channels "), message.contains(" do not fit: ") { return .invalidRouteChannels }
        if permissionOperation(message) { return .permissionStartFailed }
        return .startFailed
    }

    /// The operations of a start that a missing capture permission can fail, the same two the error
    /// text names the permission for (`RouterError.description`).
    private static func permissionOperation(_ text: String) -> Bool {
        text.contains("(create tap)") || text.contains("(create aggregate)")
    }

    // MARK: - Issues of a route

    /// The issues of one route, the first is the main one. Empty for a route that is off, starting or fine.
    public static func of(_ status: RouteStatus, in snapshot: EngineSnapshot) -> [RouteIssue] {
        let route = status.route
        guard snapshot.isOn, route.enabled else { return [] }
        let names = Names(route: route, snapshot: snapshot)
        var issues: [RouteIssue]
        switch status.state {
        case .disabled, .starting:
            issues = []
        case .waitingForDevice:
            issues = [waitingForDevice(route: route, names: names, snapshot: snapshot)]
        case .waitingForApp:
            issues = [
                RouteIssue(
                    kind: .appNotRunning, severity: .info, message: "Waiting for \(names.app) to start.",
                    action: .none)
            ]
        case .running(let warnings):
            issues = warnings.map { warning(for: $0, route: route, names: names, snapshot: snapshot) }
        case .failed(let failure):
            issues = failed(failure, route: route, names: names)
        }
        if !status.teardownFailures.isEmpty {
            let count = status.teardownFailures.count
            issues.append(
                RouteIssue(
                    kind: .teardownLeftovers, severity: .warning,
                    message:
                        "\(count) teardown \(count == 1 ? "step" : "steps") failed."
                        + " A tap or aggregate device likely stays until the app quits.",
                    action: .none, detail: status.teardownFailures.joined(separator: "; ")))
        }
        return issues
    }

    /// The issue of an engine that could not start. The engine start is the only thing this retries.
    public static func engineStartFailure(_ text: String) -> RouteIssue {
        RouteIssue(
            kind: .engineStartFailed, severity: .error,
            message: "The routing engine could not start. No route runs.", action: .retry, detail: text)
    }

    /// The worst severity over the enabled routes and the engine start, nil when there is no issue at all.
    /// `ShellStatus.of` stays the source of the icon, a test keeps the two in step.
    public static func worstSeverity(_ snapshot: EngineSnapshot, startFailure: String? = nil) -> IssueSeverity? {
        var all = snapshot.routes.flatMap { of($0, in: snapshot) }.map(\.severity)
        if startFailure != nil { all.append(.error) }
        return all.max()
    }

    // MARK: - Waiting

    private static func waitingForDevice(route: Route, names: Names, snapshot: EngineSnapshot) -> RouteIssue {
        let device = snapshot.devices.first { $0.uid == route.destinationUID }
        // The snapshot says which of the two causes holds at the moment of the read. The engine state
        // itself is the same `waitingForDevice` for both, so the texts stay "likely".
        guard let device else {
            return RouteIssue(
                kind: .deviceGone, severity: .warning,
                message: "\(names.device) is gone, likely unplugged or switched off. The route waits for it.",
                action: .chooseDevice)
        }
        if !device.isAlive {
            return RouteIssue(
                kind: .deviceNotResponding, severity: .warning,
                message: "\(names.device) is listed but does not respond, likely switched off or disconnected."
                    + " The route waits for it.",
                action: .chooseDevice)
        }
        if !device.isDefaultOutput {
            return RouteIssue(
                kind: .deviceNotDefault, severity: .warning,
                message: "\(names.device) is likely no longer the default output. The route waits until it is"
                    + " the default again. \(names.app) plays on the current default output meanwhile.",
                action: .none)
        }
        return RouteIssue(
            kind: .deviceReturning, severity: .warning,
            message: "\(names.device) is back. The route resumes shortly.", action: .none)
    }

    // MARK: - Warnings

    private static func warning(
        for warning: RouteWarning, route: Route, names: Names, snapshot: EngineSnapshot
    ) -> RouteIssue {
        switch warning {
        case .noSignal(let texts):
            let detail = texts.joined(separator: "\n")
            // The tap check texts start with "warning: tap buffer". They mean capture works.
            if texts.contains(where: { $0.hasPrefix("warning: tap buffer") }) {
                return tapChannelMismatch(detail: detail)
            }
            let playing =
                snapshot.apps.first { $0.bundleID == route.appBundleID }?.processes.contains(where: \.isRunningOutput)
                ?? false
            if playing {
                return RouteIssue(
                    kind: .permissionSilence, severity: .warning,
                    message: "No audio from \(names.app) for 10 s although it plays. Likely the audio capture"
                        + " permission is missing or denied, or it plays to another device than \(names.device).",
                    action: .openAudioCaptureSettings, detail: detail)
            }
            return RouteIssue(
                kind: .appNotPlaying, severity: .warning,
                message: "No audio from \(names.app) for 10 s. It is likely paused or not playing to"
                    + " \(names.device). If it plays, the audio capture permission may be missing.",
                action: .none, detail: detail)
        case .tapCheck(let text):
            return tapChannelMismatch(detail: text)
        case .sampleRateMismatch(let tap, let device):
            return RouteIssue(
                kind: .sampleRateMismatch, severity: .warning,
                message: "Sample rates differ: the tap runs at \(hertz(tap)), \(names.device) at \(hertz(device))."
                    + " The audio is likely affected.",
                action: .none)
        }
    }

    private static func tapChannelMismatch(detail: String) -> RouteIssue {
        RouteIssue(
            kind: .tapChannelMismatch, severity: .warning,
            message: "Audio likely arrives on other tap channels than the source pair. Check the source channels.",
            action: .none, detail: detail)
    }

    // MARK: - Failures

    private static func failed(_ failure: RouteFailure, route: Route, names: Names) -> [RouteIssue] {
        switch failure {
        case .validation(let errors):
            return errors.map { validation($0, names: names) }
        case .startFailed(let message, let attempt, let retryIn):
            let progress = "Attempt \(attempt) failed, retrying in \(seconds(retryIn))."
            return [startIssue(message: message, progress: progress, names: names)]
        case .refused(let message):
            return [startIssue(message: message, progress: "It is not retried automatically.", names: names)]
        case .retriesExhausted(let message, let attempts):
            let progress = "It failed \(attempts) times in a row, retries stopped."
            return [startIssue(message: message, progress: progress, names: names)]
        }
    }

    private static func startIssue(message: String, progress: String, names: Names) -> RouteIssue {
        let kind = kind(ofFailureMessage: message)
        let cause: String
        var action = RouteAction.retry
        switch kind {
        case .permissionStartFailed:
            cause = "The route could not start. Likely the audio capture permission is missing or denied."
            action = .openAudioCaptureSettings
        case .ambiguousTapBuffer:
            cause =
                "The tap buffer on \(names.device) cannot be told from a device input."
                + " The route refuses to start, a device input could reach the output."
            action = .none
        case .appNotRunning:
            cause = "The route could not start, \(names.app) has no audio process."
        case .deviceGone:
            cause = "The route could not start, \(names.device) is likely gone."
            action = .chooseDevice
        case .invalidRouteChannels:
            cause = "The route could not start, its channels do not fit \(names.device)."
            action = .chooseDevice
        default:
            cause = "The route could not start."
        }
        return RouteIssue(
            kind: kind, severity: .error, message: "\(cause) \(progress)", action: action, detail: message)
    }

    private static func validation(_ error: RouteValidationError, names: Names) -> RouteIssue {
        switch error {
        case .emptyBundleID:
            return RouteIssue(
                kind: .invalidRouteApp, severity: .error, message: "The route names no app.", action: .none)
        case .unknownDevice:
            return RouteIssue(
                kind: .invalidRouteDevice, severity: .error,
                message: "\(names.device) is not a known output device.", action: .chooseDevice)
        case .pairOutOfRange(_, let first, let deviceChannels):
            return RouteIssue(
                kind: .invalidRouteChannels, severity: .error,
                message: "Channels \(first),\(first + 1) do not fit: \(names.device) has \(deviceChannels)"
                    + " output channels.",
                action: .chooseDevice)
        case .duplicateDestinationPair(_, let first, _, _, _):
            return RouteIssue(
                kind: .invalidRouteDuplicatePair, severity: .error,
                message: "Channels \(first),\(first + 1) of \(names.device) are also used by another route.",
                action: .chooseDevice)
        case .duplicateRouteID:
            return RouteIssue(
                kind: .invalidRouteDuplicateID, severity: .error,
                message: "The route id is used more than once.", action: .none)
        }
    }

    // MARK: - Text helpers

    private struct Names {
        let app: String
        let device: String

        init(route: Route, snapshot: EngineSnapshot) {
            app = route.appBundleID.isEmpty ? route.name : route.appBundleID
            device = snapshot.devices.first { $0.uid == route.destinationUID }?.name ?? "Device \(route.destinationUID)"
        }
    }

    private static func hertz(_ rate: Double) -> String { "\(Int(rate.rounded())) Hz" }

    private static func seconds(_ value: TimeInterval) -> String {
        "\(Int(value.rounded(.up))) s"
    }
}
