// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Testing

@testable import RouterCore

/// Builds real AudioBufferLists in memory, so the code that runs on the audio thread is the code
/// under test. No audio hardware is involved.
private final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storages: [UnsafeMutablePointer<Float>] = []

    /// One buffer per entry of `channelsPerBuffer`, `frames` frames each, filled with `fill`.
    init(channelsPerBuffer: [Int], frames: Int, fill: (Int, Int, Int) -> Float = { _, _, _ in 0 }) {
        list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
        for (index, channels) in channelsPerBuffer.enumerated() {
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    storage[frame * channels + channel] = fill(index, frame, channel)
                }
            }
            storages.append(storage)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage)
            )
        }
    }

    deinit {
        for storage in storages { storage.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    func sample(buffer: Int, frame: Int, channel: Int) -> Float {
        let channels = Int(list[buffer].mNumberChannels)
        return storages[buffer][frame * channels + channel]
    }
}

private func render(
    _ routes: [ChannelRoute], input: Buffers, output: Buffers
) {
    routes.withUnsafeBufferPointer { buffer in
        ChannelMapper.render(
            routes: buffer.baseAddress!,
            routeCount: buffer.count,
            input: input.list.unsafePointer,
            output: output.list.unsafeMutablePointer
        )
    }
}

struct ChannelMapperTests {
    // Left is 1.x, right is 2.x, so a sample tells where it came from.
    private let stereo: (Int, Int, Int) -> Float = { _, frame, channel in
        Float(channel + 1) + Float(frame) / 100
    }

    @Test func stereoLandsOnTheChosenPairOfOneInterleavedStream() throws {
        let source = ChannelLayout(channelsPerBuffer: [2])
        let destination = ChannelLayout(channelsPerBuffer: [8])
        let routes = try ChannelMapper.routes(source: source, destination: destination, pair: ChannelPair(first: 5))
        let input = Buffers(channelsPerBuffer: [2], frames: 4, fill: stereo)
        let output = Buffers(channelsPerBuffer: [8], frames: 4)
        render(routes, input: input, output: output)
        for frame in 0..<4 {
            for channel in 0..<8 {
                let expected: Float =
                    channel == 4 ? 1 + Float(frame) / 100 : channel == 5 ? 2 + Float(frame) / 100 : 0
                #expect(output.sample(buffer: 0, frame: frame, channel: channel) == expected)
            }
        }
    }

    @Test func pairAtTheStartAndTheEndOfTheDevice() throws {
        let source = ChannelLayout(channelsPerBuffer: [2])
        let destination = ChannelLayout(channelsPerBuffer: [32])
        for first in [1, 31] {
            let routes = try ChannelMapper.routes(
                source: source, destination: destination, pair: ChannelPair(first: first))
            let input = Buffers(channelsPerBuffer: [2], frames: 2, fill: stereo)
            let output = Buffers(channelsPerBuffer: [32], frames: 2)
            render(routes, input: input, output: output)
            #expect(output.sample(buffer: 0, frame: 1, channel: first - 1) == 1.01)
            #expect(output.sample(buffer: 0, frame: 1, channel: first) == 2.01)
            #expect(output.sample(buffer: 0, frame: 1, channel: first == 1 ? 5 : 0) == 0)
        }
    }

    @Test func pairThatSpansTwoOutputStreams() throws {
        // Two streams of 2 channels: channels 2,3 are the right of stream 0 and the left of stream 1.
        let routes = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: [2]),
            destination: ChannelLayout(channelsPerBuffer: [2, 2]),
            pair: ChannelPair(first: 2)
        )
        let input = Buffers(channelsPerBuffer: [2], frames: 1, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2, 2], frames: 1)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 0, channel: 0) == 0)
        #expect(output.sample(buffer: 0, frame: 0, channel: 1) == 1)
        #expect(output.sample(buffer: 1, frame: 0, channel: 0) == 2)
        #expect(output.sample(buffer: 1, frame: 0, channel: 1) == 0)
    }

    @Test func nonInterleavedSourceIsReadPerBuffer() throws {
        let routes = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: [1, 1]),
            destination: ChannelLayout(channelsPerBuffer: [4]),
            pair: ChannelPair(first: 3)
        )
        let input = Buffers(channelsPerBuffer: [1, 1], frames: 2) { buffer, _, _ in Float(buffer + 1) }
        let output = Buffers(channelsPerBuffer: [4], frames: 2)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 1, channel: 2) == 1)
        #expect(output.sample(buffer: 0, frame: 1, channel: 3) == 2)
    }

    @Test func monoSourceFeedsBothChannels() throws {
        let routes = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: [1]),
            destination: ChannelLayout(channelsPerBuffer: [4]),
            pair: ChannelPair(first: 1)
        )
        let input = Buffers(channelsPerBuffer: [1], frames: 1) { _, _, _ in 0.5 }
        let output = Buffers(channelsPerBuffer: [4], frames: 1)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 0, channel: 0) == 0.5)
        #expect(output.sample(buffer: 0, frame: 0, channel: 1) == 0.5)
    }

    @Test func differentFrameCountsCopyTheShorterOne() throws {
        let routes = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: [2]),
            destination: ChannelLayout(channelsPerBuffer: [2]),
            pair: ChannelPair(first: 1)
        )
        let input = Buffers(channelsPerBuffer: [2], frames: 2, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 4)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 1, channel: 0) == 1.01)
        #expect(output.sample(buffer: 0, frame: 2, channel: 0) == 0)
    }

    @Test func routeBeyondTheBuffersIsSkipped() {
        let routes = [
            ChannelRoute(sourceBuffer: 3, sourceChannel: 0, destinationBuffer: 0, destinationChannel: 0),
            ChannelRoute(sourceBuffer: 0, sourceChannel: 9, destinationBuffer: 0, destinationChannel: 0),
            ChannelRoute(sourceBuffer: 0, sourceChannel: 0, destinationBuffer: 0, destinationChannel: 9),
        ]
        let input = Buffers(channelsPerBuffer: [2], frames: 2, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 2)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 0, channel: 0) == 0)
        #expect(output.sample(buffer: 0, frame: 1, channel: 1) == 0)
    }

    @Test func routesRejectAPairOutsideTheDeviceAndAnEmptyTap() {
        #expect(throws: RouterError.self) {
            try ChannelMapper.routes(
                source: ChannelLayout(channelsPerBuffer: [2]),
                destination: ChannelLayout(channelsPerBuffer: [4]),
                pair: ChannelPair(first: 4))
        }
        #expect(throws: RouterError.self) {
            try ChannelMapper.routes(
                source: ChannelLayout(channelsPerBuffer: []),
                destination: ChannelLayout(channelsPerBuffer: [4]),
                pair: ChannelPair(first: 1))
        }
    }
}
