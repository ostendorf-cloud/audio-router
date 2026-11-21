// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a route does not fit the devices and processes of the moment.
public enum RouteValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyBundleID(route: UUID)
    case unknownDevice(route: UUID, uid: String)
    /// The destination pair needs channels `first` and `first + 1`, the device has fewer.
    case pairOutOfRange(route: UUID, first: Int, deviceChannels: Int)
    /// Another enabled route writes the same pair of the same device.
    case duplicateDestinationPair(route: UUID, other: UUID, uid: String, first: Int)

    /// The route the error is about.
    public var routeID: UUID {
        switch self {
        case .emptyBundleID(let route), .unknownDevice(let route, _), .pairOutOfRange(let route, _, _),
            .duplicateDestinationPair(let route, _, _, _):
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
        case .duplicateDestinationPair(let route, let other, let uid, let first):
            return
                "route \(Self.label(route)): channels \(first),\(first + 1) of device \(uid) are already used "
                + "by route \(Self.label(other))"
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
    /// Only enabled routes occupy a destination pair, a disabled route never clashes.
    public static func validate(
        _ routes: [Route], devices: [OutputDevice], processes: [AudioProcess]
    ) -> [RouteValidationError] {
        _ = processes
        var errors: [RouteValidationError] = []
        var claimed: [PairKey: UUID] = [:]
        for route in routes {
            if route.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyBundleID(route: route.id))
            }
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
            guard route.enabled else { continue }
            let key = PairKey(uid: route.destinationUID, first: route.destinationPair.first)
            if let other = claimed[key] {
                errors.append(
                    .duplicateDestinationPair(
                        route: route.id, other: other, uid: route.destinationUID, first: key.first))
            } else {
                claimed[key] = route.id
            }
        }
        return errors
    }

    private struct PairKey: Hashable {
        let uid: String
        let first: Int
    }
}
