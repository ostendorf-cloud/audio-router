// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// RouterCore holds the pure logic and must build without Core Audio, audio frameworks or a UI.
/// This scans the sources against an allow list, so any other import fails the tests.
/// `task lint:core-imports` is a simpler grep with the same allow list.
enum ImportScanner {
    /// The only modules a RouterCore file may import.
    static let allowed: Set<String> = ["Foundation", "Darwin"]

    /// The source with comments and the contents of string literals replaced by spaces. Line
    /// breaks stay, so line numbers stay. Handles nested block comments, multi line strings, raw
    /// strings (`#"..."#`) and interpolation (`\(...)`), which can hold strings of its own.
    static func code(_ source: String) -> String {
        enum Context {
            case code(parens: Int)  // parens counts open parentheses inside an interpolation
            case string(hashes: Int, multiline: Bool)
        }
        let chars = Array(source)
        var out: [Character] = []
        var stack: [Context] = [.code(parens: 0)]
        var blockDepth = 0
        var index = 0

        func at(_ offset: Int) -> Character? {
            index + offset < chars.count ? chars[index + offset] : nil
        }
        func hashes(from start: Int) -> Int {
            var count = 0
            while start + count < chars.count, chars[start + count] == "#" { count += 1 }
            return count
        }
        func blank(_ count: Int) {
            for offset in 0..<count where index + offset < chars.count {
                out.append(chars[index + offset] == "\n" ? "\n" : " ")
            }
            index += count
        }

        while index < chars.count {
            let char = chars[index]
            if blockDepth > 0 {
                if char == "/" && at(1) == "*" {
                    blockDepth += 1
                    blank(2)
                } else if char == "*" && at(1) == "/" {
                    blockDepth -= 1
                    blank(2)
                } else {
                    blank(1)
                }
                continue
            }
            switch stack[stack.count - 1] {
            case .code(let parens):
                if char == "/" && at(1) == "/" {
                    while index < chars.count, chars[index] != "\n" { blank(1) }
                } else if char == "/" && at(1) == "*" {
                    blockDepth = 1
                    blank(2)
                } else if char == "#" || char == "\"" {
                    let count = hashes(from: index)
                    guard index + count < chars.count, chars[index + count] == "\"" else {
                        out.append(char)
                        index += 1
                        continue
                    }
                    let multiline =
                        index + count + 2 < chars.count && chars[index + count + 1] == "\""
                        && chars[index + count + 2] == "\""
                    out.append(" ")
                    blank(count + (multiline ? 3 : 1) - 1)
                    stack.append(.string(hashes: count, multiline: multiline))
                } else if stack.count > 1 && char == "(" {
                    stack[stack.count - 1] = .code(parens: parens + 1)
                    out.append(char)
                    index += 1
                } else if stack.count > 1 && char == ")" {
                    if parens == 0 {
                        stack.removeLast()  // the end of an interpolation, back in the string
                        blank(1)
                    } else {
                        stack[stack.count - 1] = .code(parens: parens - 1)
                        out.append(char)
                        index += 1
                    }
                } else {
                    out.append(char)
                    index += 1
                }
            case .string(let count, let multiline):
                if char == "\\" && hashes(from: index + 1) == count {
                    if index + 1 + count < chars.count, chars[index + 1 + count] == "(" {
                        blank(count + 2)
                        stack.append(.code(parens: 0))
                    } else {
                        blank(count + 2)  // an escaped character
                    }
                } else if char == "\"" {
                    let quotes = multiline ? 3 : 1
                    let closes =
                        (0..<quotes).allSatisfy { at($0) == "\"" } && hashes(from: index + quotes) >= count
                    if closes {
                        blank(quotes + count)
                        stack.removeLast()
                    } else {
                        blank(1)
                    }
                } else {
                    blank(1)
                }
            }
        }
        return String(out)
    }

    /// The module a statement imports, or nil when it is no import. Handles attributes such as
    /// `@preconcurrency` or `@_implementationOnly`, access levels such as `public import`, kinds
    /// such as `import struct CoreAudio.AudioBuffer` and submodules such as `import AudioToolbox.AudioUnit`.
    static func importedModule(_ statement: String) -> String? {
        var words = statement.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = words.first, first.hasPrefix("@") { words.removeFirst() }
        let modifiers: Set<String> = ["public", "package", "internal", "fileprivate", "private", "open"]
        if let first = words.first, modifiers.contains(first) { words.removeFirst() }
        guard words.first == "import", words.count >= 2 else { return nil }
        words.removeFirst()
        let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "let", "var"]
        if let first = words.first, kinds.contains(first), words.count >= 2 { words.removeFirst() }
        return words.first.map { String($0.split(separator: ".").first ?? "") }
    }

    /// Every import of a module outside the allow list, as `<line>: <module>`.
    static func violations(_ source: String) -> [String] {
        var found: [String] = []
        let lines = code(source).split(separator: "\n", omittingEmptySubsequences: false)
        for (number, line) in lines.enumerated() {
            for statement in line.split(separator: ";") {
                if let module = importedModule(String(statement)), !allowed.contains(module) {
                    found.append("\(number + 1): \(module)")
                }
            }
        }
        return found
    }
}

@Suite struct CoreImportTests {
    /// `Tests/RouterCoreTests/<this file>` up to the package root, then `Sources/RouterCore`.
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RouterCore")

    static func swiftFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        return files.sorted { $0.path < $1.path }
    }

    @Test func theScanFindsTheSources() {
        let names = Self.swiftFiles().map(\.lastPathComponent)
        #expect(names.contains("RoutePlanner.swift"))
        #expect(names.contains("Protocols.swift"))
    }

    @Test(arguments: [
        "import CoreAudio",
        "import CoreAudioTypes",
        "import AudioToolbox",
        "import AudioUnit",
        "import AVFoundation",
        "import AVFAudio",
        "import AppKit",
        "import Cocoa",
        "import SwiftUI",
        "@preconcurrency import AVFoundation",
        "@_implementationOnly import AudioToolbox",
        "public import AppKit",
        "import struct CoreAudio.AudioBuffer",
        "import AudioToolbox.AudioUnit",
        "  import CoreAudio",
        "import Foundation; import CoreAudio",
        "import AVFoundation;",
        "let x = 1 /* comment */; import CoreAudio",
        "let text = \"a \\(\"b\") c\"; import CoreAudio",
    ])
    func everyImportOutsideTheAllowListIsFound(source: String) {
        #expect(ImportScanner.violations(source).count == 1)
    }

    @Test(arguments: [
        "import Foundation",
        "import Darwin",
        "@preconcurrency import Foundation",
        "// import CoreAudio",
        "/* import CoreAudio */",
        "/* outer /* inner */\nimport CoreAudio\n*/",
        "let importance = 1",
        "let text = \"import CoreAudio\"",
        "let text = \"\"\"\nimport CoreAudio\n\"\"\"",
        "let text = #\"\"\"\nimport CoreAudio \"\"\" still inside\n\"\"\"#",
        "let text = #\"a \"quote\" \\#(1) import\"#",
        "let text = \"\\(\"import CoreAudio\")\"",
    ])
    func commentsStringsAndAllowedImportsPass(source: String) {
        #expect(ImportScanner.violations(source).isEmpty)
    }

    @Test func aViolationNamesItsLine() {
        let source = "import Foundation\n\"\"\"\nimport AppKit\n\"\"\"\nimport AudioToolbox\n"
        #expect(ImportScanner.violations(source) == ["5: AudioToolbox"])
    }

    @Test func routerCoreImportsOnlyTheAllowList() throws {
        let files = Self.swiftFiles()
        #expect(!files.isEmpty, "no Swift file under \(Self.sources.path)")
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            found += ImportScanner.violations(text).map { "\(file.lastPathComponent):\($0)" }
        }
        #expect(found.isEmpty, "RouterCore may import only \(ImportScanner.allowed.sorted()): \(found)")
    }
}
