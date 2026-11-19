// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio

/// The buffers of one side of an aggregate device: channels per buffer, in buffer order.
///
/// An interleaved stream is one buffer with n channels. A non interleaved stream is n buffers
/// with one channel each. A multichannel interface can expose several streams.
public struct ChannelLayout: Equatable, Sendable {
    public let channelsPerBuffer: [Int]

    public init(channelsPerBuffer: [Int]) {
        self.channelsPerBuffer = channelsPerBuffer
    }

    public var totalChannels: Int { channelsPerBuffer.reduce(0, +) }

    /// Finds the buffer and the channel inside it for a 0 based channel over all buffers.
    func locate(_ channel: Int) -> (buffer: Int, channel: Int)? {
        guard channel >= 0 else { return nil }
        var remaining = channel
        for (index, count) in channelsPerBuffer.enumerated() {
            if remaining < count { return (index, remaining) }
            remaining -= count
        }
        return nil
    }
}

/// One copied channel: source buffer and channel to destination buffer and channel. Plain
/// integers only, so an array of routes can be read in the real time callback without any
/// reference counting.
public struct ChannelRoute: Equatable, Sendable {
    public let sourceBuffer: Int
    public let sourceChannel: Int
    public let destinationBuffer: Int
    public let destinationChannel: Int

    public init(sourceBuffer: Int, sourceChannel: Int, destinationBuffer: Int, destinationChannel: Int) {
        self.sourceBuffer = sourceBuffer
        self.sourceChannel = sourceChannel
        self.destinationBuffer = destinationBuffer
        self.destinationChannel = destinationChannel
    }
}

public enum ChannelMapper {
    /// Finds the buffers of the tap inside the input side of the aggregate device.
    ///
    /// The target device is a sub device of the aggregate, so its own input channels (a mixer
    /// can have 32) join the same input buffer list. The headers do not say in which order the
    /// sub device streams and the tap streams come. This looks for the buffer shape of the tap,
    /// one buffer with all channels when interleaved, one buffer per channel otherwise. It
    /// refuses when the shape appears more than once, because then the tap cannot be told from a
    /// device input and a microphone could be routed to the output. That includes a device with
    /// one stereo input stream (layout `[2, 2]`). Phase 1 refuses it and names the device.
    /// A non interleaved tap is handled: its shape is one buffer per channel.
    public static func tapBuffers(
        in input: ChannelLayout,
        tapChannels: Int,
        interleaved: Bool,
        deviceName: String = "the output device"
    ) throws -> Range<Int> {
        guard tapChannels > 0 else {
            throw RouterError.unsupportedFormat("the tap has no channels")
        }
        let shape = interleaved ? [tapChannels] : Array(repeating: 1, count: tapChannels)
        let buffers = input.channelsPerBuffer
        var matches: [Range<Int>] = []
        var start = 0
        while start + shape.count <= buffers.count {
            if Array(buffers[start..<start + shape.count]) == shape {
                matches.append(start..<start + shape.count)
            }
            start += 1
        }
        guard let match = matches.first else {
            throw RouterError.unsupportedFormat(
                "no input buffer of the aggregate device has the tap shape \(shape), buffers are \(buffers)")
        }
        guard matches.count == 1 else {
            throw RouterError.ambiguousTapStream(device: deviceName, buffers: buffers, tapShape: shape)
        }
        return match
    }

    /// Builds the routes that copy the source onto the channel pair of the destination. A mono
    /// source feeds both channels. `sourceBufferOffset` is the index of the first tap buffer in
    /// the full input list. Runs once when a route starts, never in the callback.
    public static func routes(
        source: ChannelLayout,
        destination: ChannelLayout,
        pair: ChannelPair,
        sourceBufferOffset: Int = 0
    ) throws -> [ChannelRoute] {
        guard source.totalChannels > 0 else {
            throw RouterError.unsupportedFormat("the tap has no channels")
        }
        return try [0, 1].map { offset in
            let destinationChannel = pair.first - 1 + offset
            guard let out = destination.locate(destinationChannel) else {
                throw RouterError.unsupportedFormat(
                    "output channel \(destinationChannel + 1) does not exist on the device")
            }
            guard let src = source.locate(min(offset, source.totalChannels - 1)) else {
                throw RouterError.unsupportedFormat("the tap has no channel \(offset + 1)")
            }
            return ChannelRoute(
                sourceBuffer: src.buffer + sourceBufferOffset,
                sourceChannel: src.channel,
                destinationBuffer: out.buffer,
                destinationChannel: out.channel
            )
        }
    }

    /// Copies the routed channels from `input` into `output`. Channels without a route stay as
    /// they are: Core Audio hands the IO proc zeroed output buffers (AudioHardware.h, the
    /// AudioDeviceIOProc documentation), so every other channel of the device stays silent.
    /// `signalSeen` is set to 1 once a copied sample is not zero. Only this function writes it,
    /// only the control thread reads it, and one aligned 32 bit word cannot tear.
    ///
    /// Real time contract. This function runs on the audio thread and must not allocate, lock,
    /// log, call into Objective-C or touch a reference counted object. It is held to that by
    /// construction:
    /// - The arguments are raw pointers and integers. There is no class, array, closure,
    ///   existential or String in the signature or the body, so Swift emits no retain, release or
    ///   allocation.
    /// - The routes are built before the device starts and are freed after it stopped.
    /// - No bounds failure path allocates: a route that does not fit the buffers is skipped.
    /// - The body is `while` loops and pointer arithmetic over Float samples. It calls no generic
    ///   library code such as ranges, `min` or the CoreAudio overlay wrappers.
    /// - Index arithmetic uses the wrapping operators `&+` and `&*`, so no overflow trap exists.
    ///   Routes and buffer sizes are checked first, so nothing wraps in practice.
    /// `ChannelMapperTests` runs this very function on in memory buffer lists, and
    /// docs/prototype-findings.md lists the disassembly check the owner can repeat.
    public static func render(
        routes: UnsafePointer<ChannelRoute>,
        routeCount: Int,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        signalSeen: UnsafeMutablePointer<UInt32>
    ) {
        // AudioBufferList is a header followed by mNumberBuffers AudioBuffers. Plain pointer
        // arithmetic keeps the wrapper types of the CoreAudio overlay out of the audio thread.
        let header = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        let inputCount = Int(input.pointee.mNumberBuffers)
        let outputCount = Int(output.pointee.mNumberBuffers)
        let inputBuffers = UnsafeRawPointer(input).advanced(by: header)
            .assumingMemoryBound(to: AudioBuffer.self)
        let outputBuffers = UnsafeMutableRawPointer(output).advanced(by: header)
            .assumingMemoryBound(to: AudioBuffer.self)
        let floatSize = MemoryLayout<Float>.size

        var index = 0
        while index < routeCount {
            let route = routes[index]
            index &+= 1
            guard route.sourceBuffer >= 0, route.sourceBuffer < inputCount,
                route.destinationBuffer >= 0, route.destinationBuffer < outputCount,
                route.sourceChannel >= 0, route.destinationChannel >= 0
            else { continue }
            let from = inputBuffers[route.sourceBuffer]
            let to = outputBuffers[route.destinationBuffer]
            let fromChannels = Int(from.mNumberChannels)
            let toChannels = Int(to.mNumberChannels)
            guard fromChannels > 0, toChannels > 0,
                route.sourceChannel < fromChannels, route.destinationChannel < toChannels,
                let fromData = from.mData, let toData = to.mData
            else { continue }
            var frames = Int(from.mDataByteSize) / (floatSize &* fromChannels)
            let outFrames = Int(to.mDataByteSize) / (floatSize &* toChannels)
            if outFrames < frames { frames = outFrames }
            let source = fromData.assumingMemoryBound(to: Float.self)
            let destination = toData.assumingMemoryBound(to: Float.self)
            var bits: UInt32 = 0
            var frame = 0
            while frame < frames {
                let sample = source[frame &* fromChannels &+ route.sourceChannel]
                destination[frame &* toChannels &+ route.destinationChannel] = sample
                // Drops the sign bit, so -0.0 counts as silence. A bit cast, not a library call.
                bits |= sample.bitPattern << 1
                frame &+= 1
            }
            if bits != 0 { signalSeen.pointee = 1 }
        }
    }

    /// Accumulates the level of the tap samples that `render` read and of the samples it wrote.
    /// Call it after `render` with the same arguments. It reads the output again, so a wrong
    /// copy would show as a difference between the two readings.
    ///
    /// Same real time contract as `render`: raw pointers and integers only, wrapping index
    /// arithmetic, no allocation, lock, logging or reference counting. The meter memory scheme and
    /// why plain words are enough for a diagnostic are in `MeterBlock`.
    static func measure(
        routes: UnsafePointer<ChannelRoute>,
        routeCount: Int,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafePointer<AudioBufferList>,
        meter: MeterBlock
    ) {
        let header = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        let inputCount = Int(input.pointee.mNumberBuffers)
        let outputCount = Int(output.pointee.mNumberBuffers)
        let inputBuffers = UnsafeRawPointer(input).advanced(by: header)
            .assumingMemoryBound(to: AudioBuffer.self)
        let outputBuffers = UnsafeRawPointer(output).advanced(by: header)
            .assumingMemoryBound(to: AudioBuffer.self)
        let floatSize = MemoryLayout<Float>.size
        let slot = Int(meter.words[0] & 1)
        var inputLevel = meter.slots[slot]
        var outputLevel = meter.slots[2 &+ slot]

        var index = 0
        while index < routeCount {
            let route = routes[index]
            index &+= 1
            guard route.sourceBuffer >= 0, route.sourceBuffer < inputCount,
                route.destinationBuffer >= 0, route.destinationBuffer < outputCount,
                route.sourceChannel >= 0, route.destinationChannel >= 0
            else { continue }
            let from = inputBuffers[route.sourceBuffer]
            let to = outputBuffers[route.destinationBuffer]
            let fromChannels = Int(from.mNumberChannels)
            let toChannels = Int(to.mNumberChannels)
            guard fromChannels > 0, toChannels > 0,
                route.sourceChannel < fromChannels, route.destinationChannel < toChannels,
                let fromData = from.mData, let toData = to.mData
            else { continue }
            var frames = Int(from.mDataByteSize) / (floatSize &* fromChannels)
            let outFrames = Int(to.mDataByteSize) / (floatSize &* toChannels)
            if outFrames < frames { frames = outFrames }
            let source = fromData.assumingMemoryBound(to: Float.self)
            let destination = toData.assumingMemoryBound(to: Float.self)
            var frame = 0
            while frame < frames {
                inputLevel.add(source[frame &* fromChannels &+ route.sourceChannel])
                outputLevel.add(destination[frame &* toChannels &+ route.destinationChannel])
                frame &+= 1
            }
        }
        meter.slots[slot] = inputLevel
        meter.slots[2 &+ slot] = outputLevel
    }
}
