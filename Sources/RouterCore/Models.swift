// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// A Core Audio object id. Core Audio's AudioObjectID is a UInt32.
public typealias ObjectID = UInt32

/// An output device as the user sees it.
public struct OutputDevice: Equatable, Sendable {
    public let objectID: ObjectID
    public let uid: String
    public let name: String
    /// Output channels summed over all output streams.
    public let channelCount: Int

    public init(objectID: ObjectID, uid: String, name: String, channelCount: Int) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
    }
}

/// A client process connected to Core Audio.
public struct AudioProcess: Equatable, Sendable {
    public let objectID: ObjectID
    public let pid: Int32
    /// Empty when the process has no bundle id.
    public let bundleID: String
    public let isRunningOutput: Bool

    public init(objectID: ObjectID, pid: Int32, bundleID: String, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

/// A parent app and the processes that belong to it, helpers included.
public struct AppGroup: Equatable, Sendable {
    public let bundleID: String
    public let processes: [AudioProcess]

    public init(bundleID: String, processes: [AudioProcess]) {
        self.bundleID = bundleID
        self.processes = processes
    }
}

/// Two adjacent output channels, counted from 1 like the labels on a mixer.
public struct ChannelPair: Equatable, Sendable {
    public let first: Int

    public var second: Int { first + 1 }

    /// Channels count from 1. The upper bound only keeps `second` clear of overflow.
    public init(first: Int) throws {
        guard first >= 1, first <= 65_536 else {
            throw RouterError.usage("--channels counts from 1 and stays below 65537, got \(first).")
        }
        self.first = first
    }
}
