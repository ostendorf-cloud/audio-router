// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The menu bar app. A placeholder for now: one menu bar icon with a Quit item. The routes, the
/// engine and the settings follow in later issues. The app talks to the engine only, never to
/// Core Audio.
@main
struct AudioRouterMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("audio-router", systemImage: "speaker.wave.2") {
            Button("Quit audio-router") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
