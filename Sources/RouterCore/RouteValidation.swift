// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a route does not fit the devices and processes of the moment.
public enum RouteValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyBundleID(route: UUID)
    case unknownDevice(route: UUID, uid: String)
    /// The destination pair needs channels `first` and `first + 1`, the device has fewer.
    case pairOutOfRange(route: UUID, first: Int, deviceChannels: Int)
    /// Another enabled route writes at least one of the same channels of the same device. The
    /// pairs may be identical or overlap by one channel, for example 3,4 and 4,5.
    case duplicateDestinationPair(route: UUID, first: Int, other: UUID, otherFirst: Int, uid: String)
    /// Two routes carry the same id. Reported for every later route with that id.
    case duplicateRouteID(route: UUID)

    /// The route the error is about.
    public var routeID: UUID {
        switch self {
        case .emptyBundleID(let route), .unknownDevice(let route, _), .pairOutOfRange(let route, _, _),
            .duplicateDestinationPair(let route, _, _, _, _), .duplicateRouteID(let route):
            return route
        }
    }

    public var description: String {
        switch self {
        case .emptyBundleID(let route):
            return "route \(Self.label(route)): the bundle id is empty"
        case .unknownDevice(let route, let uid):
            return "route \(Self.label(route)): no output device with uid \(uid)"
        case .pairOutOfRange(let route, let first, let deviceChannels):
            return
                "route \(Self.label(route)): channels \(first),\(first + 1) do not fit a device with "
                + "\(deviceChannels) output channels"
        case .duplicateDestinationPair(let route, let first, let other, let otherFirst, let uid):
            return
                "route \(Self.label(route)): channels \(first),\(first + 1) of device \(uid) share a channel "
                + "with channels \(otherFirst),\(otherFirst + 1) of route \(Self.label(other))"
        case .duplicateRouteID(let route):
            return "route \(Self.label(route)): the route id is used more than once"
        }
    }

    private static func label(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

/// Checks routes against a snapshot of the devices and processes.
public enum RouteValidator {
    /// Returns every problem, in route order. An empty result means the routes are valid.
    ///
    /// An app that is not running is not an error: the route waits for it. So `processes` does not
    /// decide anything yet. It is part of the signature so the check can grow without a new API.
    ///
    /// A disabled route to an unplugged device is a normal state. So a disabled route is checked
    /// for an empty bundle id and a duplicate route id only. It skips the device and pair checks
    /// and never claims a destination channel.
    ///
    /// Two enabled routes of the same device clash when they share any channel, so 3,4 and 4,5
    /// clash and 3,4 and 5,6 do not. Every overlapping pair of routes is reported once, so a chain
    /// 3,4 / 4,5 / 5,6 gives two errors. The model itself allows any adjacent pair.
    public static func validate(
        _ routes: [Route], devices: [OutputDevice], processes: [AudioProcess]
    ) -> [RouteValidationError] {
        _ = processes
        var errors: [RouteValidationError] = []
        var seenIDs: Set<UUID> = []
        var claims: [Claim] = []
        for route in routes {
            if !seenIDs.insert(route.id).inserted {
                errors.append(.duplicateRouteID(route: route.id))
            }
            if route.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyBundleID(route: route.id))
            }
            guard route.enabled else { continue }
            guard let device = devices.first(where: { $0.uid == route.destinationUID }) else {
                errors.append(.unknownDevice(route: route.id, uid: route.destinationUID))
                continue
            }
            if route.destinationPair.second > device.channelCount {
                errors.append(
                    .pairOutOfRange(
                        route: route.id, first: route.destinationPair.first, deviceChannels: device.channelCount))
                continue
            }
            let first = route.destinationPair.first
            // Every overlapping pair of routes is reported once, against each earlier claim. An entry
            // with the same id is skipped: that case is already `duplicateRouteID`.
            for other in claims
            where other.uid == route.destinationUID && other.route != route.id && abs(other.first - first) <= 1 {
                errors.append(
                    .duplicateDestinationPair(
                        route: route.id, first: first, other: other.route, otherFirst: other.first,
                        uid: route.destinationUID))
            }
            claims.append(Claim(uid: route.destinationUID, first: first, route: route.id))
        }
        return errors
    }

    private struct Claim {
        let uid: String
        let first: Int
        let route: UUID
    }
}
