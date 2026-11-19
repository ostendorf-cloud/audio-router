// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// What happened while the tap stream was looked for by the stream id diff: every step that ran
/// and the outcome. Printed with the start lines, and also before a refusal, so a failing step
/// is visible.
public struct StreamDiffLog: Equatable, Sendable {
    public private(set) var steps: [String] = []
    public private(set) var failure: String?
    public private(set) var usedIndex: Int?

    public init() {}

    public mutating func step(_ text: String) {
        steps.append(text)
    }

    /// Records the reason the diff was not used. The first reason stays.
    public mutating func fail(_ reason: String) {
        if failure == nil { failure = reason }
        steps.append("failed: \(reason)")
    }

    public mutating func used(index: Int) {
        usedIndex = index
    }

    /// The one line that always states the outcome.
    public var outcome: String {
        if let usedIndex, failure == nil { return "stream id diff: used, tap at index \(usedIndex)" }
        return "stream id diff: not used (\(failure ?? "not evaluated"))"
    }

    /// The step lines followed by the outcome.
    public var lines: [String] {
        steps.map { "stream id diff step: \($0)" } + [outcome]
    }
}
