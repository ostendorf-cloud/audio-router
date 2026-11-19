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
            #expect(
                throws: RouterError.ambiguousTapStream(
                    device: "X32", buffers: layout, tapShape: interleaved ? [2] : [1, 1])
            ) {
                try ChannelMapper.tapBuffers(
                    in: ChannelLayout(channelsPerBuffer: layout), tapChannels: 2, interleaved: interleaved,
                    deviceName: "X32")
            }
        }
    }

    @Test func aStereoInputDeviceIsRefusedWithDeviceAndLayoutInTheMessage() {
        do {
            _ = try ChannelMapper.tapBuffers(
                in: ChannelLayout(channelsPerBuffer: [2, 2]), tapChannels: 2, interleaved: true,
                deviceName: "Scarlett 2i2")
            Issue.record("a [2, 2] layout must be refused")
        } catch {
            let text = "\(error)"
            #expect(text.contains("Scarlett 2i2"))
            #expect(text.contains("[2, 2]"))
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

    // MARK: A 32 channel tap next to 32 device inputs

    private func choose(
        _ buffers: [Int], channels: Int = 32, interleaved: Bool = true, deviceInputs: [Int]? = nil,
        override: Int? = nil, diff: Int? = nil
    ) throws -> (range: Range<Int>, choice: TapBufferChoice) {
        try ChannelMapper.chooseTapBuffers(
            in: ChannelLayout(channelsPerBuffer: buffers), tapChannels: channels, interleaved: interleaved,
            deviceName: "X32", deviceInputBuffers: deviceInputs, override: override, streamDiffBuffer: diff)
    }

    // MARK: Stream id diff

    private func diff(
        before: [UInt32], after: [UInt32], channels: [Int]? = nil, buffers: [Int] = [32, 32], tap: Int = 32,
        interleaved: Bool = true
    ) throws -> Int {
        try ChannelMapper.tapBufferByStreamDiff(
            before: before, after: after, streamChannels: channels ?? buffers, inputBuffers: buffers,
            tapChannels: tap, interleaved: interleaved)
    }

    @Test func streamsThatChangedSinceTheTapWasAddedFail() throws {
        func run(_ current: [UInt32]?) throws -> Int {
            try ChannelMapper.tapBufferByStreamDiff(
                before: [239], after: [239, 241], streamChannels: [32, 32], inputBuffers: [32, 32],
                tapChannels: 32, interleaved: true, currentStreams: current)
        }
        #expect(try run([239, 241]) == 1)
        #expect(try run(nil) == 1)
        #expect(throws: RouterError.self) { try run([239, 242]) }
        #expect(throws: RouterError.self) { try run([239]) }
        #expect(throws: RouterError.self) { try run([241, 239]) }
        #expect(throws: RouterError.self) { try run([]) }
    }

    @Test func theNewStreamIsTheTapAtItsIndex() throws {
        #expect(try diff(before: [239], after: [239, 240]) == 1)
        // The order differs from "tap last": the new stream sits first.
        #expect(try diff(before: [239], after: [240, 239]) == 0)
        #expect(try diff(before: [10, 11], after: [10, 99, 11], buffers: [2, 32, 2], tap: 32) == 1)
        #expect(try diff(before: [], after: [5], buffers: [2], tap: 2) == 0)
    }

    @Test func noNewStreamOrTwoNewStreamsFail() {
        #expect(throws: RouterError.self) { try diff(before: [239, 240], after: [239, 240]) }
        #expect(throws: RouterError.self) { try diff(before: [239], after: [239, 240, 241], buffers: [32, 32, 32]) }
        #expect(throws: RouterError.self) { try diff(before: [239], after: []) }
    }

    @Test func aReorderedOrRemovedOldStreamFails() {
        #expect(throws: RouterError.self) {
            try diff(before: [1, 2], after: [2, 1, 3], buffers: [2, 2, 2], tap: 2)
        }
        #expect(throws: RouterError.self) { try diff(before: [1, 2], after: [1, 3], buffers: [2, 2], tap: 2) }
    }

    @Test func channelCountsPerStreamMustMatchTheBuffers() {
        #expect(throws: RouterError.self) { try diff(before: [239], after: [239, 240], channels: [32, 2]) }
        #expect(throws: RouterError.self) { try diff(before: [239], after: [239, 240], channels: [32]) }
        // The new stream does not have the tap's channel count.
        #expect(throws: RouterError.self) { try diff(before: [239], after: [239, 240], buffers: [32, 2]) }
    }

    @Test func aNonInterleavedTapFallsBack() throws {
        #expect(throws: RouterError.self) {
            try diff(before: [1], after: [1, 2], buffers: [2, 1, 1], tap: 2, interleaved: false)
        }
        // Everything else fits, only the tap is not interleaved.
        #expect(throws: RouterError.self) {
            try diff(before: [1], after: [1, 2], buffers: [2, 2], tap: 2, interleaved: false)
        }
        #expect(try diff(before: [1], after: [1, 2], buffers: [2, 2], tap: 2, interleaved: true) == 1)
    }

    @Test func theDiffNamesTheBufferOnTheSymmetricX32List() throws {
        let found = try choose([32, 32], deviceInputs: [32], diff: 1)
        #expect(found.range == 1..<2)
        #expect(found.choice == .streamDiff)
        #expect(try choose([32, 32], deviceInputs: [32], diff: 0).range == 0..<1)
    }

    @Test func theOverrideBeatsTheDiff() throws {
        let found = try choose([32, 32], override: 0, diff: 1)
        #expect(found.range == 0..<1)
        #expect(found.choice == .override)
    }

    @Test func aDiffBufferOfTheWrongShapeFallsBackToTheRules() throws {
        // Diff says buffer 0 (32 channels) but the tap has 2: the unique shape rule decides.
        let found = try choose([32, 2], channels: 2, diff: 0)
        #expect(found.range == 1..<2)
        #expect(found.choice == .uniqueShape)
        #expect(throws: RouterError.self) { try choose([32, 32], diff: 5) }
        #expect(throws: RouterError.self) { try choose([32, 32], diff: -1) }
        #expect(throws: RouterError.self) { try choose([32, 32], diff: nil) }
    }

    @Test func aDiffBufferIsUsedForAnInterleavedShapeAtTheEnd() throws {
        // Diff index 1 of [32, 2] with a stereo tap.
        #expect(try choose([32, 2], channels: 2, diff: 1).choice == .streamDiff)
    }

    @Test func aTapOfTheDeviceInputShapeIsRefusedWithoutTheOrderEvidence() {
        #expect(throws: RouterError.ambiguousTapStream(device: "X32", buffers: [32, 32], tapShape: [32])) {
            try choose([32, 32])
        }
    }

    @Test func aSymmetricListCannotProveTheOrderAndIsRefused() {
        // Device [32] and tap [32]: device+tap and tap+device are the same list.
        #expect(throws: RouterError.unprovableTapOrder(device: "X32", buffers: [32, 32], tapShape: [32])) {
            try choose([32, 32], deviceInputs: [32])
        }
        #expect(throws: RouterError.unprovableTapOrder(device: "X32", buffers: [1, 1, 1, 1], tapShape: [1, 1])) {
            try choose([1, 1, 1, 1], channels: 2, interleaved: false, deviceInputs: [1, 1])
        }
        // Two device inputs of the same shape: still the same list in both orders.
        #expect(throws: RouterError.unprovableTapOrder(device: "X32", buffers: [32, 32, 32], tapShape: [32])) {
            try choose([32, 32, 32], deviceInputs: [32, 32])
        }
        let text = "\(RouterError.unprovableTapOrder(device: "X32", buffers: [32, 32], tapShape: [32]))"
        #expect(text.contains("--tap-buffer"))
        #expect(text.contains("[32, 2]"))
        #expect(text.contains("--tap-buffer 1"))
    }

    @Test func theExplicitBufferWorksOnASymmetricList() throws {
        for index in [0, 1] {
            let found = try choose([32, 32], deviceInputs: [32], override: index)
            #expect(found.range == index..<index + 1)
            #expect(found.choice == .override)
        }
    }

    @Test func anAsymmetricListExcludesTheOtherOrder() throws {
        // Device [2, 32] then tap [32] is [2, 32, 32]. Tap first would be [32, 2, 32].
        let found = try choose([2, 32, 32], deviceInputs: [2, 32])
        #expect(found.range == 2..<3)
        #expect(found.choice == .lastByMeasuredOrder)
    }

    @Test func theOrderRuleNeedsTheListToBeExactlyDeviceInputsPlusTheTap() throws {
        // The device reports other buffers than the aggregate holds before the tap.
        #expect(throws: RouterError.self) { try choose([32, 32], deviceInputs: [16]) }
        #expect(throws: RouterError.self) { try choose([32, 32], deviceInputs: []) }
        // More buffers than device inputs plus the tap.
        #expect(throws: RouterError.self) { try choose([32, 32, 32], deviceInputs: [32]) }
        #expect(throws: RouterError.self) { try choose([32, 32], deviceInputs: [32, 32]) }
        // The shape matches twice but not at the end of the list.
        #expect(throws: RouterError.self) { try choose([32, 32, 2], deviceInputs: [32, 32]) }
        #expect(throws: RouterError.self) { try choose([32, 32, 2], deviceInputs: [32, 2]) }
        // The tap would come first. The measured order is device inputs first.
        #expect(throws: RouterError.self) { try choose([32, 2, 32], deviceInputs: [2, 32]) }
        let found = try choose([2, 32, 32], deviceInputs: [2, 32])
        #expect(found.range == 2..<3)
    }

    @Test func theOrderRuleOnlyAppliesWhenTheShapeIsAmbiguous() throws {
        let unique = try choose([32, 2], channels: 2, deviceInputs: [32])
        #expect(unique.range == 1..<2)
        #expect(unique.choice == .uniqueShape)
        let first = try choose([2, 32], channels: 2, deviceInputs: [32])
        #expect(first.range == 0..<1)
        #expect(first.choice == .uniqueShape)
    }

    @Test func aNonInterleavedTapUsesTheOrderRuleToo() throws {
        let found = try choose([1, 1, 2, 1, 1], channels: 2, interleaved: false, deviceInputs: [1, 1, 2])
        #expect(found.range == 3..<5)
        #expect(found.choice == .lastByMeasuredOrder)
    }

    @Test func theOverrideNamesTheBufferAndChecksItsShape() throws {
        let second = try choose([32, 32], override: 1)
        #expect(second.range == 1..<2)
        #expect(second.choice == .override)
        let first = try choose([32, 32], override: 0)
        #expect(first.range == 0..<1)
        #expect(first.choice == .override)
        #expect(try choose([32, 2], channels: 2, interleaved: true, override: 1).range == 1..<2)
        #expect(throws: RouterError.self) { try choose([32, 2], override: 1) }
        #expect(throws: RouterError.self) { try choose([32, 32], override: 2) }
        #expect(throws: RouterError.self) { try choose([32, 32], override: -1) }
        #expect(throws: RouterError.self) { try choose([32, 1, 1], channels: 2, interleaved: false, override: 2) }
        #expect(try choose([32, 1, 1], channels: 2, interleaved: false, override: 1).range == 1..<3)
    }

    @Test func aDeviceInputNeverReachesTheOutputWithA32ChannelTap() throws {
        // 32 device inputs full of 7s, then a 32 channel tap whose channel n holds 100 + n.
        let layout = ChannelLayout(channelsPerBuffer: [32, 32])
        let found = try ChannelMapper.chooseTapBuffers(
            in: layout, tapChannels: 32, interleaved: true, deviceInputBuffers: [32], override: 1)
        for (source, expected) in [(1, (100, 101)), (5, (104, 105)), (31, (130, 131))] {
            let routes = try ChannelMapper.routes(
                source: ChannelLayout(channelsPerBuffer: Array(layout.channelsPerBuffer[found.range])),
                destination: ChannelLayout(channelsPerBuffer: [8]),
                pair: Samples.pair(3),
                sourceBufferOffset: found.range.lowerBound,
                sourcePair: Samples.pair(source)
            )
            #expect(routes.map(\.sourceBuffer) == [1, 1])
            let input = Buffers(channelsPerBuffer: [32, 32], frames: 2) { buffer, _, channel in
                buffer == 0 ? 7 : Float(100 + channel)
            }
            let output = Buffers(channelsPerBuffer: [8], frames: 2)
            render(routes, input: input, output: output)
            #expect(output.sample(buffer: 0, frame: 1, channel: 2) == Float(expected.0))
            #expect(output.sample(buffer: 0, frame: 1, channel: 3) == Float(expected.1))
            for channel in [0, 1, 4, 5, 6, 7] {
                #expect(output.sample(buffer: 0, frame: 1, channel: channel) == 0)
            }
        }
    }

    @Test func theSourcePairPicksTheChannelsOfTheTap() throws {
        let routes = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: [32]),
            destination: ChannelLayout(channelsPerBuffer: [4]),
            pair: Samples.pair(1),
            sourcePair: Samples.pair(31)
        )
        #expect(routes.map(\.sourceChannel) == [30, 31])
        let defaults = try ChannelMapper.routes(
            source: ChannelLayout(channelsPerBuffer: [32]),
            destination: ChannelLayout(channelsPerBuffer: [4]),
            pair: Samples.pair(1)
        )
        #expect(defaults.map(\.sourceChannel) == [0, 1])
    }

    @Test func aSourcePairBeyondTheTapIsRefused() {
        for (layout, first) in [([2], 2), ([2], 3), ([32], 32), ([1], 2), ([1, 1], 2)] {
            #expect(throws: RouterError.self, "layout \(layout) pair \(first)") {
                try ChannelMapper.routes(
                    source: ChannelLayout(channelsPerBuffer: layout),
                    destination: ChannelLayout(channelsPerBuffer: [4]),
                    pair: Samples.pair(1),
                    sourcePair: Samples.pair(first)
                )
            }
        }
    }

    // MARK: Which channels carry signal

    private func flags(_ input: Buffers, count: Int) -> [UInt32] {
        let memory = UnsafeMutablePointer<UInt32>.allocate(capacity: count + 2)
        memory.initialize(repeating: 0, count: count + 2)
        defer { memory.deallocate() }
        ChannelMapper.markActive(input: input.list.unsafePointer, flags: memory, flagCount: count)
        return Array(UnsafeBufferPointer(start: memory, count: count + 2))
    }

    @Test func markActiveFlagsChannelsWithSignalOverAllBuffers() {
        // Buffer 0 has 3 channels, buffer 1 has 2. Signal on global channel 1, and on global
        // channel 3 in the last frame only. Global channel 4 holds negative zero.
        let input = Buffers(channelsPerBuffer: [3, 2], frames: 4) { buffer, frame, channel in
            if buffer == 0 && channel == 1 { return 0.5 }
            if buffer == 1 && channel == 0 { return frame == 3 ? -0.25 : 0 }
            if buffer == 1 && channel == 1 { return -0.0 }
            return 0
        }
        #expect(flags(input, count: 5) == [0, 1, 0, 1, 0, 0, 0])
    }

    @Test func markActiveStaysInsideTheFlagMemory() {
        let input = Buffers(channelsPerBuffer: [3, 2], frames: 2) { _, _, _ in 1 }
        // Only 4 flags. Global channel 4 is not recorded, the two words behind stay 0.
        #expect(flags(input, count: 4) == [1, 1, 1, 1, 0, 0])
    }

    @Test func activitySeparatesTapAndDeviceChannels() {
        let found = ChannelMapper.activity(active: [1, 32, 33, 63], inputBuffers: [32, 32], tapBuffers: 1..<2)
        #expect(found.device == [2])
        #expect(found.tap == [1, 2, 32])
        let tapFirst = ChannelMapper.activity(active: [0, 1, 2], inputBuffers: [2, 32], tapBuffers: 0..<1)
        #expect(tapFirst.tap == [1, 2])
        #expect(tapFirst.device == [1])
        let split = ChannelMapper.activity(active: [0, 1, 2], inputBuffers: [1, 1, 1], tapBuffers: 1..<3)
        #expect(split.device == [1])
        #expect(split.tap == [1, 2])
        let around = ChannelMapper.activity(active: [0, 2, 4], inputBuffers: [2, 2, 2], tapBuffers: 1..<2)
        #expect(around.device == [1, 3])
        #expect(around.tap == [1])
        let none = ChannelMapper.activity(active: [], inputBuffers: [32, 2], tapBuffers: 1..<2)
        #expect(none.tap.isEmpty && none.device.isEmpty)
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

/// Runs `render` and then `measure` over the same buffers, like the IO proc with the meter on.
private func measure(
    _ routes: [ChannelRoute], input: Buffers, output: Buffers, meter: MeterBlock, renderFirst: Bool = true
) {
    if renderFirst { render(routes, input: input, output: output) }
    routes.withUnsafeBufferPointer { buffer in
        ChannelMapper.measure(
            routes: buffer.baseAddress!,
            routeCount: buffer.count,
            input: input.list.unsafePointer,
            output: UnsafePointer(output.list.unsafeMutablePointer),
            meter: meter
        )
    }
}

struct MeterMeasureTests {
    private let tapRoutes = [route(1, 0, 0, 2), route(1, 1, 0, 3)]

    /// A 32 channel device input full of 7s, then a stereo tap with 0.5 left and -0.25 right.
    private func tapInput(frames: Int = 4, left: Float = 0.5, right: Float = -0.25) -> Buffers {
        Buffers(channelsPerBuffer: [32, 2], frames: frames) { buffer, _, channel in
            buffer == 0 ? 7 : (channel == 0 ? left : right)
        }
    }

    /// Collects twice: the first call only primes the scheme, the second returns the written slot.
    private func read(_ meter: MeterBlock) throws -> MeterReading {
        #expect(meter.collect() == nil)
        return try #require(meter.collect())
    }

    @Test func peakRmsAndFramesOfTapAndOutput() throws {
        let meter = MeterBlock.allocate(channels: 2)
        defer { meter.deallocate() }
        measure(tapRoutes, input: tapInput(), output: Buffers(channelsPerBuffer: [8], frames: 4), meter: meter)
        let reading = try read(meter)
        let rms = (0.15625).squareRoot()  // (0.25 + 0.0625) / 2
        for level in [reading.input, reading.output] {
            #expect(level.peak == 0.5)
            #expect(abs(level.rms - rms) < 1e-12)
            #expect(level.samples == 8)
        }
        #expect(reading.frames == 4)
    }

    @Test func deviceInputsAreNotMeasured() throws {
        let meter = MeterBlock.allocate(channels: 2)
        defer { meter.deallocate() }
        measure(tapRoutes, input: tapInput(), output: Buffers(channelsPerBuffer: [8], frames: 4), meter: meter)
        #expect(try read(meter).input.peak == 0.5)
    }

    @Test func theOutputIsReadBackNotAssumed() throws {
        let meter = MeterBlock.allocate(channels: 2)
        defer { meter.deallocate() }
        // No render: the output stays silent while the tap is not.
        measure(
            tapRoutes, input: tapInput(), output: Buffers(channelsPerBuffer: [8], frames: 4), meter: meter,
            renderFirst: false)
        let reading = try read(meter)
        #expect(reading.input.peak == 0.5)
        #expect(reading.output.peak == 0)
        #expect(reading.output.samples == 8)
    }

    @Test func aReadingCoversOneIntervalAndThenResets() throws {
        let meter = MeterBlock.allocate(channels: 2)
        defer { meter.deallocate() }
        let output = Buffers(channelsPerBuffer: [8], frames: 4)
        measure(tapRoutes, input: tapInput(left: 0.5, right: 0.5), output: output, meter: meter)
        #expect(meter.collect() == nil)  // flips: later writes go to the other slot
        measure(tapRoutes, input: tapInput(left: 0.25, right: 0.25), output: output, meter: meter)
        #expect(try #require(meter.collect()).input.peak == 0.5)  // the first interval only
        let second = try #require(meter.collect())
        #expect(second.input.peak == 0.25)  // the second interval only, nothing of the first
        #expect(second.input.samples == 8)
        let empty = try #require(meter.collect())
        #expect(empty.input.samples == 0)
        #expect(empty.input.peakDBFS == -Double.infinity)
        #expect(empty.input.rms == 0)
        #expect(empty.output.samples == 0)
        #expect(empty.output.peak == 0)
        #expect(empty.frames == 0)
    }

    private func samplesSeen(_ routes: [ChannelRoute], input: Buffers, output: Buffers) throws -> (UInt64, UInt64) {
        let meter = MeterBlock.allocate(channels: routes.count)
        defer { meter.deallocate() }
        measure(routes, input: input, output: output, meter: meter, renderFirst: false)
        let reading = try read(meter)
        return (reading.input.samples, reading.output.samples)
    }

    @Test func routesJustPastTheBuffersAreNotMeasured() throws {
        let hiddenInput = Buffers(channelsPerBuffer: [2], frames: 2, hiddenBuffer: true) { _, _, _ in 1 }
        let plainOutput = Buffers(channelsPerBuffer: [2], frames: 2)
        #expect(try samplesSeen([route(1, 0, 0, 0)], input: hiddenInput, output: plainOutput) == (0, 0))
        let plainInput = Buffers(channelsPerBuffer: [2], frames: 2) { _, _, _ in 1 }
        let hiddenOutput = Buffers(channelsPerBuffer: [2], frames: 2, hiddenBuffer: true)
        #expect(try samplesSeen([route(0, 0, 1, 0)], input: plainInput, output: hiddenOutput) == (0, 0))
        #expect(try samplesSeen([route(0, 2, 0, 0)], input: plainInput, output: plainOutput) == (0, 0))
        #expect(try samplesSeen([route(0, 0, 0, 2)], input: plainInput, output: plainOutput) == (0, 0))
    }

    @Test func aShorterOutputLimitsWhatIsMeasured() throws {
        let input = Buffers(channelsPerBuffer: [2], frames: 4, padFrames: 4) { _, _, _ in 1 }
        let output = Buffers(channelsPerBuffer: [2], frames: 2, padFrames: 4)
        #expect(try samplesSeen([route(0, 0, 0, 0)], input: input, output: output) == (2, 2))
    }

    @Test func aShorterInputLimitsWhatIsMeasured() throws {
        // Bytes not divided by the channel count would read the canary frames behind the input.
        let input = Buffers(channelsPerBuffer: [2], frames: 2, padFrames: 4) { _, _, _ in 1 }
        let output = Buffers(channelsPerBuffer: [2], frames: 6)
        #expect(try samplesSeen([route(0, 0, 0, 0)], input: input, output: output) == (2, 2))
    }

    @Test func badSamplesAreSkipped() throws {
        let meter = MeterBlock.allocate(channels: 2)
        defer { meter.deallocate() }
        let input = Buffers(channelsPerBuffer: [2], frames: 3) { _, frame, channel in
            [Float.nan, Float.infinity, 0.5][frame] * (channel == 0 ? 1 : -1)
        }
        measure(
            [route(0, 0, 0, 0), route(0, 1, 0, 1)], input: input,
            output: Buffers(channelsPerBuffer: [2], frames: 3), meter: meter)
        let level = try read(meter).input
        #expect(level.peak == 0.5)
        #expect(level.samples == 2)
        #expect(level.rms == 0.5)
    }

    @Test func routesOutsideTheBuffersAddNothing() throws {
        let meter = MeterBlock.allocate(channels: 2)
        defer { meter.deallocate() }
        let output = Buffers(channelsPerBuffer: [2], frames: 2)
        measure(
            [route(5, 0, 0, 0), route(0, 9, 0, 0), route(0, 0, 3, 0), route(0, 0, 0, 9)],
            input: Buffers(channelsPerBuffer: [2], frames: 2) { _, _, _ in 1 }, output: output, meter: meter)
        #expect(try read(meter).input.samples == 0)
    }

    @Test func framesFollowTheChannelCount() throws {
        let meter = MeterBlock.allocate(channels: 2)
        defer { meter.deallocate() }
        measure(tapRoutes, input: tapInput(frames: 5), output: Buffers(channelsPerBuffer: [8], frames: 5), meter: meter)
        #expect(try read(meter).frames == 5)
    }
}

struct LevelTests {
    @Test func dBFSOfKnownValues() {
        #expect(Level.dBFS(1) == 0)
        #expect(abs(Level.dBFS(0.5) - -6.0206) < 1e-4)
        #expect(abs(Level.dBFS(0.1) - -20) < 1e-9)
        #expect(Level.dBFS(0) == -Double.infinity)
        #expect(Level.dBFS(-0.5) == -Double.infinity)
    }

    @Test func accumulatorTracksPeakOfNegativeSamplesAndSumOfSquares() {
        var accumulator = LevelAccumulator()
        for sample: Float in [0.5, -0.75, 0.25] { accumulator.add(sample) }
        let level = LevelReading(accumulator)
        #expect(level.peak == 0.75)
        #expect(level.samples == 3)
        #expect(abs(level.rms - ((0.25 + 0.5625 + 0.0625) / 3).squareRoot()) < 1e-12)
    }

    @Test func aFullScaleSineHasAnRmsOfMinus3dB() {
        var accumulator = LevelAccumulator()
        for index in 0..<48000 { accumulator.add(Float(sin(2 * Double.pi * 1000 * Double(index) / 48000))) }
        let level = LevelReading(accumulator)
        #expect(abs(level.peakDBFS) < 0.01)
        #expect(abs(level.rmsDBFS - -3.0103) < 0.01)
    }

    @Test func silenceIsMinusInfinity() {
        let level = LevelReading(LevelAccumulator())
        #expect(level.peakDBFS == -Double.infinity)
        #expect(level.rmsDBFS == -Double.infinity)
    }
}
