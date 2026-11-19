// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RouterCore

struct RoutePlannerTests {
    private let processes = [
        Samples.process(1, "com.google.Chrome"),
        Samples.process(2, "com.google.Chrome.helper.Renderer"),
        Samples.process(3, "com.spotify.client"),
    ]

    private func arguments(
        bundleID: String = "com.google.Chrome",
        device: String = "mixer-uid",
        first: Int = 3
    ) -> RouteArguments {
        RouteArguments(bundleID: bundleID, deviceUID: device, channels: Samples.pair(first))
    }

    @Test func planCoversTheParentAndItsHelpers() throws {
        let plan = try RoutePlanner.plan(arguments(), devices: [Samples.device], processes: processes)
        #expect(plan.device == Samples.device)
        #expect(plan.appBundleID == "com.google.Chrome")
        #expect(plan.processes.map(\.objectID) == [1, 2])
    }

    @Test func aHelperIdSelectsTheWholeApp() throws {
        let plan = try RoutePlanner.plan(
            arguments(bundleID: "com.google.Chrome.helper.Renderer"),
            devices: [Samples.device], processes: processes)
        #expect(plan.appBundleID == "com.google.Chrome")
        #expect(plan.processes.map(\.objectID) == [1, 2])
    }

    @Test func unknownDeviceFails() {
        #expect(throws: RouterError.unknownDevice(uid: "nope")) {
            try RoutePlanner.plan(
                arguments(device: "nope"), devices: [Samples.device], processes: processes)
        }
    }

    @Test func lastChannelFitsAndOneBeyondFails() throws {
        _ = try RoutePlanner.plan(
            arguments(first: 31), devices: [Samples.device], processes: processes)
        #expect(
            throws: RouterError.channelsOutOfRange(
                first: 32, deviceChannels: 32, deviceName: "Mixer")
        ) {
            try RoutePlanner.plan(
                arguments(first: 32), devices: [Samples.device], processes: processes)
        }
    }

    @Test func missingProcessFails() {
        #expect(throws: RouterError.noMatchingProcess(bundleID: "com.apple.Music")) {
            try RoutePlanner.plan(
                arguments(bundleID: "com.apple.Music"),
                devices: [Samples.device], processes: processes)
        }
    }

    @Test func fakesFeedThePlanner() throws {
        let devices = FakeDevices(devices: [Samples.device])
        let list = FakeProcesses(list: processes)
        let plan = try RoutePlanner.plan(
            arguments(), devices: try devices.outputDevices(), processes: try list.processes())
        #expect(plan.processes.count == 2)
    }
}
