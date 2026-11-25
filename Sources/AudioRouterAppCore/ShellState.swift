// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore

/// What the menu bar icon shows. One value for the whole app.
public enum ShellStatus: Equatable, Sendable {
    /// Routing is switched off globally.
    case off
    /// Routing is on and nothing needs attention. This includes an empty route list and routes that
    /// wait for their app, which is the normal case.
    case running
    /// A route has an issue of severity `warning`, for example a route that runs with a warning or waits for
    /// its destination device. A route whose app plays nothing is `info` and stays `running`.
    case warning
    /// A route failed, or the engine could not start.
    case error

    /// The name of the menu bar template image, without extension. `scripts/bundle.sh` copies
    /// `Resources/Branding/<name>.png` and `<name>@2x.png` into `Contents/Resources` of the app.
    public var imageName: String {
        switch self {
        case .off: "menubar-off"
        case .running: "menubar-running"
        case .warning: "menubar-warning"
        case .error: "menubar-error"
        }
    }

    /// The SF Symbol the menu bar shows when the template image is missing, which is the case for a
    /// binary that runs outside the app bundle, for example from `swift run`.
    public var symbolName: String {
        switch self {
        case .off: "speaker.slash"
        case .running: "speaker.wave.2"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }

    /// The accessibility label of the icon.
    public var label: String {
        switch self {
        case .off: "audio-router, off"
        case .running: "audio-router, running"
        case .warning: "audio-router, warning"
        case .error: "audio-router, error"
        }
    }

    /// Maps the engine snapshot to the icon state: off, else the worst issue severity of
    /// `RouteIssues.worstSeverity`, so the icon and the messages cannot drift. A switched off route counts
    /// with its failed teardown only (issue 23).
    public static func of(_ snapshot: EngineSnapshot, startFailed: Bool = false) -> ShellStatus {
        guard snapshot.isOn else { return .off }
        return RouteIssues.worstSeverity(snapshot, startFailed: startFailed)?.shellStatus ?? .running
    }
}

/// The state of one route row in the menu.
public enum ShellRowState: Equatable, Sendable {
    case disabled
    case waitingForDevice
    case waitingForApp
    case starting
    case running
    case warning
    case failed

    /// A running route shows `warning` only when one of its warnings maps to an issue of severity `warning`.
    /// A route whose app plays nothing stays `running`, its message says so (issue 61).
    public static func of(_ status: RouteStatus, in snapshot: EngineSnapshot) -> ShellRowState {
        switch status.state {
        case .disabled: return .disabled
        case .waitingForDevice: return .waitingForDevice
        case .waitingForApp: return .waitingForApp
        case .starting: return .starting
        case .running(let warnings):
            let issues = RouteIssues.of(warnings, route: status.route, in: snapshot)
            return issues.contains { $0.severity >= .warning } ? .warning : .running
        case .failed: return .failed
        }
    }

    /// A short label. The final message texts are a separate issue.
    public var text: String {
        switch self {
        case .disabled: "Off"
        case .waitingForDevice: "Waiting for device"
        case .waitingForApp: "Waiting for app"
        case .starting: "Starting"
        case .running: "Running"
        case .warning: "Running with warning"
        case .failed: "Failed"
        }
    }
}

/// One route row of the menu: a toggle and the state.
public struct ShellRouteRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let state: ShellRowState

    public init(id: UUID, name: String, isEnabled: Bool, state: ShellRowState) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.state = state
    }

    /// The menu text, for example `Music: Running`.
    public var title: String { "\(name): \(state.text)" }
}

/// The about section of the settings window.
public enum ShellAbout {
    /// Text for a run without a bundle, for example `swift run`.
    public static let developmentVersion = "development build"

    /// The `CFBundleShortVersionString` of the bundle, or the fallback text when it is missing or empty.
    public static func version(info: [String: Any]?) -> String {
        guard let value = info?["CFBundleShortVersionString"] as? String, !value.isEmpty else {
            return developmentVersion
        }
        return value
    }

    /// The version of the running app. A `swift run` binary has no Info.plist of its own, and the
    /// bundle then belongs to the toolchain or is empty, so the key is simply absent.
    public static func version(bundle: Bundle = .main) -> String {
        version(info: bundle.infoDictionary)
    }
}
