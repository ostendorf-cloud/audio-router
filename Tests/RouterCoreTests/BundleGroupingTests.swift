// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RouterCore

struct BundleGroupingTests {
    @Test func helpersGroupUnderThePresentParent() {
        let processes = [
            Samples.process(1, "com.google.Chrome"),
            Samples.process(2, "com.google.Chrome.helper"),
            Samples.process(3, "com.google.Chrome.helper.Renderer"),
            Samples.process(4, "com.spotify.client"),
        ]
        let groups = BundleGrouping.groups(processes)
        #expect(groups.map(\.bundleID) == ["com.google.Chrome", "com.spotify.client"])
        #expect(groups[0].processes.map(\.objectID) == [1, 2, 3])
        #expect(groups[1].processes.map(\.objectID) == [4])
    }

    @Test func helperGroupsUnderTheParentIdWhenTheParentPlaysNothing() {
        let processes = [
            Samples.process(1, "com.tinyspeck.slackmacgap.helper"),
            Samples.process(2, "com.tinyspeck.slackmacgap.helper.Renderer"),
        ]
        let groups = BundleGrouping.groups(processes)
        #expect(groups.map(\.bundleID) == ["com.tinyspeck.slackmacgap"])
        #expect(groups[0].processes.count == 2)
    }

    @Test func similarPrefixIsNotAParent() {
        let all: Set<String> = ["com.example.app", "com.example.application"]
        #expect(BundleGrouping.parentID(of: "com.example.application", among: all) == "com.example.application")
    }

    @Test func shortestPrefixWins() {
        let all: Set<String> = ["a.b", "a.b.c", "a.b.c.d"]
        #expect(BundleGrouping.parentID(of: "a.b.c.d", among: all) == "a.b")
    }

    @Test func processesWithoutBundleIDAreLeftOut() {
        let groups = BundleGrouping.groups([Samples.process(1, ""), Samples.process(2, "x.y")])
        #expect(groups.map(\.bundleID) == ["x.y"])
    }

    @Test func outputIsSorted() {
        let groups = BundleGrouping.groups([
            Samples.process(2, "b.app"), Samples.process(1, "a.app"),
        ])
        #expect(groups.map(\.bundleID) == ["a.app", "b.app"])
    }
}
