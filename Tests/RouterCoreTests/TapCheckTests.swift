// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RouterCore

struct TapCheckTests {
    private let pair = ChannelPair.firstPair

    @Test func signalInsideThePairIsConsistent() {
        #expect(TapCheck.verdict(tap: [1, 2], device: [1, 2, 3, 31, 32], source: pair) == .consistent)
        #expect(TapCheck.verdict(tap: [1], device: [], source: pair) == .consistent)
        #expect(TapCheck.verdict(tap: [2], device: [5], source: pair) == .consistent)
    }

    @Test func signalOutsideThePairIsNamed() {
        #expect(TapCheck.verdict(tap: [3, 4], device: [], source: pair) == .outsideSource(channels: [3, 4]))
        #expect(TapCheck.verdict(tap: [1, 2, 7], device: [], source: pair) == .outsideSource(channels: [7]))
        #expect(TapCheck.verdict(tap: [1], device: [], source: pair) == .consistent)
    }

    @Test func theSourcePairDecidesWhatIsOutside() throws {
        let other = try ChannelPair(first: 3, flag: "--source-channels")
        #expect(TapCheck.verdict(tap: [3, 4], device: [], source: other) == .consistent)
        #expect(TapCheck.verdict(tap: [1, 2], device: [], source: other) == .outsideSource(channels: [1, 2]))
        #expect(TapCheck.verdict(tap: [2, 3], device: [], source: other) == .outsideSource(channels: [2]))
        #expect(TapCheck.verdict(tap: [4, 5], device: [], source: other) == .outsideSource(channels: [5]))
    }

    @Test func aSilentTapWithAHotDeviceInputIsSuspect() {
        #expect(TapCheck.verdict(tap: [], device: [1], source: pair) == .tapSilentDeviceActive)
    }

    @Test func nothingAnywhereSaysNothing() {
        #expect(TapCheck.verdict(tap: [], device: [], source: pair) == .consistent)
    }

    @Test func theWarningNamesBufferMethodAndTheRetryFlags() throws {
        let text = try #require(
            TapCheck.warning(tap: [5, 6], device: [], source: pair, buffer: 1, choice: .streamDiff))
        #expect(text.hasPrefix("warning: tap buffer 1 was picked by stream id diff"))
        #expect(text.contains("signal on tap channels 5,6, outside --source-channels 1,2"))
        #expect(text.contains("--tap-buffer <n>"))
        #expect(text.contains("--source-channels <a>,<b>"))
    }

    @Test func theWarningNamesTheMethodForEveryChoice() throws {
        let expected: [(TapBufferChoice, String)] = [
            (.streamDiff, "by stream id diff"),
            (.override, "by --tap-buffer"),
            (.uniqueShape, "by the only buffer of the tap shape"),
            (.lastByMeasuredOrder, "by the last buffer of the tap shape"),
        ]
        for (choice, words) in expected {
            let text = try #require(
                TapCheck.warning(tap: [], device: [3], source: pair, buffer: 0, choice: choice))
            #expect(text.contains(words), "\(text)")
        }
    }

    @Test func aSilentTapWarningNamesTheDeviceChannels() throws {
        let text = try #require(
            TapCheck.warning(tap: [], device: [1, 31], source: pair, buffer: 0, choice: .override))
        #expect(text.contains("no signal on the tap, but on device input channels 1,31"))
        #expect(text.hasPrefix("warning: tap buffer 0 was picked by --tap-buffer"))
    }

    @Test func aConsistentPickHasNoWarning() {
        #expect(TapCheck.warning(tap: [1, 2], device: [1], source: pair, buffer: 1, choice: .streamDiff) == nil)
        #expect(TapCheck.warning(tap: [], device: [], source: pair, buffer: 1, choice: .streamDiff) == nil)
    }

    // MARK: Report over route info and the active flags

    private func info(
        buffers: [Int], tap: Range<Int>, choice: TapBufferChoice, source: ChannelPair = .firstPair
    ) -> RouteInfo {
        RouteInfo(
            tap: StreamFormatInfo(sampleRate: 48000, channels: 32, interleaved: true),
            inputBuffers: buffers, tapBuffers: tap, outputBuffers: [32],
            inputStreams: [], outputStreams: [], aggregateSampleRate: 48000, deviceSampleRate: 48000,
            tapBufferChoice: choice, sourceChannels: source, tapMode: .deviceStream)
    }

    @Test func theRightBufferOfTheX32GivesNoWarning() {
        // The owner's run: tap in buffer 1, tap channels 1,2, device noise 1,2,3,31,32.
        let active = [0, 1, 2, 30, 31, 32, 33]
        let report = TapCheck.report(active: active, info: info(buffers: [32, 32], tap: 1..<2, choice: .streamDiff))
        #expect(report.warning == nil)
        #expect(report.activity.hasPrefix("signal on tap channels: 1,2 | on device input channels"))
    }

    @Test func theWrongBufferWarnsWithTheBufferIndexAndTheMethod() throws {
        // The app is really in buffer 1, the diff picked buffer 0: tap side shows the device noise.
        let active = [0, 1, 2, 30, 31, 32, 33]
        let report = TapCheck.report(active: active, info: info(buffers: [32, 32], tap: 0..<1, choice: .streamDiff))
        let text = try #require(report.warning)
        #expect(text.contains("tap buffer 0 was picked by stream id diff"))
        #expect(text.contains("outside --source-channels 1,2"))
    }

    @Test func aWrongBufferWithOnlyThePairNoiseWarnsByTheSilentTap() throws {
        // Picked buffer 0 holds nothing while the real tap in buffer 1 carries the app.
        let active = [32, 33]
        let report = TapCheck.report(active: active, info: info(buffers: [32, 32], tap: 0..<1, choice: .override))
        let text = try #require(report.warning)
        #expect(text.contains("picked by --tap-buffer"))
        #expect(text.contains("no signal on the tap"))
    }

    @Test func anAppOnAnotherPairWarnsAndTheMatchingSourcePairDoesNot() throws {
        let active = [34, 35]
        let layout = info(buffers: [32, 32], tap: 1..<2, choice: .streamDiff)
        #expect(TapCheck.report(active: active, info: layout).warning != nil)
        let moved = info(
            buffers: [32, 32], tap: 1..<2, choice: .streamDiff,
            source: try ChannelPair(first: 3, flag: "--source-channels"))
        #expect(TapCheck.report(active: active, info: moved).warning == nil)
    }

    @Test func aMultichannelAppInsideThePairDoesNotWarn() {
        let layout = info(buffers: [32, 32], tap: 1..<2, choice: .streamDiff)
        #expect(TapCheck.report(active: [32], info: layout).warning == nil)
        #expect(TapCheck.report(active: [32, 33], info: layout).warning == nil)
    }
}

/// A stereo input device: the aggregate lists `[2, 2]`, the tap shape appears twice.
struct StereoInputDeviceTests {
    private func choose(
        diff: Int?, override: Int? = nil, deviceInputs: [Int]? = [2]
    ) throws -> (range: Range<Int>, choice: TapBufferChoice) {
        try ChannelMapper.chooseTapBuffers(
            in: ChannelLayout(channelsPerBuffer: [2, 2]), tapChannels: 2, interleaved: true,
            deviceName: "USB Stereo", deviceInputBuffers: deviceInputs, override: override, streamDiffBuffer: diff)
    }

    private func diffIndex(before: [UInt32], after: [UInt32], current: [UInt32]? = nil) throws -> Int {
        try ChannelMapper.tapBufferByStreamDiff(
            before: before, after: after, streamChannels: [2, 2], inputBuffers: [2, 2],
            tapChannels: 2, interleaved: true, currentStreams: current)
    }

    @Test func theDiffNamesTheTapOfAStereoInputDevice() throws {
        let index = try diffIndex(before: [100], after: [100, 101], current: [100, 101])
        #expect(index == 1)
        let chosen = try choose(diff: index)
        #expect(chosen.range == 1..<2)
        #expect(chosen.choice == .streamDiff)
    }

    @Test func theDiffMayNameTheFirstStream() throws {
        let index = try diffIndex(before: [100], after: [101, 100])
        #expect(index == 0)
        let chosen = try choose(diff: index)
        #expect(chosen.range == 0..<1)
        #expect(chosen.choice == .streamDiff)
    }

    @Test func withoutTheDiffTheLayoutIsRefusedAndNamesTheDevice() {
        #expect(throws: RouterError.unprovableTapOrder(device: "USB Stereo", buffers: [2, 2], tapShape: [2])) {
            try choose(diff: nil)
        }
        #expect(throws: RouterError.ambiguousTapStream(device: "USB Stereo", buffers: [2, 2], tapShape: [2])) {
            try choose(diff: nil, deviceInputs: nil)
        }
    }

    @Test func aChangedStreamListFailsTheDiffAndTheRouteIsRefused() throws {
        #expect(throws: RouterError.self) {
            try diffIndex(before: [100], after: [100, 101], current: [100, 102])
        }
        #expect(throws: RouterError.self) {
            try diffIndex(before: [100], after: [100, 101], current: [100])
        }
        // The caller then passes no diff index, and the symmetric layout refuses.
        #expect(throws: RouterError.unprovableTapOrder(device: "USB Stereo", buffers: [2, 2], tapShape: [2])) {
            try choose(diff: nil)
        }
    }

    @Test func aDiffIndexOfTheWrongShapeIsIgnoredAndTheLayoutRefuses() {
        #expect(throws: RouterError.self) { try choose(diff: 2) }
        #expect(throws: RouterError.self) { try choose(diff: -1) }
    }

    @Test func tapBufferStillWinsOnAStereoInputDevice() throws {
        #expect(try choose(diff: nil, override: 1).choice == .override)
        #expect(try choose(diff: 1, override: 0).range == 0..<1)
    }
}
