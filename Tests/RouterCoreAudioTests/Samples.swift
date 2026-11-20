// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

@testable import RouterCore

/// The part of `Samples` in `Tests/RouterCoreTests/Fakes.swift` that these tests use. A test
/// target cannot import another test target, so this is a copy. Keep the two in step.
enum Samples {
    static func pair(_ first: Int) -> ChannelPair {
        // Test values are always valid, a bad one fails the test run loudly.
        do { return try ChannelPair(first: first) } catch { fatalError("bad test channel \(first)") }
    }
}
