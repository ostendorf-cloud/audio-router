// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// Which parts of the stream id diff run for a tap mode.
public enum StreamDiffPlan {
    /// The diff path (aggregate with the sub device only, tap list set afterwards) is for the
    /// device stream mode. The stereo mixdown tap keeps its place in the composition from the
    /// start, with the drift compensation key.
    public static func usesDiff(mode: TapMode) -> Bool { mode == .deviceStream }

    /// The device stream tap taps the output stream of the same device that is the aggregate's
    /// main sub device, so both share one hardware clock and there is nothing to compensate. That
    /// is reasoning, not header text: `AudioHardware.h` only says that
    /// `kAudioSubTapDriftCompensationKey` says "drift compensation is enabled for the AudioSubTap"
    /// and does not say for which clock. Short runs showed no drift symptoms, a long run is not
    /// measured.
    public static func setsDrift(mode: TapMode) -> Bool { mode != .deviceStream }

    public static let driftSkipped =
        "drift compensation skipped, the tap shares the clock of the main sub device (reasoning, not header text)"
}

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

    /// A drift compensation that could not be set is not an error of the diff: the tap of the
    /// device stream mode shares the main device's clock. The diff goes on.
    public mutating func driftNotSet(reason: String) {
        steps.append("drift compensation not set (\(reason)), tap shares the main device clock")
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
