// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import SwiftUI

/// The settings window: a placeholder for the route list and the about section.
struct ShellSettings: View {
    var body: some View {
        Form {
            Section("Routes") {
                Text("The route editor follows in a later version.")
                    .foregroundStyle(.secondary)
            }
            LoginItemSection()
            Section("About") {
                LabeledContent("audio-router", value: ShellAbout.version())
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 260)
    }
}
