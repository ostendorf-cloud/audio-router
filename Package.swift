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
        .executable(name: "audio-router-proto", targets: ["audio-router-proto"]),
    ],
    targets: [
        .target(name: "RouterCore"),
        .executableTarget(
            name: "audio-router-proto",
            dependencies: ["RouterCore"],
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
        .testTarget(name: "RouterCoreTests", dependencies: ["RouterCore"]),
    ]
)
