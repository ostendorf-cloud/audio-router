// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

private func proc(_ id: ObjectID, _ bundle: String) -> AudioProcess {
    AudioProcess(objectID: id, pid: Int32(id) + 1000, bundleID: bundle, isRunningOutput: true)
}

private let player = proc(1, "com.example.Player")
private let playerHelper = proc(2, "com.example.Player.helper.Renderer")
private let other = proc(3, "com.example.Other")

private func start(_ list: FakeProcessList) throws -> (EventLog, any Cancellable) {
    let log = EventLog()
    let monitor = ProcessMonitor(processes: list, observer: list)
    let handle = try monitor.start { log.append($0) }
    log.held = handle
    return (log, handle)
}

@Suite("Process monitor")
struct ProcessesMonitoringTests {
    @Test func appStartAfterWatching() throws {
        let list = FakeProcessList([])
        let (log, _) = try start(list)
        #expect(log.events.isEmpty)
        list.change(to: [player])
        #expect(log.events == [.appStarted(AppGroup(bundleID: "com.example.Player", processes: [player]))])
    }

    @Test func runningAppsArriveAsStartedOnStart() throws {
        let list = FakeProcessList([other, player, playerHelper])
        let (log, _) = try start(list)
        #expect(
            log.events == [
                .appStarted(AppGroup(bundleID: "com.example.Other", processes: [other])),
                .appStarted(AppGroup(bundleID: "com.example.Player", processes: [player, playerHelper])),
            ])
    }

    @Test func helperStartIsNotAnAppStart() throws {
        let list = FakeProcessList([player])
        let (log, _) = try start(list)
        log.clear()
        list.change(to: [player, playerHelper])
        #expect(log.events == [.helperStarted(bundleID: "com.example.Player", process: playerHelper)])
    }

    @Test func helperStopKeepsTheApp() throws {
        let list = FakeProcessList([player, playerHelper])
        let (log, _) = try start(list)
        log.clear()
        list.change(to: [player])
        #expect(log.events == [.helperStopped(bundleID: "com.example.Player", process: playerHelper)])
    }

    @Test func appQuitWhenTheLastProcessIsGone() throws {
        let list = FakeProcessList([player, playerHelper, other])
        let (log, _) = try start(list)
        log.clear()
        list.change(to: [other])
        #expect(log.events == [.appQuit(bundleID: "com.example.Player")])
    }

    @Test func helperOutlivingItsParentStaysGroupedUnderTheParent() throws {
        let list = FakeProcessList([playerHelper])
        let (log, _) = try start(list)
        #expect(
            log.events == [.appStarted(AppGroup(bundleID: "com.example.Player", processes: [playerHelper]))])
    }

    @Test func unchangedListEmitsNothing() throws {
        let list = FakeProcessList([player])
        let (log, _) = try start(list)
        log.clear()
        list.fire()
        #expect(log.events.isEmpty)
    }

    @Test func processWithoutBundleIDIsIgnored() throws {
        let list = FakeProcessList([])
        let (log, _) = try start(list)
        list.change(to: [proc(9, "")])
        #expect(log.events.isEmpty)
    }

    @Test func failedReadKeepsTheLastSnapshot() throws {
        let list = FakeProcessList([player])
        let (log, _) = try start(list)
        log.clear()
        list.setFailing(true)
        list.fire()
        #expect(log.events.isEmpty)
        list.setFailing(false)
        list.fire()
        #expect(log.events.isEmpty)
    }

    @Test func cancelRemovesTheListenerAndStopsEvents() throws {
        let list = FakeProcessList([])
        let (log, handle) = try start(list)
        #expect(list.listenerInstalled)
        handle.cancel()
        #expect(!list.listenerInstalled)
        #expect(list.removals == 1)
        list.change(to: [player])
        #expect(log.events.isEmpty)
        handle.cancel()
        #expect(list.removals == 1)
    }

    @Test func cancelInsideTheHandlerStopsTheRest() throws {
        let list = FakeProcessList([])
        let log = EventLog()
        let box = HandleBox()
        let monitor = ProcessMonitor(processes: list, observer: list)
        box.handle = try monitor.start { event in
            log.append(event)
            box.handle?.cancel()
        }
        list.change(to: [player, other])
        #expect(log.events.count == 1)
        #expect(list.removals == 1)
    }

    @Test func droppingTheHandleWithoutCancelRemovesTheListener() throws {
        let list = FakeProcessList([])
        let log = EventLog()
        var handle: (any Cancellable)? = try ProcessMonitor(processes: list, observer: list)
            .start { log.append($0) }
        #expect(list.listenerInstalled)
        #expect(handle != nil)
        handle = nil
        #expect(!list.listenerInstalled)
        #expect(list.removals == 1)
        list.change(to: [player])
        #expect(log.events.isEmpty)
    }

    @Test func failedFirstReadThrowsAndLeavesNoListener() {
        let list = FakeProcessList([player])
        list.setFailing(true)
        let monitor = ProcessMonitor(processes: list, observer: list)
        #expect(throws: ProcessMonitorError.self) {
            _ = try monitor.start { _ in }
        }
        #expect(!list.listenerInstalled)
        #expect(list.removals == 1)
    }

    @Test func ownProcessIsDropped() throws {
        let mine = AudioProcess(objectID: 7, pid: 4242, bundleID: "com.example.Mine", isRunningOutput: true)
        let list = FakeProcessList([mine])
        let log = EventLog()
        let monitor = ProcessMonitor(
            processes: list, observer: list, ownPID: 4242, ownBundleID: "com.example.Mine")
        log.held = try monitor.start { log.append($0) }
        #expect(log.events.isEmpty)
        // Same bundle id, other pid: dropped by the id as well.
        list.change(to: [mine, proc(8, "com.example.Mine"), player])
        #expect(log.events == [.appStarted(AppGroup(bundleID: "com.example.Player", processes: [player]))])
    }

    @Test func replacedMainProcessShowsAsHelperStopAndStart() throws {
        let list = FakeProcessList([player, playerHelper])
        let (log, _) = try start(list)
        log.clear()
        let replacement = proc(10, "com.example.Player")
        list.change(to: [replacement, playerHelper])
        #expect(
            log.events == [
                .helperStopped(bundleID: "com.example.Player", process: player),
                .helperStarted(bundleID: "com.example.Player", process: replacement),
            ])
    }

    @Test func regroupingShowsQuitOfThePseudoAppThenStartOfTheParent() throws {
        let extra = proc(4, "com.example.Player.Extra")
        let list = FakeProcessList([extra])
        let (log, _) = try start(list)
        #expect(
            log.events == [.appStarted(AppGroup(bundleID: "com.example.Player.Extra", processes: [extra]))])
        log.clear()
        list.change(to: [player, extra])
        #expect(
            log.events == [
                .appQuit(bundleID: "com.example.Player.Extra"),
                .appStarted(AppGroup(bundleID: "com.example.Player", processes: [player, extra])),
            ])
    }

    @Test func fakeMonitorEmitsScriptedEvents() throws {
        let fake = FakeProcessMonitor()
        let log = EventLog()
        let group = AppGroup(bundleID: "com.example.Player", processes: [player])
        let handle = try fake.start { log.append($0) }
        fake.emit(
            .appStarted(group),
            .helperStarted(bundleID: "com.example.Player", process: playerHelper),
            .appQuit(bundleID: "com.example.Player"))
        #expect(log.events.count == 3)
        #expect(log.events.last == .appQuit(bundleID: "com.example.Player"))
        handle.cancel()
        fake.emit(.appQuit(bundleID: "com.example.Other"))
        #expect(log.events.count == 3)
        #expect(fake.cancels == 1)
    }
}

private final class HandleBox: @unchecked Sendable {
    var handle: (any Cancellable)?
}
