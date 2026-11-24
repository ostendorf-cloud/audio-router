// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the user can do about an issue. One action per issue.
public enum RouteAction: Equatable, Sendable, CaseIterable {
    /// Opens the privacy pane of System Settings, see `ErrorsSettings`.
    case openAudioCaptureSettings
    /// The engine's `retryNow` for the route, or a new engine start for an engine failure.
    case retry
    /// The user picks another destination device.
    case chooseDevice
    /// Nothing to press. The text says what to do or what happens next.
    case none

    /// The button title, nil for `none`.
    public var title: String? {
        switch self {
        case .openAudioCaptureSettings: "Open System Settings"
        case .retry: "Retry now"
        case .chooseDevice: "Choose device"
        case .none: nil
        }
    }
}

/// How bad an issue is. The order is the order of the menu bar icon: the worst issue decides.
public enum IssueSeverity: Int, Comparable, Equatable, Sendable {
    /// Normal, for example a route that waits for its app.
    case info
    case warning
    case error

    public static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The icon state of an issue of this severity. `ShellStatus.of` is the source of truth for a
    /// snapshot, a test keeps the two in step.
    public var shellStatus: ShellStatus {
        switch self {
        case .info: .running
        case .warning: .warning
        case .error: .error
        }
    }
}

/// The cause an issue names. One value per message family. A case is a likely cause when the text says so.
public enum RouteIssueKind: String, Equatable, Sendable, CaseIterable {
    /// Silence while the app plays: the capture permission is likely missing. A denied tap may deliver silence.
    case permissionSilence
    /// A start failed in the way a missing permission can fail it.
    case permissionStartFailed
    /// Silence and the app does not output audio, or not to this device.
    case appNotPlaying
    /// The destination is not in the device list.
    case deviceGone
    /// The destination is listed but reports not alive.
    case deviceNotResponding
    /// The destination is alive but the default output is another device.
    case deviceNotDefault
    /// The destination is alive and the default output again. The route resumes after the quiet period.
    case deviceReturning
    /// No process of the app is connected to Core Audio. The normal case.
    case appNotRunning
    /// The tap and the destination run at different rates.
    case sampleRateMismatch
    /// Signal on other tap channels than the source pair, or a silent tap next to an active device input.
    case tapChannelMismatch
    /// The tap buffer cannot be told from a device input. The route refuses to start.
    case ambiguousTapBuffer
    /// Any other failed start.
    case startFailed
    case invalidRouteApp
    case invalidRouteDevice
    case invalidRouteChannels
    case invalidRouteDuplicatePair
    case invalidRouteDuplicateID
    /// A teardown step failed. A tap or aggregate device can stay until the app quits.
    case teardownLeftovers
    /// The engine itself could not start.
    case engineStartFailed
}

/// One message with its action, for one route or for the engine.
public struct RouteIssue: Equatable, Sendable {
    public let kind: RouteIssueKind
    public let severity: IssueSeverity
    /// The text the user sees. It says `likely` where the cause is inferred and not known.
    public let message: String
    public let action: RouteAction
    /// The raw text of the engine or the checks, for a tooltip or a log. Not part of the golden texts.
    public let detail: String?

    public init(
        kind: RouteIssueKind, severity: IssueSeverity, message: String, action: RouteAction, detail: String? = nil
    ) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.action = action
        self.detail = detail
    }
}
