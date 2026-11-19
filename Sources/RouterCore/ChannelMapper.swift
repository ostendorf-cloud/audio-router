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
    /// one stereo input stream (layout `[2, 2]`). This function refuses it and names the device.
    /// `chooseTapBuffers` accepts it when the stream id diff names the buffer.
    /// A non interleaved tap is handled: its shape is one buffer per channel.
    public static func tapBuffers(
        in input: ChannelLayout,
        tapChannels: Int,
        interleaved: Bool,
        deviceName: String = "the output device"
    ) throws -> Range<Int> {
        try chooseTapBuffers(
            in: input, tapChannels: tapChannels, interleaved: interleaved, deviceName: deviceName
        ).range
    }

    /// Like `tapBuffers`, with two more ways to decide and the way reported.
    ///
    /// - `override` names the first tap buffer. The shape found there must equal the tap shape.
    /// - `deviceInputBuffers` is the input layout of the target device read from the device
    ///   itself. When the tap shape appears more than once, the last match is taken only if the
    ///   list is exactly the device inputs followed by the tap shape AND that differs from the
    ///   tap shape followed by the device inputs. Then the layout itself excludes the other
    ///   order (it assumes the aggregate lists its parts one after the other). When both orders
    ///   give the same list, for example device `[32]` and tap `[32]`, the layout proves nothing
    ///   and the route is refused unless `override` names the buffer. Without
    ///   `deviceInputBuffers` an ambiguous shape is refused as well.
    ///
    /// Headers checked for a provable way to name the tap stream (AudioHardware.h,
    /// AudioHardwareBase.h): `kAudioDevicePropertyIOProcStreamUsage` switches streams on and off by
    /// index but does not say which index is the tap. `kAudioAggregateDevicePropertyTapList`
    /// lists tap uids, not streams. No header says that a tap's stream is owned by the tap
    /// object. So no documented property names the tap stream.
    public static func chooseTapBuffers(
        in input: ChannelLayout,
        tapChannels: Int,
        interleaved: Bool,
        deviceName: String = "the output device",
        deviceInputBuffers: [Int]? = nil,
        override: Int? = nil,
        streamDiffBuffer: Int? = nil
    ) throws -> (range: Range<Int>, choice: TapBufferChoice) {
        guard tapChannels > 0 else {
            throw RouterError.unsupportedFormat("the tap has no channels")
        }
        let shape = interleaved ? [tapChannels] : Array(repeating: 1, count: tapChannels)
        let buffers = input.channelsPerBuffer
        if let override {
            guard override >= 0, override + shape.count <= buffers.count,
                Array(buffers[override..<override + shape.count]) == shape
            else {
                throw RouterError.unsupportedFormat(
                    "--tap-buffer \(override) does not name a buffer of the tap shape \(shape), buffers are \(buffers)")
            }
            return (override..<override + shape.count, .override)
        }
        // The stream id diff names the buffer without a guess about the order. A buffer of the
        // wrong shape means the diff and the buffer list disagree: ignore it and decide as before.
        if let k = streamDiffBuffer, k >= 0, k + shape.count <= buffers.count,
            Array(buffers[k..<k + shape.count]) == shape
        {
            return (k..<k + shape.count, .streamDiff)
        }
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
        if matches.count == 1 { return (match, .uniqueShape) }
        guard let last = matches.last, let deviceInputBuffers, buffers == deviceInputBuffers + shape else {
            throw RouterError.ambiguousTapStream(device: deviceName, buffers: buffers, tapShape: shape)
        }
        // With device inputs D and tap shape T the list is D+T or T+D. If both are the same list
        // (D == T, or D and T repeat the same shape) the layout cannot tell the order.
        guard deviceInputBuffers + shape != shape + deviceInputBuffers else {
            throw RouterError.unprovableTapOrder(device: deviceName, buffers: buffers, tapShape: shape)
        }
        return (last, .lastByMeasuredOrder)
    }

    /// Finds the tap buffer from the input stream IDs of the aggregate device before and after the
    /// tap was added to its tap list. The one new stream is the tap's, and its index in the stream
    /// list is taken as the buffer index.
    ///
    /// The header does not say that the IO proc buffers follow the order of
    /// `kAudioDevicePropertyStreams`. This checks what it can: exactly one new stream, the old
    /// streams keep their order, the channels per stream equal the buffer list, and the new
    /// stream has the tap's channel count. Where several streams have the same channel count,
    /// that does not prove the order, only a run does (docs/prototype-findings.md section 9).
    /// Only an interleaved tap is handled, the caller falls back when this throws.
    public static func tapBufferByStreamDiff(
        before: [UInt32],
        after: [UInt32],
        streamChannels: [Int],
        inputBuffers: [Int],
        tapChannels: Int,
        interleaved: Bool,
        currentStreams: [UInt32]? = nil
    ) throws -> Int {
        func fail(_ reason: String) -> RouterError { .unsupportedFormat("stream id diff: \(reason)") }
        guard interleaved else { throw fail("only an interleaved tap is handled") }
        if let currentStreams, currentStreams != after {
            throw fail("the input streams changed since the tap was added (after \(after), now \(currentStreams))")
        }
        let added = after.indices.filter { !before.contains(after[$0]) }
        guard added.count == 1, let k = added.first else {
            throw fail("\(added.count) new input streams, expected exactly one (before \(before), after \(after))")
        }
        guard after.filter({ before.contains($0) }) == before else {
            throw fail("the old streams changed (before \(before), after \(after))")
        }
        guard streamChannels == inputBuffers else {
            throw fail("channels per stream \(streamChannels) differ from the buffers \(inputBuffers)")
        }
        guard inputBuffers[k] == tapChannels else {
            throw fail("the new stream has \(inputBuffers[k]) channels, the tap has \(tapChannels)")
        }
        return k
    }

    /// Builds the routes that copy the source onto the channel pair of the destination. A mono
    /// source feeds both channels. `sourceBufferOffset` is the index of the first tap buffer in
    /// the full input list. `sourcePair` names the tap channels to copy, counted from 1. Runs
    /// once when a route starts, never in the callback.
    public static func routes(
        source: ChannelLayout,
        destination: ChannelLayout,
        pair: ChannelPair,
        sourceBufferOffset: Int = 0,
        sourcePair: ChannelPair = .firstPair
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
            // A mono tap feeds both channels, but only for the default source pair.
            let monoDuplicate = source.totalChannels == 1 && sourcePair.first == 1
            let wanted = monoDuplicate ? 0 : sourcePair.first - 1 + offset
            guard let src = source.locate(wanted) else {
                throw RouterError.unsupportedFormat(
                    "the tap has \(source.totalChannels) channels, no channel \(wanted + 1) for "
                        + "--source-channels \(sourcePair.first),\(sourcePair.second)")
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

    /// Sets `flags[n]` to 1 for every input channel n that carried a sample that is not zero.
    /// Channels count over all input buffers in order, buffer major. A channel past `flagCount` is
    /// not recorded. Diagnostic only, it shows which tap channels carry the app.
    ///
    /// Same real time contract as `render`: raw pointers and integers, wrapping index arithmetic,
    /// no allocation, lock, logging or reference counting.
    static func markActive(
        input: UnsafePointer<AudioBufferList>,
        flags: UnsafeMutablePointer<UInt32>,
        flagCount: Int
    ) {
        let header = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        let inputCount = Int(input.pointee.mNumberBuffers)
        let buffers = UnsafeRawPointer(input).advanced(by: header).assumingMemoryBound(to: AudioBuffer.self)
        let floatSize = MemoryLayout<Float>.size
        var first = 0  // global index of channel 0 of the current buffer
        var index = 0
        while index < inputCount {
            let buffer = buffers[index]
            index &+= 1
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            if let data = buffer.mData {
                let frames = Int(buffer.mDataByteSize) / (floatSize &* channels)
                let samples = data.assumingMemoryBound(to: Float.self)
                var channel = 0
                while channel < channels {
                    let slot = first &+ channel
                    if slot < flagCount && flags[slot] == 0 {
                        var frame = 0
                        while frame < frames {
                            if samples[frame &* channels &+ channel].bitPattern << 1 != 0 {
                                flags[slot] = 1
                                break
                            }
                            frame &+= 1
                        }
                    }
                    channel &+= 1
                }
            }
            first &+= channels
        }
    }

    /// Splits the active input channels into tap channels and device input channels, both counted
    /// from 1 inside their group. Control thread only.
    public static func activity(
        active: [Int], inputBuffers: [Int], tapBuffers: Range<Int>
    ) -> (tap: [Int], device: [Int]) {
        var tap: [Int] = []
        var device: [Int] = []
        var first = 0
        var tapFirst = 0
        var deviceFirst = 0
        for (buffer, count) in inputBuffers.enumerated() {
            let isTap = tapBuffers.contains(buffer)
            for channel in 0..<count where active.contains(first + channel) {
                if isTap {
                    tap.append(tapFirst + channel + 1)
                } else {
                    device.append(deviceFirst + channel + 1)
                }
            }
            first += count
            if isTap { tapFirst += count } else { deviceFirst += count }
        }
        return (tap, device)
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
