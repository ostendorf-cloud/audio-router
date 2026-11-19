// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RouterCore

private let base = ["route", "--bundle-id", "a", "--device", "b", "--channels", "3,4"]

private func parseRoute(_ extra: [String]) throws -> RouteArguments {
    guard case .route(let arguments) = try ArgumentParser.parse(base + extra) else {
        Issue.record("not a route command")
        throw RouterError.usage("not a route command")
    }
    return arguments
}

struct TapModeParsingTests {
    @Test func theDefaultsAreTheMixdownAndTheFirstPair() throws {
        let arguments = try parseRoute([])
        #expect(arguments.tapMode == .stereoMixdown)
        #expect(arguments.sourceChannels == Samples.pair(1))
        #expect(arguments.tapBuffer == nil)
        #expect(ChannelPair.firstPair == Samples.pair(1))
    }

    @Test func bothModesParse() throws {
        #expect(try parseRoute(["--tap-mode", "stereo-mixdown"]).tapMode == .stereoMixdown)
        #expect(try parseRoute(["--tap-mode", "device-stream"]).tapMode == .deviceStream)
        #expect(TapMode.allCases.count == 2)
    }

    @Test(arguments: ["", "mixdown", "deviceStream", "Device-Stream", "device-stream ", "stereo_mixdown"])
    func anUnknownModeIsRefusedAndNamesTheChoices(value: String) {
        do {
            _ = try parseRoute(["--tap-mode", value])
            Issue.record("\(value) must be refused")
        } catch {
            #expect("\(error)".contains("stereo-mixdown, device-stream"))
        }
    }

    @Test func sourceChannelsParseLikeChannels() throws {
        #expect(try parseRoute(["--source-channels", "5,6"]).sourceChannels == Samples.pair(5))
        #expect(try parseRoute(["--source-channels", "31,32"]).sourceChannels == Samples.pair(31))
    }

    @Test(arguments: ["", "1", "1,3", "0,1", "2,1", "a,b", "1,2,3", "-1,0", "65537,65538"])
    func badSourceChannelsAreRefusedAndNameTheFlag(value: String) {
        do {
            _ = try parseRoute(["--source-channels", value])
            Issue.record("\(value) must be refused")
        } catch {
            #expect("\(error)".contains("--source-channels"))
            #expect(!"\(error)".contains("--channels"))
        }
    }

    @Test func theChannelsFlagStillNamesItself() {
        do {
            _ = try ArgumentParser.parseChannels("1,3")
            Issue.record("must be refused")
        } catch {
            #expect("\(error)".hasPrefix("--channels must be"))
        }
        #expect(throws: RouterError.usage("--channels counts from 1 and stays below 65537, got 0.")) {
            try ChannelPair(first: 0)
        }
    }

    @Test func tapBufferParsesFromZero() throws {
        #expect(try parseRoute(["--tap-buffer", "0"]).tapBuffer == 0)
        #expect(try parseRoute(["--tap-buffer", "1"]).tapBuffer == 1)
    }

    @Test(arguments: ["", "-1", "x", "1.5", "65537"])
    func aBadTapBufferIsRefused(value: String) {
        #expect(throws: RouterError.self) { try parseRoute(["--tap-buffer", value]) }
    }

    @Test func eachNewFlagTakesAValueAndOnlyOnce() {
        for flag in ["--tap-mode", "--source-channels", "--tap-buffer"] {
            #expect(throws: RouterError.self) { try ArgumentParser.parse(base + [flag]) }
        }
        #expect(throws: RouterError.self) {
            try ArgumentParser.parse(base + ["--tap-mode", "device-stream", "--tap-mode", "stereo-mixdown"])
        }
        #expect(throws: RouterError.self) {
            try ArgumentParser.parse(base + ["--source-channels", "1,2", "--source-channels", "3,4"])
        }
        #expect(throws: RouterError.self) {
            try ArgumentParser.parse(base + ["--tap-buffer", "1", "--tap-buffer", "1"])
        }
    }

    @Test func allOptionsTogetherInAnyOrder() throws {
        let arguments = try ArgumentParser.parse([
            "route", "--tap-buffer", "1", "--meter", "--source-channels", "3,4", "--tap-mode", "device-stream",
            "--channels", "5,6", "--device", "dev", "--bundle-id", "x",
        ])
        #expect(
            arguments
                == .route(
                    RouteArguments(
                        bundleID: "x", deviceUID: "dev", channels: Samples.pair(5), meter: true,
                        tapMode: .deviceStream, sourceChannels: Samples.pair(3), tapBuffer: 1)))
    }

    @Test func theUsageNamesTheNewFlags() {
        for text in ["--tap-mode stereo-mixdown|device-stream", "--source-channels", "--tap-buffer"] {
            #expect(ArgumentParser.usage.contains(text))
        }
    }
}

struct TapModeSessionTests {
    private let process = Samples.process(1, "com.apple.QuickTimePlayerX")

    private func plan(
        _ mode: TapMode, source: ChannelPair = Samples.pair(1), tapBuffer: Int? = nil
    ) -> RoutePlan {
        RoutePlan(
            device: Samples.device, channels: Samples.pair(3), appBundleID: "com.apple.QuickTimePlayerX",
            processes: [process], tapMode: mode, sourceChannels: source, tapBuffer: tapBuffer)
    }

    @Test func thePlannerCarriesTheOptionsFromTheArguments() throws {
        let arguments = RouteArguments(
            bundleID: "com.apple.QuickTimePlayerX", deviceUID: "mixer-uid", channels: Samples.pair(3),
            tapMode: .deviceStream, sourceChannels: Samples.pair(5), tapBuffer: 1)
        let plan = try RoutePlanner.plan(arguments, devices: [Samples.device], processes: [process])
        #expect(plan.tapMode == .deviceStream)
        #expect(plan.sourceChannels == Samples.pair(5))
        #expect(plan.tapBuffer == 1)
        let defaults = try RoutePlanner.plan(
            RouteArguments(bundleID: "com.apple.QuickTimePlayerX", deviceUID: "mixer-uid", channels: Samples.pair(3)),
            devices: [Samples.device], processes: [process])
        #expect(defaults.tapMode == .stereoMixdown)
        #expect(defaults.sourceChannels == Samples.pair(1))
        #expect(defaults.tapBuffer == nil)
    }

    @Test func theSessionPassesModeDeviceAndSourceToTheBackend() throws {
        for mode in TapMode.allCases {
            let backend = FakeBackend()
            let session = RouteSession(backend: backend, plan: plan(mode, source: Samples.pair(7), tapBuffer: 1))
            try session.start()
            #expect(backend.tapRequested?.mode == mode)
            #expect(backend.tapRequested?.deviceUID == "mixer-uid")
            #expect(backend.ioRequested?.source == Samples.pair(7))
            #expect(backend.ioRequested?.tapBuffer == 1)
            session.stop()
        }
    }

    @Test func noOverrideStaysNil() throws {
        let backend = FakeBackend()
        try RouteSession(backend: backend, plan: plan(.deviceStream)).start()
        #expect(backend.ioRequested?.tapBuffer == nil)
        #expect(backend.ioRequested?.source == Samples.pair(1))
    }

    @Test func activeChannelsAreOnlyHandedOutWhileTheRouteRuns() throws {
        let backend = FakeBackend()
        backend.setActive([1, 2])
        let session = RouteSession(backend: backend, plan: plan(.deviceStream))
        #expect(session.activeInputChannels() == nil, "not started")
        try session.start()
        #expect(session.activeInputChannels() == [1, 2])
        session.stop()
        #expect(session.activeInputChannels() == nil, "stopped")
    }

    @Test func anExclusiveDeviceStreamTapIsRefusedBeforeAnythingIsCreated() {
        let backend = FakeBackend(exclusiveTap: true)
        #expect(throws: RouterError.self) { try RouteSession(backend: backend, plan: plan(.deviceStream)).start() }
        #expect(backend.calls.isEmpty)
        // The mixdown mode does not read the flag.
        #expect(throws: Never.self) { try RouteSession(backend: backend, plan: plan(.stereoMixdown)).start() }
    }

    @Test func theValidationOnlyRefusesAnExclusiveDeviceStream() throws {
        try TapMode.deviceStream.validateDescription(isExclusive: false)
        try TapMode.stereoMixdown.validateDescription(isExclusive: false)
        try TapMode.stereoMixdown.validateDescription(isExclusive: true)
        #expect(throws: RouterError.self) { try TapMode.deviceStream.validateDescription(isExclusive: true) }
    }

    @Test func theTapInfoRemembersItsMode() {
        #expect(TapInfo(objectID: 1, uid: "u").mode == .stereoMixdown)
        #expect(TapInfo(objectID: 1, uid: "u", mode: .deviceStream).mode == .deviceStream)
    }
}

struct TapModeFormattingTests {
    @Test func theActivityLineNamesTapAndDeviceChannels() {
        #expect(
            Formatting.activity(tap: [1, 2], device: [])
                == "signal on tap channels: 1,2 | on device input channels (noise counts): none")
        #expect(
            Formatting.activity(tap: [], device: [3], preferred: "1,2")
                == "signal on tap channels: none | on device input channels (noise counts): 3"
                + " | device preferred stereo pair: 1,2")
    }

    @Test func theSilenceWarningNamesTheDeviceOnlyInTheDeviceStreamMode() {
        let plain = Formatting.silenceWarning(bundleID: "app", mode: .stereoMixdown, deviceName: "X-USB")
        #expect(plain.contains("permission"))
        #expect(!plain.contains("X-USB"))
        let stream = Formatting.silenceWarning(bundleID: "app", mode: .deviceStream, deviceName: "X-USB")
        #expect(stream.contains("permission"))
        #expect(stream.contains("plays to X-USB"))
        #expect(stream.hasSuffix("\n"))
    }

    @Test func theProbesAndTheDescriptionFlagsAreListed() {
        let info = RouteInfo(
            tap: StreamFormatInfo(sampleRate: 48000, channels: 32, interleaved: true),
            inputBuffers: [32, 32], tapBuffers: 1..<2, outputBuffers: [32],
            inputStreams: [], outputStreams: [], aggregateSampleRate: nil, deviceSampleRate: nil,
            tapIsMixdown: false, tapIsExclusive: true, probes: ["probe: a", "probe: b"])
        let lines = Formatting.routeInfo(info)
        #expect(lines.suffix(3) == ["tap description: mixdown false, exclusive true", "probe: a", "probe: b"])
        #expect(info.preferredStereo == "not available")
    }

    @Test func theRouteInfoSaysHowTheTapBufferWasChosen() {
        func last(_ choice: TapBufferChoice, mode: TapMode = .deviceStream, source: Int = 1) -> String {
            let info = RouteInfo(
                tap: StreamFormatInfo(sampleRate: 48000, channels: 32, interleaved: true),
                inputBuffers: [32, 32], tapBuffers: 1..<2, outputBuffers: [32],
                inputStreams: [], outputStreams: [], aggregateSampleRate: 48000, deviceSampleRate: 48000,
                tapBufferChoice: choice, sourceChannels: Samples.pair(source), tapMode: mode)
            return Formatting.routeInfo(info).first { $0.hasPrefix("tap mode:") } ?? ""
        }
        #expect(
            last(.uniqueShape)
                == "tap mode: device-stream, source channels 1,2, tap buffer: the only buffer of the tap shape")
        let named = last(.override, mode: .stereoMixdown, source: 3)
        #expect(named.hasPrefix("tap mode: stereo-mixdown, source channels 3,4"))
        #expect(last(.override).hasSuffix("tap buffer: named by --tap-buffer"))
        let order = last(.lastByMeasuredOrder)
        #expect(order.contains("the layout excludes the other order"))
        #expect(order.contains("content is not proven"))
        #expect(order.contains("--tap-buffer"))
    }
}
