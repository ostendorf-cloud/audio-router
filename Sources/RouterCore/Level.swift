// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

// The meter memory the IO proc writes (`LevelAccumulator`, `MeterBlock`) is in RouterCoreAudio.

/// The level of one measuring point over one interval. Linear values, full scale is 1.
public struct LevelReading: Equatable, Sendable {
    public let peak: Double
    public let rms: Double
    /// Samples of all measured channels together, bad samples excluded.
    public let samples: UInt64

    public init(peak: Double, rms: Double, samples: UInt64) {
        self.peak = peak
        self.rms = rms
        self.samples = samples
    }

    public var peakDBFS: Double { Level.dBFS(peak) }
    public var rmsDBFS: Double { Level.dBFS(rms) }
}

/// What the meter saw in one interval: the tap input as the IO proc read it, and the output
/// channels as the IO proc wrote them.
///
/// `output` is read back from the output buffer right after the copy, with the same guards as
/// the copy, so it equals `input` by construction. It shows that the copy ran. It is not an
/// independent measuring point and says nothing about the gain before the IO proc. Left and
/// right are merged in one level.
public struct MeterReading: Equatable, Sendable {
    public let input: LevelReading
    public let output: LevelReading
    /// Frames per channel the IO proc saw in the interval. That is the IO rate of the aggregate
    /// device on its own clock, not the sample rate of the tap, and it jitters with the timer.
    /// Average several readings.
    public let frames: UInt64

    public init(input: LevelReading, output: LevelReading, frames: UInt64) {
        self.input = input
        self.output = output
        self.frames = frames
    }
}

public enum Level {
    /// Decibels relative to full scale. Silence (zero or less) is minus infinity.
    public static func dBFS(_ linear: Double) -> Double {
        linear > 0 ? 20 * log10(linear) : -Double.infinity
    }
}
