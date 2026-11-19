// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

private let plan = RoutePlan(
    device: Samples.device,
    channels: Samples.pair(3),
    appBundleID: "com.spotify.client",
    processes: [Samples.process(1, "com.spotify.client")]
)

/// Records the order of exit, write and park calls.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var all: [String] { lock.withLock { recorded } }

    func add(_ call: String) { lock.withLock { recorded.append(call) } }
}

struct FinisherTests {
    private func make(_ backend: FakeBackend, _ calls: Calls) -> (Finisher, RouteSession) {
        let session = RouteSession(backend: backend, plan: plan)
        let finisher = Finisher(
            session: session,
            exit: { calls.add("exit \($0)") },
            write: { calls.add("write \($0.trimmingCharacters(in: .newlines))") },
            park: { calls.add("park") }
        )
        return (finisher, session)
    }

    @Test func tearsDownBeforeItWritesAndExits() throws {
        let backend = FakeBackend()
        let calls = Calls()
        let (finisher, session) = make(backend, calls)
        try session.start()
        finisher.finish(code: 0, message: "stopped")
        #expect(backend.calls.suffix(3) == ["stopIO 20 30", "destroyAggregate 20", "destroyTap 10"])
        #expect(calls.all == ["write stopped", "exit 0"])
    }

    @Test func passesTheCodeThroughAndWorksWithoutMessage() throws {
        let calls = Calls()
        let (finisher, session) = make(FakeBackend(), calls)
        try session.start()
        finisher.finish(code: 7, message: nil)
        #expect(calls.all == ["exit 7"])
    }

    @Test func aFailedTeardownReportsLeftoversAndExitsWithOne() throws {
        let calls = Calls()
        let (finisher, session) = make(FakeBackend(failing: ["destroyTap"]), calls)
        try session.start()
        finisher.finish(code: 0, message: "stopped")
        #expect(calls.all.count == 3)
        #expect(calls.all[0] == "write stopped")
        #expect(calls.all[1].hasPrefix("write teardown: destroy tap"))
        #expect(calls.all[2] == "exit 1")
    }

    @Test func aSecondCallParksAndDoesNotExitOrTearDownAgain() throws {
        let backend = FakeBackend()
        let calls = Calls()
        let (finisher, session) = make(backend, calls)
        try session.start()
        finisher.finish(code: 0, message: "stopped")
        let teardownCalls = backend.calls.count
        finisher.finish(code: 1, message: "error: again")
        #expect(calls.all == ["write stopped", "exit 0", "park"])
        #expect(backend.calls.count == teardownCalls)
    }

    @Test func aStopThatWonAgainstAFailedStartStillReportsTheErrorAndExitsNonZero() {
        let calls = Calls()
        let (finisher, session) = make(FakeBackend(failing: ["createAggregate"]), calls)
        var failure = ""
        do {
            try session.start()
        } catch {
            failure = "error: \(error)"
        }
        #expect(!failure.isEmpty)
        finisher.finish(code: 0, message: "stopped")  // the signal handler got there first
        #expect(calls.all == ["write stopped", "write \(failure)", "exit 1"])
    }

    @Test func theStartErrorIsNotPrintedTwiceWhenTheStartPathFinishes() {
        let calls = Calls()
        let (finisher, session) = make(FakeBackend(failing: ["createAggregate"]), calls)
        var failure = ""
        do {
            try session.start()
        } catch {
            failure = "error: \(error)"
        }
        finisher.finish(code: 1, message: failure)
        #expect(calls.all == ["write \(failure)", "exit 1"])
    }

    @Test func aFailedStartWithLeftoversReportsThemInTheError() {
        let calls = Calls()
        let (finisher, session) = make(FakeBackend(failing: ["createAggregate", "destroyTap"]), calls)
        _ = try? session.start()
        finisher.finish(code: 0, message: "stopped")
        #expect(calls.all.count == 3)
        #expect(calls.all[1].hasPrefix("write error: Teardown finished with errors"))
        #expect(calls.all[2] == "exit 1")
    }

    @Test func aFinishWithoutAStartedRouteStillExits() {
        let calls = Calls()
        let (finisher, _) = make(FakeBackend(), calls)
        finisher.finish(code: 1, message: "error: boom")
        #expect(calls.all == ["write error: boom", "exit 1"])
    }
}

struct DeviceWatchTests {
    @Test func registersTheObserverThenChecksOnce() throws {
        let devices = RecordingDevices([Samples.device])
        let gone = Flag()
        _ = try DeviceWatch.start(devices: devices, uid: "mixer-uid") { gone.set() }
        #expect(devices.events == ["observe", "list"])
        #expect(!gone.isSet)
    }

    @Test func aDeviceLostBeforeTheObserverExistedIsNoticed() throws {
        let devices = RecordingDevices([])
        let gone = Flag()
        _ = try DeviceWatch.start(devices: devices, uid: "mixer-uid") { gone.set() }
        #expect(gone.isSet)
    }

    @Test func aLaterRemovalIsNoticedByTheObserver() throws {
        let devices = RecordingDevices([Samples.device])
        let gone = Flag()
        _ = try DeviceWatch.start(devices: devices, uid: "mixer-uid") { gone.set() }
        devices.fire()
        #expect(!gone.isSet)
        devices.set([])
        devices.fire()
        #expect(gone.isSet)
    }

    @Test func anotherDeviceDoesNotCount() {
        let other = OutputDevice(objectID: 9, uid: "other", name: "Other", channelCount: 2)
        #expect(!DeviceWatch.isPresent(uid: "mixer-uid", devices: RecordingDevices([other])))
        #expect(DeviceWatch.isPresent(uid: "other", devices: RecordingDevices([other])))
    }
}

struct DiagnosticsTests {
    @Test func writesTheTextToTheDescriptor() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        Diagnostics.write("hello\n", to: fds[1])
        close(fds[1])
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(fds[0], &buffer, buffer.count)
        close(fds[0])
        #expect(String(decoding: buffer.prefix(count), as: UTF8.self) == "hello\n")
    }

    @Test func aBrokenDescriptorIsIgnored() {
        Diagnostics.write("lost\n", to: -1)  // EBADF, must neither crash nor loop
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        close(fds[0])
        signal(SIGPIPE, SIG_IGN)
        Diagnostics.write("lost\n", to: fds[1])  // EPIPE
        close(fds[1])
    }

    @Test func aLongTextIsWrittenInFull() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let text = String(repeating: "x", count: 40_000)
        let readEnd = fds[0]
        let reader = Thread {
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                if count <= 0 { break }
                total += count
            }
            close(readEnd)
            received.set(total)
        }
        reader.start()
        Diagnostics.write(text, to: fds[1])
        close(fds[1])
        while !received.isDone { Thread.sleep(forTimeInterval: 0.01) }
        #expect(received.value == 40_000)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var done = false

    var value: Int { lock.withLock { total } }
    var isDone: Bool { lock.withLock { done } }

    func set(_ count: Int) {
        lock.withLock {
            total = count
            done = true
        }
    }
}

private let received = Counter()

struct ProcessFilterTests {
    private let processes = [
        Samples.process(1, "com.spotify.client", pid: 10),
        Samples.process(2, ProcessFilter.ownBundleID, pid: 20),
        Samples.process(3, "com.other", pid: 30),
    ]

    @Test func dropsTheOwnBundleId() {
        let rest = ProcessFilter.withoutSelf(processes, bundleID: ProcessFilter.ownBundleID, pid: 9999)
        #expect(rest.map(\.objectID) == [1, 3])
    }

    @Test func dropsTheOwnPidEvenWithAnotherBundleId() {
        let rest = ProcessFilter.withoutSelf(processes, bundleID: "none", pid: 33)  // object 3 has pid 33
        #expect(rest.map(\.objectID) == [1, 2])
    }

    @Test func theOwnBundleIdMatchesTheInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/audio-router-proto/Info.plist")
        let data = try Data(contentsOf: plist)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let identifier = (object as? [String: Any])?["CFBundleIdentifier"] as? String
        #expect(identifier == ProcessFilter.ownBundleID)
    }
}

struct MeterFormattingTests {
    private let reading = MeterReading(
        input: LevelReading(peak: 0.5, rms: 0.25, samples: 96000),
        output: LevelReading(peak: 0, rms: 0, samples: 96000),
        frames: 48000
    )

    @Test func meterLineShowsPeakAndRmsOfTapAndOutput() {
        #expect(
            Formatting.meter(reading)
                == "meter: tap peak -6.0 dBFS rms -12.0 dBFS | out peak -inf dBFS rms -inf dBFS | 48000 frames")
    }

    @Test func routeInfoNamesLayoutTapBufferAndRates() {
        let info = RouteInfo(
            tap: StreamFormatInfo(sampleRate: 48000, channels: 2, interleaved: true),
            inputBuffers: [32, 2], tapBuffers: 1..<2, outputBuffers: [32],
            inputStreams: [
                StreamFormatInfo(sampleRate: 48000, channels: 32, interleaved: true),
                StreamFormatInfo(sampleRate: 48000, channels: 2, interleaved: true),
            ],
            outputStreams: [StreamFormatInfo(sampleRate: 48000, channels: 32, interleaved: false)],
            aggregateSampleRate: 48000, deviceSampleRate: 44100.5)
        #expect(
            Formatting.routeInfo(info) == [
                "tap format: 48000 Hz, 2 channels, interleaved",
                "aggregate input buffers: [32, 2], tap in buffer 1",
                "aggregate input streams: 48000 Hz, 32 channels, interleaved; 48000 Hz, 2 channels, interleaved",
                "aggregate output buffers: [32]",
                "aggregate output streams: 48000 Hz, 32 channels, not interleaved",
                "sample rate: tap 48000 Hz, aggregate 48000 Hz, device 44100.5 Hz",
            ])
    }

    @Test func aNonInterleavedTapSaysWhichBuffers() {
        let info = RouteInfo(
            tap: StreamFormatInfo(sampleRate: 0, channels: 2, interleaved: false),
            inputBuffers: [32, 1, 1], tapBuffers: 1..<3, outputBuffers: [32],
            inputStreams: [], outputStreams: [], aggregateSampleRate: nil, deviceSampleRate: nil)
        let lines = Formatting.routeInfo(info)
        #expect(lines[0] == "tap format: unknown, 2 channels, not interleaved")
        #expect(lines[1] == "aggregate input buffers: [32, 1, 1], tap in buffers 1 to 2")
        #expect(lines[5] == "sample rate: tap unknown, aggregate unknown, device unknown")
    }
}

struct MeterSessionTests {
    private let reading = MeterReading(
        input: LevelReading(peak: 1, rms: 0.5, samples: 4),
        output: LevelReading(peak: 1, rms: 0.5, samples: 4),
        frames: 2
    )

    @Test func routeMeterParsesAndIsOffByDefault() throws {
        let base = ["route", "--bundle-id", "a", "--device", "b", "--channels", "3,4"]
        guard case .route(let off) = try ArgumentParser.parse(base),
            case .route(let on) = try ArgumentParser.parse(base + ["--meter"]),
            case .route(let first) = try ArgumentParser.parse(["route", "--meter"] + base.dropFirst())
        else {
            Issue.record("route did not parse")
            return
        }
        #expect(!off.meter)
        #expect(on.meter)
        #expect(first.meter)
        #expect(throws: RouterError.self) { try ArgumentParser.parse(base + ["--meter", "--meter"]) }
    }

    @Test func sessionPassesTheMeterFlagAndHandsOutReadings() throws {
        let backend = FakeBackend()
        backend.queue(reading)
        let session = RouteSession(backend: backend, plan: plan, meter: true)
        #expect(session.meterReading() == nil, "not started")
        try session.start()
        #expect(backend.meterRequested)
        #expect(session.meterReading() == reading)
        #expect(session.meterReading() == nil, "nothing queued")
        #expect(session.routeInfo() == FakeBackend.info)
        session.stop()
        backend.queue(reading)
        #expect(session.meterReading() == nil, "stopped")
        #expect(session.routeInfo() == nil, "stopped")
    }

    @Test func withoutTheFlagNothingIsRead() throws {
        let backend = FakeBackend()
        backend.queue(reading)
        let session = RouteSession(backend: backend, plan: plan)
        try session.start()
        #expect(!backend.meterRequested)
        #expect(session.meterReading() == nil)
    }
}
