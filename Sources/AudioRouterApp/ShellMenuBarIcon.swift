// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AudioRouterAppCore
import SwiftUI

/// The menu bar icon: the template image of the status from `Contents/Resources`.
/// Outside the app bundle, for example with `swift run`, the image is missing and the SF Symbol stands in.
struct ShellMenuBarIcon: View {
    let status: ShellStatus

    var body: some View {
        Group {
            if let image = Self.templateImage(status.imageName) {
                Image(nsImage: image)
            } else {
                Image(systemName: status.symbolName)
            }
        }
        .accessibilityLabel(status.label)
    }

    /// `Bundle.image(forResource:)` loads `<name>.png` and `<name>@2x.png` as one image with two
    /// representations. A template image takes the menu bar colour in light and dark mode.
    static func templateImage(_ name: String) -> NSImage? {
        guard let image = Bundle.main.image(forResource: name) else { return nil }
        image.isTemplate = true
        return image
    }
}
