// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Opens a URL in the system. The app implements it with `NSWorkspace`, tests with a fake.
public protocol SettingsOpening: Sendable {
    func open(_ url: URL)
}

public enum ErrorsSettings {
    /// The privacy pane of System Settings.
    ///
    /// Not verified: the anchor of the audio capture list ("System Audio Recording Only"). Nothing in
    /// this repository documents it, so this is the generic `com.apple.preference.security?Privacy`
    /// pane and the user scrolls to the list. Replace it once the anchor is checked on a Mac.
    public static let audioCapturePane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
}

/// Runs the action of an issue.
public struct IssueActionRunner: Sendable {
    private let opener: any SettingsOpening
    private let retry: @Sendable (UUID?) -> Void
    private let chooseDevice: @Sendable () -> Void

    /// - Parameters:
    ///   - retry: gets the route id, or nil for an engine start failure.
    ///   - chooseDevice: brings the place to pick another device to the front.
    public init(
        opener: any SettingsOpening, retry: @escaping @Sendable (UUID?) -> Void,
        chooseDevice: @escaping @Sendable () -> Void
    ) {
        self.opener = opener
        self.retry = retry
        self.chooseDevice = chooseDevice
    }

    /// `routeID` is nil for the issue of the engine.
    public func perform(_ action: RouteAction, routeID: UUID?) {
        switch action {
        case .openAudioCaptureSettings: opener.open(ErrorsSettings.audioCapturePane)
        case .retry: retry(routeID)
        case .chooseDevice: chooseDevice()
        case .none: break
        }
    }
}

extension ShellViewModel {
    /// Retries one route at once (the engine's `retryNow`), or starts the engine again when `routeID` is nil.
    public func retry(routeID: UUID?) {
        if let routeID {
            retryNow(routeID)
        } else {
            let routes = snapshot.routes.map(\.route)
            Task { await start(routes: routes) }
        }
    }

    /// The issues of one route, for the menu.
    public func issues(for routeID: UUID) -> [RouteIssue] {
        guard let status = snapshot.status(of: routeID) else { return [] }
        return RouteIssues.of(status, in: snapshot)
    }

    /// The issue of a failed engine start, nil when it started.
    public var engineIssue: RouteIssue? { startFailure.map(RouteIssues.engineStartFailure) }
}
