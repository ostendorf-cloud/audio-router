// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One stored route: an app, copied onto a channel pair of one output device.
///
/// A route names the app by bundle id and the device by uid, never by object id or PID, so it
/// survives a restart of the app and of Core Audio. It has no gain field: every route copies at
/// unity. Pairs count from 1 like the labels on a mixer, `ChannelPair(first: 3)` is channels 3,4.
public struct Route: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// The parent bundle id. Helper processes are grouped under it at run time.
    public var appBundleID: String
    /// The uid of the destination output device.
    public var destinationUID: String
    /// The channels the route writes on the destination device.
    public var destinationPair: ChannelPair
    /// The tap channels the route reads.
    public var sourcePair: ChannelPair
    public var enabled: Bool

    public init(
        id: UUID = UUID(), name: String, appBundleID: String, destinationUID: String,
        destinationPair: ChannelPair, sourcePair: ChannelPair = .firstPair, enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.appBundleID = appBundleID
        self.destinationUID = destinationUID
        self.destinationPair = destinationPair
        self.sourcePair = sourcePair
        self.enabled = enabled
    }
}

extension Route: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, appBundleID, destinationUID, destinationPair, sourcePair, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.appBundleID = try container.decode(String.self, forKey: .appBundleID)
        self.destinationUID = try container.decode(String.self, forKey: .destinationUID)
        self.destinationPair = try Route.decodePair(container, .destinationPair)
        self.sourcePair = try Route.decodePair(container, .sourcePair)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(appBundleID, forKey: .appBundleID)
        try container.encode(destinationUID, forKey: .destinationUID)
        try container.encode(destinationPair.first, forKey: .destinationPair)
        try container.encode(sourcePair.first, forKey: .sourcePair)
        try container.encode(enabled, forKey: .enabled)
    }

    /// A pair is stored as the number of its first channel, counted from 1.
    private static func decodePair(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> ChannelPair {
        let first = try container.decode(Int.self, forKey: key)
        do {
            return try ChannelPair(first: first, flag: key.rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "\(key.rawValue) must count from 1, got \(first).")
        }
    }
}
