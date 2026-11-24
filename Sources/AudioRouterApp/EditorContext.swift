// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import Foundation
import RouterCore

/// Builds the route editor on the engine and the route file the shell already uses.
@MainActor
enum EditorContext {
    static let model: EditorViewModel = {
        let store: any EditorRouteStoring
        if let url = try? RouteStore.defaultURL() {
            store = RouteStore(url: url)
        } else {
            store = EditorUnavailableStore(reason: "the application support folder was not found")
        }
        let provider = EditorSnapshotProvider(engine: ShellContext.engine)
        return EditorViewModel(store: store, engine: ShellContext.engine, devices: provider, apps: provider)
    }()
}
