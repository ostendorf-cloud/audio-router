// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore
import Testing

@testable import AudioRouterAppCore

@MainActor private func makeTracker(_ source: MeterSource, _ clock: FakeMeterClock) -> (MeterMenuTracker, MeterPoller) {
    let poller = MeterPoller(
        read: { source.read() }, interval: 0.1, clock: clock, offMain: { $0() },
        mainHop: { work in MainActor.assumeIsolated { work() } })
    return (MeterMenuTracker(poller: poller), poller)
}

private let ours = ["Routing", "Settings\u{2026}", MeterMenuTracker.quitTitle]
private let other = ["Cut", "Copy", "Paste"]

@MainActor @Suite struct MeterMenuTrackerTests {
    @Test func beginningToTrackStartsPollingAndEndingStopsIt() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let (tracker, poller) = makeTracker(source, clock)
        #expect(!poller.isPolling)
        tracker.menuDidBeginTracking()
        #expect(poller.isPolling)
        clock.fire()
        #expect(source.reads == 1)
        tracker.menuDidEndTracking()
        #expect(!poller.isPolling)
        clock.fire()
        #expect(source.reads == 1)
    }

    @Test func aBeginTwiceAndOneEndLeavesTheMenuClosed() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let (tracker, poller) = makeTracker(source, clock)
        tracker.menuDidBeginTracking()
        tracker.menuDidBeginTracking()
        tracker.menuDidEndTracking()
        #expect(!poller.isPolling)
        #expect(clock.activeTimers == 0)
    }

    @Test func aMenuOfOursStartsPollingAndAnotherMenuDoesNot() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let (tracker, poller) = makeTracker(source, clock)
        tracker.menuDidBeginTracking(itemTitles: other)
        #expect(!poller.isPolling)
        tracker.menuDidBeginTracking(itemTitles: ours)
        #expect(poller.isPolling)
        tracker.menuDidEndTracking(itemTitles: other)
        #expect(poller.isPolling)
        tracker.menuDidEndTracking(itemTitles: ours)
        #expect(!poller.isPolling)
    }

    @Test func theMenuAndTheWindowAreIndependentClients() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let (tracker, poller) = makeTracker(source, clock)
        poller.start(.settings)
        tracker.menuDidBeginTracking()
        tracker.menuDidEndTracking()
        #expect(poller.isPolling)
        poller.stop(.settings)
        #expect(!poller.isPolling)
    }

    @Test func theWindowCanCloseAndOpenAgain() {
        let source = MeterSource()
        let clock = FakeMeterClock()
        let (_, poller) = makeTracker(source, clock)
        poller.start(.settings)
        poller.stop(.settings)
        #expect(!poller.isPolling)
        poller.start(.settings)
        clock.fire()
        #expect(poller.isPolling)
        #expect(source.reads == 1)
    }

    @Test func onlyTheMenuWithTheQuitItemIsOurs() {
        #expect(MeterMenuTracker.ownsMenu(itemTitles: ours))
        #expect(!MeterMenuTracker.ownsMenu(itemTitles: other))
        #expect(!MeterMenuTracker.ownsMenu(itemTitles: []))
    }
}
