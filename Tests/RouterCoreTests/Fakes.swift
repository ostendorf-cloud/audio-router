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

struct FakeProcesses: ProcessProviding {
    var list: [AudioProcess]

    func processes() throws -> [AudioProcess] { list }
}

struct FakeFailure: Error, Equatable {
    let step: String
}

/// Records every call in order and fails the steps named in `failing`.
final class FakeBackend: AudioRoutingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let failing: Set<String>

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    var calls: [String] { lock.withLock { recorded } }

    private func record(_ call: String) throws {
        lock.withLock { recorded.append(call) }
        if failing.contains(call.split(separator: " ").first.map(String.init) ?? call) {
            throw FakeFailure(step: call)
        }
    }

    func createTap(processes: [ObjectID], name: String) throws -> TapInfo {
        try record("createTap \(processes.map(String.init).joined(separator: ","))")
        return TapInfo(objectID: 10, uid: "tap-uid")
    }

    func createAggregate(deviceUID: String, tap: TapInfo) throws -> ObjectID {
        try record("createAggregate \(deviceUID) \(tap.uid)")
        return 20
    }

    func startIO(aggregate: ObjectID, channels: ChannelPair) throws -> IOHandle {
        try record("startIO \(aggregate) \(channels.first),\(channels.second)")
        return IOHandle(rawValue: 30)
    }

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

    static func process(_ id: ObjectID, _ bundleID: String, pid: Int32 = 100, playing: Bool = true)
        -> AudioProcess
    {
        AudioProcess(
            objectID: id, pid: pid + Int32(id), bundleID: bundleID, isRunningOutput: playing)
    }
}
