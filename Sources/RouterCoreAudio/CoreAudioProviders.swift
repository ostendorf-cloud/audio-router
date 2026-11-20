// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation
import RouterCore

/// Output devices from Core Audio.
public struct CoreAudioDeviceProvider: AudioDeviceProviding {
    public init() {}

    public func outputDevices() throws -> [OutputDevice] {
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            CoreAudioProperty.system, kAudioHardwarePropertyDevices, initial: 0)
        return ids.compactMap { id in
            guard
                let channels = try? CoreAudioProperty.channelsPerBuffer(
                    id, scope: kAudioObjectPropertyScopeOutput),
                channels.reduce(0, +) > 0,
                let uid = try? CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            let name = (try? CoreAudioProperty.string(id, kAudioObjectPropertyName)) ?? uid
            return OutputDevice(
                objectID: id, uid: uid, name: name, channelCount: channels.reduce(0, +))
        }
    }

    public func observeDeviceList(_ handler: @escaping @Sendable () -> Void) throws
        -> any Cancellable
    {
        let queue = DispatchQueue(label: "audio-router.device-list")
        let listener = DeviceListListener(queue: queue, handler: handler)
        try listener.install()
        return listener
    }
}

/// Registers a block on the system object's device list and removes the same block on cancel.
private final class DeviceListListener: Cancellable, @unchecked Sendable {
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var installed = false

    init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.block = { _, _ in handler() }
    }

    func install() throws {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        try CoreAudioProperty.check(
            AudioObjectAddPropertyListenerBlock(
                CoreAudioProperty.system, &address, queue, block),
            "add device list listener"
        )
        lock.withLock { installed = true }
    }

    func cancel() {
        let wasInstalled = lock.withLock {
            defer { installed = false }
            return installed
        }
        guard wasInstalled else { return }
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(CoreAudioProperty.system, &address, queue, block)
    }
}

/// Audio client processes from Core Audio. Needs no permission.
public struct CoreAudioProcessProvider: ProcessProviding {
    public init() {}

    public func processes() throws -> [AudioProcess] {
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            CoreAudioProperty.system, kAudioHardwarePropertyProcessObjectList, initial: 0)
        return ids.compactMap { id in
            guard
                let pid: Int32 = try? CoreAudioProperty.value(
                    id, kAudioProcessPropertyPID, initial: 0)
            else { return nil }
            let bundleID = (try? CoreAudioProperty.string(id, kAudioProcessPropertyBundleID)) ?? ""
            let running: UInt32 =
                (try? CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput, initial: 0))
                ?? 0
            return AudioProcess(
                objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }
}
