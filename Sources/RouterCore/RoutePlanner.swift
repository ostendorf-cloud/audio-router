// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// What a route will do, after the arguments met the real device and process lists.
public struct RoutePlan: Equatable, Sendable {
    public let device: OutputDevice
    public let channels: ChannelPair
    /// The parent app's bundle id.
    public let appBundleID: String
    /// Every process of the app, helpers included. The tap covers exactly these.
    public let processes: [AudioProcess]
}

public enum RoutePlanner {
    /// Validates the arguments against the current devices and processes.
    public static func plan(
        _ arguments: RouteArguments,
        devices: [OutputDevice],
        processes: [AudioProcess]
    ) throws -> RoutePlan {
        guard let device = devices.first(where: { $0.uid == arguments.deviceUID }) else {
            throw RouterError.unknownDevice(uid: arguments.deviceUID)
        }
        guard arguments.channels.second <= device.channelCount else {
            throw RouterError.channelsOutOfRange(
                first: arguments.channels.first,
                deviceChannels: device.channelCount,
                deviceName: device.name
            )
        }
        // The requested id may name the parent app or any of its helpers.
        let named = processes.filter { !$0.bundleID.isEmpty }
        let wanted = BundleGrouping.parentID(
            of: arguments.bundleID, among: Set(named.map(\.bundleID)))
        let members = BundleGrouping.groups(named).first { $0.bundleID == wanted }?.processes ?? []
        guard !members.isEmpty else {
            throw RouterError.noMatchingProcess(bundleID: arguments.bundleID)
        }
        return RoutePlan(
            device: device,
            channels: arguments.channels,
            appBundleID: wanted,
            processes: members
        )
    }
}
