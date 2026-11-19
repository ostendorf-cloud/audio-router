// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RouterCore

struct StreamDiffLogTests {
    @Test func aNewLogHasNotEvaluatedAsItsOutcome() {
        let log = StreamDiffLog()
        #expect(log.outcome == "stream id diff: not used (not evaluated)")
        #expect(log.lines == ["stream id diff: not used (not evaluated)"])
    }

    @Test func aUsedDiffNamesTheIndex() {
        var log = StreamDiffLog()
        log.step("A [239]")
        log.step("B [239, 240]")
        log.used(index: 1)
        #expect(log.outcome == "stream id diff: used, tap at index 1")
        #expect(
            log.lines == [
                "stream id diff step: A [239]", "stream id diff step: B [239, 240]",
                "stream id diff: used, tap at index 1",
            ])
    }

    @Test(arguments: [
        (RouterError.coreAudio(operation: "set kAudioAggregateDevicePropertyTapList ('tap#')", status: -50), "-50"),
        (
            RouterError.coreAudio(
                operation: "set kAudioSubTapPropertyDriftCompensation ('drft')", status: 2_003_329_396),
            "2003329396 (what)"
        ),
        (
            RouterError.coreAudio(operation: "read property tap#", status: 560_947_818),
            "560947818"
        ),
    ])
    func aFailedStepCarriesOperationSelectorAndStatus(error: RouterError, status: String) {
        var log = StreamDiffLog()
        log.fail("\(error)")
        #expect(log.outcome.hasPrefix("stream id diff: not used ("))
        #expect(log.outcome.contains("OSStatus \(status)"))
        let named = ["kAudioAggregateDevicePropertyTapList", "drft", "tap#"].contains { log.outcome.contains($0) }
        #expect(named)
    }

    @Test func everyFailureReasonOfTheDecisionLogicShowsInTheOutcome() {
        let cases: [(before: [UInt32], after: [UInt32], needle: String)] = [
            ([239, 240], [239, 240], "0 new input streams"),
            ([239], [239, 240, 241], "2 new input streams"),
            ([1, 2], [2, 1, 3], "the old streams changed"),
        ]
        for item in cases {
            var log = StreamDiffLog()
            do {
                _ = try ChannelMapper.tapBufferByStreamDiff(
                    before: item.before, after: item.after, streamChannels: [32, 32, 32], inputBuffers: [32, 32, 32],
                    tapChannels: 32, interleaved: true)
                Issue.record("must fail: \(item.needle)")
            } catch {
                log.fail("\(error)")
            }
            #expect(log.outcome.contains(item.needle), "\(log.outcome)")
            #expect(log.outcome.hasPrefix("stream id diff: not used ("))
        }
    }

    @Test func theNoSubTapReasonAndTheCompositionFallbackAreListed() {
        var log = StreamDiffLog()
        log.step("aggregate 237 created with the sub device only, input streams A [239]")
        let reason = "the aggregate has no sub tap (kAudioAggregateDevicePropertySubTapList) after the tap list was set"
        log.fail("\(RouterError.unsupportedFormat(reason))")
        log.step("created the aggregate again with the tap in its composition, no diff possible")
        #expect(log.outcome.contains("no sub tap"))
        #expect(log.outcome.contains("kAudioAggregateDevicePropertySubTapList"))
        #expect(log.lines.count == 4)
        #expect(log.lines.last == log.outcome)
    }

    @Test func aDriftFailureDoesNotAbortTheDiffAndTheTapIsFoundAtIndexOne() throws {
        // The owner's run: A is [239], the tap list was set, the drift property failed with !obj.
        var log = StreamDiffLog()
        log.step("aggregate 237 created with the sub device only, input streams A [239]")
        log.step("set kAudioAggregateDevicePropertyTapList ('tap#') to [x]: OSStatus 0")
        let status = RouterError.coreAudio(operation: "set 'drft'", status: 560_947_818)
        log.driftNotSet(reason: "\(status)")
        #expect(log.failure == nil)
        #expect(log.steps.last?.hasPrefix("drift compensation not set (") == true)
        #expect(log.steps.last?.contains("OSStatus 560947818 (!obj)") == true)
        #expect(log.steps.last?.hasSuffix("tap shares the main device clock") == true)
        // The diff then reads B and decides.
        let index = try ChannelMapper.tapBufferByStreamDiff(
            before: [239], after: [239, 240], streamChannels: [32, 32], inputBuffers: [32, 32],
            tapChannels: 32, interleaved: true)
        log.used(index: index)
        #expect(index == 1)
        #expect(log.outcome == "stream id diff: used, tap at index 1")
    }

    @Test func driftIsSkippedForTheDeviceStreamAndTheDiffIsUsedOnlyThere() {
        #expect(!StreamDiffPlan.setsDrift(mode: .deviceStream))
        #expect(StreamDiffPlan.setsDrift(mode: .stereoMixdown))
        #expect(StreamDiffPlan.usesDiff(mode: .deviceStream))
        #expect(!StreamDiffPlan.usesDiff(mode: .stereoMixdown))
        #expect(StreamDiffPlan.driftSkipped.contains("reasoning, not header text"))
    }

    @Test func theFirstFailureStaysAndBeatsALaterUse() {
        var log = StreamDiffLog()
        log.fail("first")
        log.fail("second")
        log.used(index: 1)
        #expect(log.failure == "first")
        #expect(log.outcome == "stream id diff: not used (first)")
        #expect(log.steps == ["failed: first", "failed: second"])
    }

    @Test func theRefusalCarriesTheReasonAndTheDiffOutcome() {
        var log = StreamDiffLog()
        let step = RouterError.coreAudio(operation: "set kAudioAggregateDevicePropertyTapList ('tap#')", status: -50)
        log.fail("\(step)")
        let error = RouterError.refusedWithDiff(
            reason: "\(RouterError.unprovableTapOrder(device: "X-USB", buffers: [32, 32], tapShape: [32]))",
            diff: log.outcome)
        let text = "\(error)"
        #expect(text.contains("Cannot tell the tap from the input channels of X-USB"))
        #expect(text.contains("--tap-buffer"))
        #expect(text.contains("stream id diff: not used ("))
        #expect(text.contains("OSStatus -50"))
        #expect(text.hasSuffix(log.outcome))
    }

    @Test func theRefusalDiagnosticsPrintTheStartLinesAndTheOutcome() {
        var log = StreamDiffLog()
        log.step("aggregate 237 created with the sub device only, input streams A [239]")
        log.fail("set failed")
        let lines = Formatting.refusalDiagnostics(
            tap: StreamFormatInfo(sampleRate: 48000, channels: 32, interleaved: true),
            inputBuffers: [32, 32],
            inputStreams: [
                StreamFormatInfo(sampleRate: 48000, channels: 32, interleaved: true),
                StreamFormatInfo(sampleRate: 48000, channels: 32, interleaved: true),
            ],
            tapIsMixdown: false, tapIsExclusive: false, diff: log, probes: ["probe: a"])
        #expect(lines[0] == "tap format: 48000 Hz, 32 channels, interleaved")
        #expect(lines[1] == "aggregate input buffers: [32, 32], tap buffer not chosen")
        #expect(lines[2].hasPrefix("aggregate input streams: 48000 Hz, 32 channels, interleaved; "))
        #expect(lines[3] == "tap description: mixdown false, exclusive false")
        #expect(lines[4].hasPrefix("stream id diff step: aggregate 237 created with the sub device only"))
        #expect(lines.contains("stream id diff: not used (set failed)"))
        #expect(lines.last == "probe: a")
        let outcomeIndex = lines.firstIndex(of: "stream id diff: not used (set failed)")
        #expect(outcomeIndex == lines.count - 2)
    }
}
