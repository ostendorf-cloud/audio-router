// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Running peak and sum of squares of a stream of samples. Plain data, so the audio thread can
/// keep it in preallocated memory.
struct LevelAccumulator: Equatable, Sendable {
    var peak: Float = 0
    var sumSquares: Double = 0
    var samples: UInt64 = 0

    /// NaN and infinite samples are skipped, so one bad sample cannot poison the sum.
    @inline(__always)
    mutating func add(_ sample: Float) {
        let magnitude = sample < 0 ? -sample : sample
        guard magnitude <= Float.greatestFiniteMagnitude else { return }
        if magnitude > peak { peak = magnitude }
        sumSquares += Double(sample) * Double(sample)
        samples &+= 1
    }
}

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

    init(_ accumulator: LevelAccumulator) {
        peak = Double(accumulator.peak)
        rms = accumulator.samples == 0 ? 0 : (accumulator.sumSquares / Double(accumulator.samples)).squareRoot()
        samples = accumulator.samples
    }

    public var peakDBFS: Double { Level.dBFS(peak) }
    public var rmsDBFS: Double { Level.dBFS(rms) }
}

/// What the meter saw in one interval: the tap input as the IO proc read it, and the output
/// channels as the IO proc wrote them.
public struct MeterReading: Equatable, Sendable {
    public let input: LevelReading
    public let output: LevelReading
    /// Frames per channel in the interval, so frames per second is the effective sample rate.
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

/// Preallocated memory the IO proc accumulates levels in and a timer reads. No class, no array,
/// so the audio thread touches no reference counted object.
///
/// Two slots per measuring point. The IO proc writes the slot named by `words[0]`. The reader
/// never reads that slot. It reads the other one, which has been idle for a whole interval, clears
/// it and then points the writer at it. So a reading covers the interval before the last one, and
/// the first call only primes the scheme and returns nil.
///
/// No lock and no atomic: the words are plain aligned 32 bit values and the slots are plain
/// memory, as with the signal flag of `ChannelMapper.render`. A callback that started before a
/// flip can still add to the slot that was just handed to the reader, and a read can see a
/// partly written slot. The error is at most one callback in a once a second diagnostic, which is
/// why this is acceptable here. Do not use this scheme for anything that must be exact.
struct MeterBlock: @unchecked Sendable {
    /// Input slot 0 and 1, output slot 0 and 1.
    let slots: UnsafeMutablePointer<LevelAccumulator>
    /// Active slot, primed flag, channels measured per frame.
    let words: UnsafeMutablePointer<UInt32>

    static func allocate(channels: Int) -> MeterBlock {
        let slots = UnsafeMutablePointer<LevelAccumulator>.allocate(capacity: 4)
        slots.initialize(repeating: LevelAccumulator(), count: 4)
        let words = UnsafeMutablePointer<UInt32>.allocate(capacity: 3)
        words.initialize(to: 0)
        words[2] = UInt32(clamping: max(channels, 1))
        return MeterBlock(slots: slots, words: words)
    }

    /// Only after the IO proc is stopped and destroyed.
    func deallocate() {
        slots.deallocate()
        words.deallocate()
    }

    /// Control thread only.
    func collect() -> MeterReading? {
        let settled = 1 - Int(words[0] & 1)
        let input = slots[settled]
        let output = slots[2 + settled]
        slots[settled] = LevelAccumulator()
        slots[2 + settled] = LevelAccumulator()
        words[0] = UInt32(settled)
        let primed = words[1] != 0
        words[1] = 1
        guard primed else { return nil }
        return MeterReading(
            input: LevelReading(input),
            output: LevelReading(output),
            frames: input.samples / UInt64(words[2])
        )
    }
}
