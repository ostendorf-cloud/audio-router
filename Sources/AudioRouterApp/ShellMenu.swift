// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AudioRouterAppCore
import SwiftUI

/// The content of the menu bar menu: global toggle, one row per route, Settings, Quit.
struct ShellMenu: View {
    let model: ShellViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle(
            "Routing",
            isOn: Binding(
                get: { model.isOn },
                set: { on in Task { await model.setGlobalOn(on) } }))
        if !model.rows.isEmpty {
            Divider()
            ForEach(model.rows) { row in
                Toggle(
                    row.title,
                    isOn: Binding(
                        get: { row.isEnabled },
                        set: { model.setRouteEnabled(row.id, $0) }))
            }
        }
        Divider()
        // An accessory app is not active, so the settings window would open behind other windows.
        // A gesture on a SettingsLink does not fire inside a menu, so a button activates the app first.
        Button("Settings\u{2026}") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit audio-router") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
