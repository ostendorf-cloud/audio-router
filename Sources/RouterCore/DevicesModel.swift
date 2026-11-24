// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One output device as the engine and the UI see it. Input devices are not modelled.
public struct DeviceInfo: Equatable, Sendable {
    public let uid: String
    public let name: String
    /// Output channels of each buffer of the stream configuration, in buffer order. A buffer holds
    /// one interleaved stream, or one channel of a non interleaved stream.
    public let outputChannelsPerStream: [Int]
    /// Nominal sample rate in Hz, nil when Core Audio did not answer. `DeviceModel` keeps the last
    /// known rate over a failed read, so an unknown rate is never reported as a change.
    public let nominalSampleRate: Double?
    /// `kAudioDevicePropertyDeviceIsAlive`.
    public let isAlive: Bool
    /// True for the device that is the system default output.
    public let isDefaultOutput: Bool
    /// False when the alive flag could not be read. `DeviceModel` then keeps the last known flag,
    /// so a failed read is never reported as a dead device. Every device the model holds has it true.
    public let isAliveKnown: Bool

    public init(
        uid: String, name: String, outputChannelsPerStream: [Int], nominalSampleRate: Double?, isAlive: Bool,
        isDefaultOutput: Bool, isAliveKnown: Bool = true
    ) {
        self.uid = uid
        self.name = name
        self.outputChannelsPerStream = outputChannelsPerStream
        self.nominalSampleRate = nominalSampleRate
        self.isAlive = isAlive
        self.isDefaultOutput = isDefaultOutput
        self.isAliveKnown = isAliveKnown
    }

    /// Output channels summed over all output streams.
    public var outputChannelCount: Int { outputChannelsPerStream.reduce(0, +) }
}

/// What a raw listener saw. It carries no value: the model re-reads the whole list.
public enum DeviceSignal: Equatable, Sendable {
    case deviceList
    case defaultOutput
    case sampleRate
    case alive
}

/// The source of device state and raw change signals. The real one reads Core Audio, tests use a fake.
public protocol DeviceMonitoring: Sendable {
    /// All output devices right now.
    func snapshot() throws -> [DeviceInfo]

    /// Calls `handler` on an arbitrary queue for each raw change of the device list, the default
    /// output, a nominal sample rate or the alive flag. Signals are not debounced and may repeat.
    /// `cancel` on the result removes every listener. A signal already in flight may still arrive
    /// after `cancel` returned. `DeviceModel` ignores it through its generation check.
    func observe(_ handler: @escaping @Sendable (DeviceSignal) -> Void) throws -> any Cancellable
}

/// A difference between two snapshots. Devices are matched by uid.
public enum DeviceChange: Equatable, Sendable {
    case added(DeviceInfo)
    case removed(DeviceInfo)
    /// `from` and `to` are uids, nil when no output device is the default.
    case defaultOutputChanged(from: String?, to: String?)
    case sampleRateChanged(uid: String, from: Double, to: Double)
    case aliveChanged(uid: String, isAlive: Bool)
    case channelsChanged(uid: String, from: [Int], to: [Int])

    /// True when a device went away, stopped being alive or stopped being the default output.
    /// `DeviceModel` reports such a change at once instead of after the quiet period.
    public var isLoss: Bool {
        switch self {
        case .removed: true
        case .aliveChanged(_, let isAlive): !isAlive
        case .defaultOutputChanged(let from, _): from != nil
        case .added, .sampleRateChanged, .channelsChanged: false
        }
    }

    /// The changes from `old` to `new`, ordered: removed, added, then per device by uid. A name
    /// change alone is not a change. Empty when the two lists describe the same state.
    public static func diff(old: [DeviceInfo], new: [DeviceInfo]) -> [DeviceChange] {
        let oldByUID = Dictionary(old.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let newByUID = Dictionary(new.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [DeviceChange] = []
        for uid in oldByUID.keys.sorted() where newByUID[uid] == nil {
            changes.append(.removed(oldByUID[uid]!))
        }
        for uid in newByUID.keys.sorted() where oldByUID[uid] == nil {
            changes.append(.added(newByUID[uid]!))
        }
        let oldDefault = old.first { $0.isDefaultOutput }?.uid
        let newDefault = new.first { $0.isDefaultOutput }?.uid
        if oldDefault != newDefault {
            changes.append(.defaultOutputChanged(from: oldDefault, to: newDefault))
        }
        for uid in newByUID.keys.sorted() {
            guard let before = oldByUID[uid], let after = newByUID[uid] else { continue }
            if let from = before.nominalSampleRate, let to = after.nominalSampleRate, from != to {
                changes.append(.sampleRateChanged(uid: uid, from: from, to: to))
            }
            if before.isAlive != after.isAlive {
                changes.append(.aliveChanged(uid: uid, isAlive: after.isAlive))
            }
            if before.outputChannelsPerStream != after.outputChannelsPerStream {
                changes.append(
                    .channelsChanged(
                        uid: uid, from: before.outputChannelsPerStream, to: after.outputChannelsPerStream))
            }
        }
        return changes
    }
}
