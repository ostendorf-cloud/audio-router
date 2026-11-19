// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import RouterCore

struct FakeDevices: AudioDeviceProviding {
    var devices: [OutputDevice]

    func outputDevices() throws -> [OutputDevice] { devices }

    func observeDeviceList(_ handler: @escaping @Sendable () -> Void) throws -> any Cancellable {
        FakeCancellable()
    }
}

struct FakeCancellable: Cancellable {
    func cancel() {}
}

/// A device list that records the order of reads and registrations and can fire its observer.
final class RecordingDevices: AudioDeviceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [OutputDevice]
    private var observer: (@Sendable () -> Void)?
    private var recorded: [String] = []

    init(_ devices: [OutputDevice]) { current = devices }

    var events: [String] { lock.withLock { recorded } }

    func set(_ devices: [OutputDevice]) { lock.withLock { current = devices } }

    func fire() { lock.withLock { observer }?() }

    func outputDevices() throws -> [OutputDevice] {
        lock.withLock {
            recorded.append("list")
            return current
        }
    }

    func observeDeviceList(_ handler: @escaping @Sendable () -> Void) throws -> any Cancellable {
        lock.withLock {
            recorded.append("observe")
            observer = handler
        }
        return FakeCancellable()
    }
}

struct FakeProcesses: ProcessProviding {
    var list: [AudioProcess]

    func processes() throws -> [AudioProcess] { list }
}

struct FakeFailure: Error, Equatable {
    let step: String
}

/// A step that stops until the test lets it go, to line up threads.
final class Gate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

/// A flag one thread sets and another reads.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}

/// Records every call in order, fails the steps named in `failing` and holds the steps named in
/// `gates` until the test releases them.
final class FakeBackend: AudioRoutingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var signal = false
    private let failing: Set<String>
    let gates: [String: Gate]

    init(failing: Set<String> = [], gating: Set<String> = []) {
        self.failing = failing
        self.gates = Dictionary(uniqueKeysWithValues: gating.map { ($0, Gate()) })
    }

    var calls: [String] { lock.withLock { recorded } }

    func setSignal(_ value: Bool) { lock.withLock { signal = value } }

    private func record(_ call: String) throws {
        lock.withLock { recorded.append(call) }
        let step = call.split(separator: " ").first.map(String.init) ?? call
        if let gate = gates[step] {
            gate.entered.signal()
            gate.release.wait()
        }
        if failing.contains(step) {
            throw FakeFailure(step: call)
        }
    }

    func createTap(processes: [ObjectID], name: String) throws -> TapInfo {
        try record("createTap \(processes.map(String.init).joined(separator: ","))")
        return TapInfo(objectID: 10, uid: "tap-uid", channelCount: 2, isInterleaved: true)
    }

    func createAggregate(deviceUID: String, tap: TapInfo) throws -> ObjectID {
        try record("createAggregate \(deviceUID) \(tap.uid)")
        return 20
    }

    func startIO(aggregate: ObjectID, tap: TapInfo, device: OutputDevice, channels: ChannelPair, meter: Bool)
        throws -> IOHandle
    {
        lock.withLock { meterFlag = meter }
        try record("startIO \(aggregate) \(channels.first),\(channels.second)")
        return IOHandle(rawValue: 30)
    }

    /// The value of the `meter` argument of the last `startIO`.
    var meterRequested: Bool { lock.withLock { meterFlag } }
    private var meterFlag = false
    private var readings: [MeterReading] = []

    /// Readings `readMeter` hands out in order, then nil.
    func queue(_ reading: MeterReading) { lock.withLock { readings.append(reading) } }

    static let info = RouteInfo(
        tap: StreamFormatInfo(sampleRate: 48000, channels: 2, interleaved: true),
        inputBuffers: [32, 2], tapBuffers: 1..<2, outputBuffers: [32],
        inputStreams: [], outputStreams: [], aggregateSampleRate: 48000, deviceSampleRate: 44100)

    func routeInfo(handle: IOHandle) -> RouteInfo? { FakeBackend.info }

    func readMeter(handle: IOHandle) -> MeterReading? {
        lock.withLock { readings.isEmpty ? nil : readings.removeFirst() }
    }

    func signalSeen(handle: IOHandle) -> Bool { lock.withLock { signal } }

    func stopIO(aggregate: ObjectID, handle: IOHandle) throws {
        try record("stopIO \(aggregate) \(handle.rawValue)")
    }

    func destroyAggregate(_ aggregate: ObjectID) throws {
        try record("destroyAggregate \(aggregate)")
    }

    func destroyTap(_ tap: ObjectID) throws {
        try record("destroyTap \(tap)")
    }
}

enum Samples {
    static let device = OutputDevice(objectID: 5, uid: "mixer-uid", name: "Mixer", channelCount: 32)

    static func pair(_ first: Int) -> ChannelPair {
        // Test values are always valid, a bad one fails the test run loudly.
        do { return try ChannelPair(first: first) } catch { fatalError("bad test channel \(first)") }
    }

    static func process(_ id: ObjectID, _ bundleID: String, pid: Int32 = 100, playing: Bool = true)
        -> AudioProcess
    {
        AudioProcess(
            objectID: id, pid: pid + Int32(id), bundleID: bundleID, isRunningOutput: playing)
    }
}
