// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Testing

@testable import RouterCore

private let canary: Float = 55

/// Builds real AudioBufferLists in memory, so the code that runs on the audio thread is the code
/// under test. No audio hardware is involved.
///
/// Every buffer has `padFrames` frames of canary values behind its declared size. Code that
/// reads or writes past the declared size shows up as a changed or copied canary.
/// With `hiddenBuffer` the list has one more buffer behind `mNumberBuffers`, filled with canary
/// values. Code that indexes one buffer too far touches it.
private final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storages: [UnsafeMutablePointer<Float>] = []
    private let channelsPerBuffer: [Int]

    init(
        channelsPerBuffer: [Int],
        frames: Int,
        padFrames: Int = 0,
        hiddenBuffer: Bool = false,
        fill: (Int, Int, Int) -> Float = { _, _, _ in 0 }
    ) {
        self.channelsPerBuffer = channelsPerBuffer
        let total = channelsPerBuffer.count + (hiddenBuffer ? 1 : 0)
        list = AudioBufferList.allocate(maximumBuffers: total)
        for index in 0..<total {
            let hidden = index == channelsPerBuffer.count
            let channels = hidden ? 2 : channelsPerBuffer[index]
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: (frames + padFrames) * channels)
            for frame in 0..<(frames + padFrames) {
                for channel in 0..<channels {
                    let declared = frame < frames && !hidden
                    storage[frame * channels + channel] = declared ? fill(index, frame, channel) : canary
                }
            }
            storages.append(storage)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage)
            )
        }
        list.count = channelsPerBuffer.count
    }

    deinit {
        for storage in storages { storage.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    /// Reads a sample, pad frames and the hidden buffer included.
    func sample(buffer: Int, frame: Int, channel: Int) -> Float {
        let channels = buffer < channelsPerBuffer.count ? channelsPerBuffer[buffer] : 2
        return storages[buffer][frame * channels + channel]
    }
}

/// Renders and returns the value of the signal flag.
@discardableResult
private func render(_ routes: [ChannelRoute], input: Buffers, output: Buffers) -> UInt32 {
    let flag = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    flag.initialize(to: 0)
    defer { flag.deallocate() }
    routes.withUnsafeBufferPointer { buffer in
        ChannelMapper.render(
            routes: buffer.baseAddress!,
            routeCount: buffer.count,
            input: input.list.unsafePointer,
            output: output.list.unsafeMutablePointer,
            signalSeen: flag
        )
    }
    return flag.pointee
}

private func route(_ srcBuffer: Int, _ srcChannel: Int, _ dstBuffer: Int, _ dstChannel: Int) -> ChannelRoute {
    ChannelRoute(
        sourceBuffer: srcBuffer, sourceChannel: srcChannel, destinationBuffer: dstBuffer,
        destinationChannel: dstChannel)
}

struct ChannelMapperTests {
    // Left is 1.x, right is 2.x, so a sample tells where it came from.
    private let stereo: (Int, Int, Int) -> Float = { _, frame, channel in
        Float(channel + 1) + Float(frame) / 100
    }

    private func expectUntouched(
        _ output: Buffers, buffers: [Int], frames: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for buffer in buffers {
            for frame in 0..<frames {
                for channel in 0..<Int(output.list[buffer].mNumberChannels) {
                    #expect(
                        output.sample(buffer: buffer, frame: frame, channel: channel) == 0,
                        sourceLocation: sourceLocation)
                }
            }
        }
    }

    @Test func stereoLandsOnTheChosenPairOfOneInterleavedStream() throws {
        let source = ChannelLayout(channelsPerBuffer: [2])
        let destination = ChannelLayout(channelsPerBuffer: [8])
        let routes = try ChannelMapper.routes(source: source, destination: destination, pair: Samples.pair(5))
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
                source: source, destination: destination, pair: Samples.pair(first))
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
            pair: Samples.pair(2)
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
            pair: Samples.pair(3)
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
            pair: Samples.pair(1)
        )
        let input = Buffers(channelsPerBuffer: [1], frames: 1) { _, _, _ in 0.5 }
        let output = Buffers(channelsPerBuffer: [4], frames: 1)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 0, channel: 0) == 0.5)
        #expect(output.sample(buffer: 0, frame: 0, channel: 1) == 0.5)
    }

    // MARK: Frame counts

    @Test func shorterInputLeavesTheRestOfTheOutputAlone() throws {
        let routes = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: [2]),
            destination: ChannelLayout(channelsPerBuffer: [2]),
            pair: Samples.pair(1)
        )
        // The input has canary frames behind its declared 2 frames. Copying more than 2 frames
        // (bytes not divided by channels) would carry them into the output.
        let input = Buffers(channelsPerBuffer: [2], frames: 2, padFrames: 4, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 6)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 1, channel: 0) == 1.01)
        for frame in 2..<6 {
            #expect(output.sample(buffer: 0, frame: frame, channel: 0) == 0)
            #expect(output.sample(buffer: 0, frame: frame, channel: 1) == 0)
        }
    }

    @Test func shorterOutputIsNotWrittenBeyondItsSize() throws {
        let routes = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: [2]),
            destination: ChannelLayout(channelsPerBuffer: [2]),
            pair: Samples.pair(1)
        )
        let input = Buffers(channelsPerBuffer: [2], frames: 4, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 2, padFrames: 3)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 1, channel: 1) == 2.01)
        for frame in 2..<5 {
            #expect(output.sample(buffer: 0, frame: frame, channel: 0) == canary)
            #expect(output.sample(buffer: 0, frame: frame, channel: 1) == canary)
        }
    }

    // MARK: Bounds, exactly at the edge

    @Test func routeToTheBufferJustPastTheInputIsSkipped() {
        let input = Buffers(channelsPerBuffer: [2], frames: 2, hiddenBuffer: true, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 2)
        render([route(1, 0, 0, 0)], input: input, output: output)
        expectUntouched(output, buffers: [0], frames: 2)
    }

    @Test func routeToTheBufferJustPastTheOutputIsSkipped() {
        let input = Buffers(channelsPerBuffer: [2], frames: 2, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 2, hiddenBuffer: true)
        render([route(0, 0, 1, 0)], input: input, output: output)
        for frame in 0..<2 {
            #expect(output.sample(buffer: 1, frame: frame, channel: 0) == canary)
            #expect(output.sample(buffer: 1, frame: frame, channel: 1) == canary)
        }
    }

    @Test func lastBufferOfEachSideStillWorks() {
        let input = Buffers(channelsPerBuffer: [1, 2], frames: 1) { buffer, _, channel in
            Float(buffer * 10 + channel + 1)
        }
        let output = Buffers(channelsPerBuffer: [1, 2], frames: 1, hiddenBuffer: true)
        render([route(1, 1, 1, 1)], input: input, output: output)
        #expect(output.sample(buffer: 1, frame: 0, channel: 1) == 12)
    }

    @Test func sourceChannelJustPastTheBufferIsSkipped() {
        let input = Buffers(channelsPerBuffer: [2], frames: 3, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 3)
        render([route(0, 2, 0, 0)], input: input, output: output)
        expectUntouched(output, buffers: [0], frames: 3)
    }

    @Test func destinationChannelJustPastTheBufferIsSkipped() {
        let input = Buffers(channelsPerBuffer: [2], frames: 3, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 3)
        render([route(0, 0, 0, 2)], input: input, output: output)
        expectUntouched(output, buffers: [0], frames: 3)
    }

    @Test func negativeSourceChannelIsSkipped() {
        let input = Buffers(channelsPerBuffer: [2], frames: 3, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 3)
        render([route(0, -1, 0, 0)], input: input, output: output)
        expectUntouched(output, buffers: [0], frames: 3)
    }

    @Test func routeBeyondTheBuffersIsSkipped() {
        let input = Buffers(channelsPerBuffer: [2], frames: 2, fill: stereo)
        let output = Buffers(channelsPerBuffer: [2], frames: 2)
        render([route(3, 0, 0, 0), route(0, 9, 0, 0), route(0, 0, 0, 9)], input: input, output: output)
        expectUntouched(output, buffers: [0], frames: 2)
    }

    // MARK: Signal flag

    @Test func signalFlagStaysClearForSilence() {
        let input = Buffers(channelsPerBuffer: [2], frames: 4) { _, _, channel in channel == 0 ? 0 : -0.0 }
        let output = Buffers(channelsPerBuffer: [2], frames: 4)
        #expect(render([route(0, 0, 0, 0), route(0, 1, 0, 1)], input: input, output: output) == 0)
    }

    @Test func signalFlagIsSetByASingleNonZeroSample() {
        let input = Buffers(channelsPerBuffer: [2], frames: 4) { _, frame, channel in
            frame == 3 && channel == 1 ? -0.25 : 0
        }
        let output = Buffers(channelsPerBuffer: [2], frames: 4)
        #expect(render([route(0, 0, 0, 0), route(0, 1, 0, 1)], input: input, output: output) == 1)
    }

    // MARK: Finding the tap among the device inputs

    private func findTap(_ buffers: [Int], channels: Int = 2, interleaved: Bool = true) throws -> Range<Int> {
        try ChannelMapper.tapBuffers(
            in: ChannelLayout(channelsPerBuffer: buffers), tapChannels: channels, interleaved: interleaved)
    }

    @Test func aTapAfterThe32DeviceInputsIsFound() throws {
        #expect(try findTap([32, 2]) == 1..<2)
    }

    @Test func aTapBeforeTheDeviceInputsIsFound() throws {
        #expect(try findTap([2, 32]) == 0..<1)
    }

    @Test func aDeviceWithoutInputsLeavesOnlyTheTap() throws {
        #expect(try findTap([2]) == 0..<1)
    }

    @Test func aNonInterleavedTapIsOneBufferPerChannel() throws {
        #expect(try findTap([32, 1, 1], interleaved: false) == 1..<3)
    }

    @Test func aDeviceInputOfTheSameShapeIsRefused() {
        for layout in [[2, 2], [2, 8, 2], [1, 1, 1, 1]] {
            let interleaved = layout != [1, 1, 1, 1]
            #expect(throws: RouterError.ambiguousTapStream(buffers: layout, tapShape: interleaved ? [2] : [1, 1])) {
                try ChannelMapper.tapBuffers(
                    in: ChannelLayout(channelsPerBuffer: layout), tapChannels: 2, interleaved: interleaved)
            }
        }
    }

    @Test func missingTapShapeAndEmptyTapAreRefused() {
        #expect(throws: RouterError.self) {
            try ChannelMapper.tapBuffers(in: ChannelLayout(channelsPerBuffer: [32]), tapChannels: 2, interleaved: true)
        }
        #expect(throws: RouterError.self) {
            try ChannelMapper.tapBuffers(in: ChannelLayout(channelsPerBuffer: []), tapChannels: 2, interleaved: true)
        }
        #expect(throws: RouterError.self) {
            try ChannelMapper.tapBuffers(in: ChannelLayout(channelsPerBuffer: [2]), tapChannels: 0, interleaved: true)
        }
    }

    @Test func aDeviceInputIsNeverCopiedToTheOutput() throws {
        // Input list: a 32 channel device input full of 7s, then the tap.
        let layout = ChannelLayout(channelsPerBuffer: [32, 2])
        let range = try ChannelMapper.tapBuffers(in: layout, tapChannels: 2, interleaved: true)
        let routes = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: Array(layout.channelsPerBuffer[range])),
            destination: ChannelLayout(channelsPerBuffer: [8]),
            pair: Samples.pair(3),
            sourceBufferOffset: range.lowerBound
        )
        #expect(routes.map(\.sourceBuffer) == [1, 1])
        let input = Buffers(channelsPerBuffer: [32, 2], frames: 2) { buffer, _, channel in
            buffer == 0 ? 7 : Float(channel + 1)
        }
        let output = Buffers(channelsPerBuffer: [8], frames: 2)
        render(routes, input: input, output: output)
        #expect(output.sample(buffer: 0, frame: 1, channel: 2) == 1)
        #expect(output.sample(buffer: 0, frame: 1, channel: 3) == 2)
        for channel in [0, 1, 4, 5, 6, 7] {
            #expect(output.sample(buffer: 0, frame: 1, channel: channel) == 0)
        }
    }

    // MARK: Layout and route building

    @Test func locateFindsEdgesAndRejectsOutsideValues() {
        let layout = ChannelLayout(channelsPerBuffer: [2, 3])
        #expect(layout.locate(-1) == nil)
        #expect(layout.locate(0)?.buffer == 0)
        #expect(layout.locate(1)?.channel == 1)
        #expect(layout.locate(2)?.buffer == 1)
        #expect(layout.locate(2)?.channel == 0)
        #expect(layout.locate(4)?.channel == 2)
        #expect(layout.locate(5) == nil)
    }

    @Test func routesRejectAPairOutsideTheDeviceAndAnEmptyTap() {
        #expect(throws: RouterError.self) {
            try ChannelMapper.routes(
                source: ChannelLayout(channelsPerBuffer: [2]),
                destination: ChannelLayout(channelsPerBuffer: [4]),
                pair: Samples.pair(4))
        }
        #expect(throws: RouterError.self) {
            try ChannelMapper.routes(
                source: ChannelLayout(channelsPerBuffer: []),
                destination: ChannelLayout(channelsPerBuffer: [4]),
                pair: Samples.pair(1))
        }
    }
}
