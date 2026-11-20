// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// RouterCore holds the pure logic and must build without Core Audio, audio frameworks or a UI.
/// This scans the sources, so a forbidden import fails the tests before it spreads.
@Suite struct CoreImportTests {
    static let forbidden = ["CoreAudio", "AudioToolbox", "AVFoundation", "AppKit"]

    /// `Tests/RouterCoreTests/<this file>` up to the package root, then `Sources/RouterCore`.
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RouterCore")

    /// The modules a line imports, or nil when the line is not an import. Handles attributes such
    /// as `@preconcurrency`, access levels such as `public import`, kinds such as
    /// `import struct CoreAudio.AudioBuffer` and submodules such as `import CoreAudio.AudioHardware`.
    static func importedModule(_ line: String) -> String? {
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = words.first, first.hasPrefix("@") { words.removeFirst() }
        let modifiers: Set<String> = ["public", "package", "internal", "fileprivate", "private"]
        if let first = words.first, modifiers.contains(first) { words.removeFirst() }
        guard words.first == "import", words.count >= 2 else { return nil }
        words.removeFirst()
        let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "let", "var"]
        if let first = words.first, kinds.contains(first), words.count >= 2 { words.removeFirst() }
        return words.first.map { String($0.split(separator: ".").first ?? "") }
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        return files.sorted { $0.path < $1.path }
    }

    @Test func theScanFindsTheSources() throws {
        let names = try Self.swiftFiles().map(\.lastPathComponent)
        #expect(names.contains("RoutePlanner.swift"))
        #expect(names.contains("Protocols.swift"))
    }

    @Test(arguments: [
        ("import CoreAudio", "CoreAudio"),
        ("@preconcurrency import AVFoundation", "AVFoundation"),
        ("public import AppKit", "AppKit"),
        ("import struct CoreAudio.AudioBuffer", "CoreAudio"),
        ("import AudioToolbox.AudioUnit", "AudioToolbox"),
        ("  import Foundation", "Foundation"),
    ])
    func theParserReadsEveryImportForm(line: String, module: String) {
        #expect(Self.importedModule(line) == module)
    }

    @Test func aCommentOrCodeIsNoImport() {
        #expect(Self.importedModule("// import CoreAudio") == nil)
        #expect(Self.importedModule("let importance = 1") == nil)
    }

    @Test func routerCoreImportsNoAudioOrUIFramework() throws {
        var found: [String] = []
        for file in try Self.swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if let module = Self.importedModule(String(line)), Self.forbidden.contains(module) {
                    found.append("\(file.lastPathComponent):\(number + 1) imports \(module)")
                }
            }
        }
        #expect(found.isEmpty, "RouterCore must not import \(Self.forbidden): \(found)")
    }
}
