// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import SwiftUI

/// The "Start at login" section of the settings window. It reads the real status on each appear.
struct LoginItemSection: View {
    @State private var model = LoginItemViewModel(service: LiveLoginItemService())

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
    }
}
