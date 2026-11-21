// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation
import RouterCore

/// Output device state and raw change signals from Core Audio. Not exercised by unit tests because
/// it needs devices. The owner checks it on a real Mac, see AGENTS.md.
public struct CoreAudioDeviceMonitor: DeviceMonitoring {
    public init() {}

    public func snapshot() throws -> [DeviceInfo] {
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            CoreAudioProperty.system, kAudioHardwarePropertyDevices, initial: 0)
        let defaultID: AudioObjectID = try CoreAudioProperty.value(
            CoreAudioProperty.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        return ids.compactMap { id in
            guard
                let channels = try? CoreAudioProperty.channelsPerBuffer(id, scope: kAudioObjectPropertyScopeOutput),
                channels.reduce(0, +) > 0,
                let uid = try? CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            let name = (try? CoreAudioProperty.string(id, kAudioObjectPropertyName)) ?? uid
            let alive: UInt32 =
                (try? CoreAudioProperty.value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0
            return DeviceInfo(
                uid: uid, name: name, outputChannelsPerStream: channels,
                nominalSampleRate: CoreAudioProperty.nominalSampleRate(id) ?? 0,
                isAlive: alive != 0, isDefaultOutput: id == defaultID)
        }
    }

    public func observe(_ handler: @escaping @Sendable (DeviceSignal) -> Void) throws -> any Cancellable {
        let listeners = DeviceListeners(handler: handler)
        try listeners.install()
        return listeners
    }
}

/// Registers blocks on the system object (device list, default output) and on each device (nominal
/// sample rate, alive). Device blocks follow the list: a new device gets blocks, a gone one loses
/// them. Cancel removes every block it added, each with the queue and block it was added with.
private final class DeviceListeners: Cancellable, @unchecked Sendable {
    private struct Registration {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    private let handler: @Sendable (DeviceSignal) -> Void
    private let queue = DispatchQueue(label: "audio-router.device-monitor")
    private let lock = NSLock()
    private var cancelled = false
    private var system: [Registration] = []
    private var perDevice: [AudioObjectID: [Registration]] = [:]

    init(handler: @escaping @Sendable (DeviceSignal) -> Void) {
        self.handler = handler
    }

    func install() throws {
        do {
            try lock.withLock {
                try add(CoreAudioProperty.system, kAudioHardwarePropertyDevices, signal: nil, to: &system)
                try add(
                    CoreAudioProperty.system, kAudioHardwarePropertyDefaultOutputDevice, signal: .defaultOutput,
                    to: &system)
                try syncDevices()
            }
        } catch {
            cancel()
            throw error
        }
    }

    func cancel() {
        let all: [Registration] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            let all = system + perDevice.values.flatMap { $0 }
            system = []
            perDevice = [:]
            return all
        }
        for registration in all { remove(registration) }
    }

    /// Adds a block for `selector`. A nil `signal` is the device list: it re-syncs the device blocks
    /// first and then reports `.deviceList`. Needs the lock held by the caller.
    private func add(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, signal: DeviceSignal?,
        to registrations: inout [Registration]
    ) throws {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if let signal {
                self.deliver(signal)
            } else {
                self.lock.withLock { try? self.syncDevices() }
                self.deliver(.deviceList)
            }
        }
        var address = CoreAudioProperty.address(selector)
        try CoreAudioProperty.check(
            AudioObjectAddPropertyListenerBlock(object, &address, queue, block),
            "add listener \(fourCC(Int32(bitPattern: selector)))")
        registrations.append(Registration(object: object, selector: selector, block: block))
    }

    private func deliver(_ signal: DeviceSignal) {
        guard !lock.withLock({ cancelled }) else { return }
        handler(signal)
    }

    /// Needs the lock held by the caller.
    private func syncDevices() throws {
        guard !cancelled else { return }
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            CoreAudioProperty.system, kAudioHardwarePropertyDevices, initial: 0)
        for gone in perDevice.keys where !ids.contains(gone) {
            for registration in perDevice.removeValue(forKey: gone) ?? [] { remove(registration) }
        }
        for id in ids where perDevice[id] == nil {
            var registrations: [Registration] = []
            do {
                try add(id, kAudioDevicePropertyNominalSampleRate, signal: .sampleRate, to: &registrations)
                try add(id, kAudioDevicePropertyDeviceIsAlive, signal: .alive, to: &registrations)
            } catch {
                // A device that vanished while the list was read has no properties to listen to.
                for registration in registrations { remove(registration) }
                continue
            }
            perDevice[id] = registrations
        }
    }

    private func remove(_ registration: Registration) {
        var address = CoreAudioProperty.address(registration.selector)
        AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
    }
}
