// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore

/// What one meter shows: peak and RMS of a route in dBFS, with a floor of -60.
///
/// Left and right are merged. The IO proc measures every routed channel into one level, so there is
/// no per channel value (per channel meters are out of scope).
///
/// The level is the tap input. The output reading of a `MeterReading` equals the tap by construction
/// (it is read back from the output buffer right after the copy, with the same guards), so a second
/// bar would show the same thing. The output reading proves that the copy ran, not the gain.
///
/// The dB conversion is `Level.dBFS` of `RouterCore`, the same one the command line meter prints.
public struct MeterLevel: Equatable, Sendable {
    /// The lowest value the meter shows. Anything quieter, silence included, is shown as this.
    public static let floorDBFS = -60.0

    /// Peak in dBFS, at least `floorDBFS`. Above 0 for a signal over full scale.
    public let peakDBFS: Double
    /// RMS in dBFS, at least `floorDBFS`.
    public let rmsDBFS: Double

    public init(peak: Double, rms: Double) {
        peakDBFS = Self.dBFS(peak)
        rmsDBFS = Self.dBFS(rms)
    }

    public init(_ reading: MeterReading) {
        self.init(peak: reading.input.peak, rms: reading.input.rms)
    }

    /// A linear level (full scale is 1) in dBFS, floored at `floorDBFS`. Zero, negative and NaN
    /// values are the floor.
    public static func dBFS(_ linear: Double) -> Double {
        let value = Level.dBFS(linear)
        return value.isNaN ? floorDBFS : max(value, floorDBFS)
    }

    /// The bar length from 0 (-60 dBFS) to 1 (0 dBFS). A signal over full scale fills the bar.
    public static func fraction(dBFS: Double) -> Double {
        min(max((dBFS - floorDBFS) / -floorDBFS, 0), 1)
    }

    public var peakFraction: Double { Self.fraction(dBFS: peakDBFS) }
    public var rmsFraction: Double { Self.fraction(dBFS: rmsDBFS) }

    /// The peak as a number with one decimal, for example `-20.0`. The floor shows as `-60.0`.
    public var peakText: String { String(format: "%.1f", peakDBFS) }
}
