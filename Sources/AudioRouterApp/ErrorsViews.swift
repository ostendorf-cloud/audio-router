// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AudioRouterAppCore
import SwiftUI

/// Opens System Settings through the workspace.
struct WorkspaceSettingsOpener: SettingsOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// The issue lines of one route, each with the button of its action. Shown under the route toggle.
struct ErrorsRouteIssueRows: View {
    let model: ShellViewModel
    let routeID: UUID

    var body: some View {
        ForEach(Array(model.issues(for: routeID).enumerated()), id: \.offset) { _, issue in
            ErrorsIssueRow(model: model, issue: issue, routeID: routeID)
        }
    }
}

/// The issue of a failed engine start, above the routes.
struct ErrorsEngineIssueRows: View {
    let model: ShellViewModel

    var body: some View {
        if let issue = model.engineIssue {
            ErrorsIssueRow(model: model, issue: issue, routeID: nil)
        }
    }
}

struct ErrorsIssueRow: View {
    let model: ShellViewModel
    let issue: RouteIssue
    let routeID: UUID?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(issue.message)
            .help(issue.detail ?? issue.message)
        if let title = issue.action.title {
            Button(title) { runner.perform(issue.action, routeID: routeID) }
        }
    }

    private var runner: IssueActionRunner {
        IssueActionRunner(
            opener: WorkspaceSettingsOpener(),
            retry: { id in Task { @MainActor in model.retry(routeID: id) } },
            chooseDevice: {
                Task { @MainActor in
                    // An accessory app is not active, see `ShellMenu`.
                    NSApp.activate()
                    openSettings()
                }
            })
    }
}
