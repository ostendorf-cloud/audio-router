// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import SwiftUI

/// The menu bar app. The scenes live in `Shell*.swift`, the testable logic in `AudioRouterAppCore`.
/// The app talks to the engine only, never to Core Audio.
@main
struct AudioRouterMenuBarApp: App {
    @NSApplicationDelegateAdaptor(ShellAppDelegate.self) private var delegate

    var body: some Scene {
        let model = ShellContext.model
        MenuBarExtra {
            ShellMenu(model: model)
        } label: {
            Image(systemName: model.status.symbolName)
                .accessibilityLabel(model.status.label)
        }
        Settings {
            ShellSettings()
        }
    }
}
