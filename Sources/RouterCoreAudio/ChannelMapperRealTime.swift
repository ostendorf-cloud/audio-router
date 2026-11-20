// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import RouterCore

// The parts of `ChannelMapper` that run on the audio thread. They read and write
// AudioBufferList, a Core Audio type, so they live here and not in RouterCore. They stay in the
// same module as `routerIOProc` and `MeterBlock`, so the compiler sees all of the IO proc code.
extension ChannelMapper {
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
