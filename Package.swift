// swift-tools-version: 6.0
// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

// The command line tool has no app bundle. The linker section __TEXT,__info_plist embeds the
// Info.plist into the Mach-O file, so the usage string for the system audio capture permission
// (NSAudioCaptureUsageDescription) travels with the binary.
let infoPlist = Context.packageDirectory + "/Sources/audio-router-proto/Info.plist"

let package = Package(
    name: "audio-router",
    // 14.2 is the first release with AudioHardwareCreateProcessTap (AudioHardwareTapping.h).
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "RouterCore", targets: ["RouterCore"]),
        .library(name: "RouterCoreAudio", targets: ["RouterCoreAudio"]),
        .executable(name: "AudioRouterApp", targets: ["AudioRouterApp"]),
        .executable(name: "audio-router-proto", targets: ["audio-router-proto"]),
    ],
    targets: [
        // Pure logic. Imports only Foundation and Darwin: CoreImportTests checks the imports.
        .target(name: "RouterCore"),
        // The real Core Audio implementation of the RouterCore protocols and the IO proc.
        .target(name: "RouterCoreAudio", dependencies: ["RouterCore"]),
        // The SwiftUI menu bar app.
        .executableTarget(
            name: "AudioRouterApp", dependencies: ["AudioRouterAppCore", "RouterCore", "RouterCoreAudio"]),
        // The testable part of the app: view models, state mapping and the engine seam. An executable
        // target cannot be imported by a test target, so this stays out of AudioRouterApp. No SwiftUI.
        .target(name: "AudioRouterAppCore", dependencies: ["RouterCore"]),
        // The command line diagnostic tool. Not part of a release.
        .executableTarget(
            name: "audio-router-proto",
            dependencies: ["RouterCore", "RouterCoreAudio"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ])
            ]
        ),
        .testTarget(name: "RouterCoreTests", dependencies: ["RouterCore"], exclude: ["Golden"]),
        .testTarget(name: "RouterCoreAudioTests", dependencies: ["RouterCore", "RouterCoreAudio"]),
        .testTarget(
            name: "AudioRouterAppTests", dependencies: ["AudioRouterAppCore", "RouterCore"], exclude: ["Errors"]),
    ]
)
