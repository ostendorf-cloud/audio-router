// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AudioRouterAppCore
import SwiftUI

/// The "Start at login" section of the settings window. It reads the real status on each appear.
/// The model comes from `LoginItemContext`: no `@State`, its macro plugin ships with Xcode only.
struct LoginItemSection: View {
    private var model: LoginItemViewModel { LoginItemContext.model }

    var body: some View {
        Section("Startup") {
            Toggle(
                "Start at login",
                isOn: Binding(get: { model.isOn }, set: { model.setEnabled($0) }))
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.showsSettingsLink {
                Button("Open Login Items") { model.openSystemSettings() }
            }
        }
        .onAppear { model.refresh() }
        // The Settings window is created once and kept on close, so onAppear may not fire on each open.
        // The menu activates the app before it opens Settings, so this does.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
