// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RouterCore

struct ArgumentParserTests {
    @Test func parsesSimpleCommands() throws {
        #expect(try ArgumentParser.parse(["devices"]) == .devices)
        #expect(try ArgumentParser.parse(["apps"]) == .apps)
        #expect(try ArgumentParser.parse(["--help"]) == .help)
    }

    @Test func parsesRouteInAnyOptionOrder() throws {
        let expected = Command.route(
            RouteArguments(bundleID: "com.spotify.client", deviceUID: "dev", channels: ChannelPair(first: 3))
        )
        let a = try ArgumentParser.parse([
            "route", "--bundle-id", "com.spotify.client", "--device", "dev", "--channels", "3,4",
        ])
        let b = try ArgumentParser.parse([
            "route", "--channels", "3,4", "--device", "dev", "--bundle-id", "com.spotify.client",
        ])
        #expect(a == expected)
        #expect(b == expected)
    }

    @Test(arguments: [
        [],
        ["unknown"],
        ["devices", "extra"],
        ["route"],
        ["route", "--bundle-id", "a", "--device", "b"],
        ["route", "--bundle-id", "a", "--device", "b", "--channels"],
        ["route", "--bundle-id", "a", "--device", "b", "--channels", "3,4", "--channels", "5,6"],
        ["route", "--bundle-id", "a", "--device", "b", "--channels", "3,4", "--verbose", "x"],
        ["route", "--bundle-id", "", "--device", "b", "--channels", "3,4"],
    ])
    func rejectsBadArguments(arguments: [String]) {
        #expect(throws: RouterError.self) { try ArgumentParser.parse(arguments) }
    }

    @Test func acceptsAdjacentChannels() throws {
        #expect(try ArgumentParser.parseChannels("1,2") == ChannelPair(first: 1))
        #expect(try ArgumentParser.parseChannels("31,32") == ChannelPair(first: 31))
    }

    @Test(arguments: ["", "3", "3,", ",4", "3,5", "4,3", "0,1", "-1,0", "a,b", "3,4,5", "3.0,4"])
    func rejectsBadChannels(text: String) {
        #expect(throws: RouterError.self) { try ArgumentParser.parseChannels(text) }
    }
}
