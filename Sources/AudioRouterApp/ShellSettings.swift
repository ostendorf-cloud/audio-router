// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import SwiftUI

/// The settings window: a placeholder for the route list and the about section.
struct ShellSettings: View {
    var body: some View {
        Form {
            Section("Routes") {
                EditorRouteList(model: EditorContext.model)
            }
            Section("About") {
                LabeledContent("audio-router", value: ShellAbout.version())
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }
}
