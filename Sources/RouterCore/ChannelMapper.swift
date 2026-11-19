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
}

public enum ChannelMapper {
    /// Builds the routes that copy the source onto the channel pair of the destination. A mono
    /// source feeds both channels. Runs once when a route starts, never in the callback.
    public static func routes(
        source: ChannelLayout,
        destination: ChannelLayout,
        pair: ChannelPair
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
                sourceBuffer: src.buffer,
                sourceChannel: src.channel,
                destinationBuffer: out.buffer,
                destinationChannel: out.channel
            )
        }
    }

    /// Copies the routed channels from `input` into `output`. Channels without a route stay as
    /// they are: Core Audio hands the IO proc zeroed output buffers (AudioHardware.h, the
    /// AudioDeviceIOProc documentation), so every other channel of the device stays silent.
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
    /// `ChannelMapperTests` runs this very function on in memory buffer lists, and
    /// docs/prototype-findings.md lists the disassembly check the owner can repeat.
    public static func render(
        routes: UnsafePointer<ChannelRoute>,
        routeCount: Int,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
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
            index += 1
            guard route.sourceBuffer < inputCount, route.destinationBuffer < outputCount
            else { continue }
            let from = inputBuffers[route.sourceBuffer]
            let to = outputBuffers[route.destinationBuffer]
            let fromChannels = Int(from.mNumberChannels)
            let toChannels = Int(to.mNumberChannels)
            guard fromChannels > 0, toChannels > 0,
                route.sourceChannel < fromChannels, route.destinationChannel < toChannels,
                let fromData = from.mData, let toData = to.mData
            else { continue }
            var frames = Int(from.mDataByteSize) / (floatSize * fromChannels)
            let outFrames = Int(to.mDataByteSize) / (floatSize * toChannels)
            if outFrames < frames { frames = outFrames }
            let source = fromData.assumingMemoryBound(to: Float.self)
            let destination = toData.assumingMemoryBound(to: Float.self)
            var frame = 0
            while frame < frames {
                destination[frame * toChannels + route.destinationChannel] =
                    source[frame * fromChannels + route.sourceChannel]
                frame += 1
            }
        }
    }
}
