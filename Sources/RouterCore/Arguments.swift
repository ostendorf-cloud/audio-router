// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// The arguments of the route command, after parsing and before they meet real devices.
public struct RouteArguments: Equatable, Sendable {
    public let bundleID: String
    public let deviceUID: String
    public let channels: ChannelPair

    public init(bundleID: String, deviceUID: String, channels: ChannelPair) {
        self.bundleID = bundleID
        self.deviceUID = deviceUID
        self.channels = channels
    }
}

public enum Command: Equatable, Sendable {
    case devices
    case apps
    case route(RouteArguments)
    case help
}

public enum ArgumentParser {
    public static let usage = """
        usage:
          audio-router-proto devices
          audio-router-proto apps
          audio-router-proto route --bundle-id <id> --device <uid> --channels <n>,<n+1>

        Channels count from 1. The pair must be two adjacent channels, for example 3,4.
        """

    /// Parses the arguments after the program name.
    public static func parse(_ arguments: [String]) throws -> Command {
        guard let name = arguments.first else {
            throw RouterError.usage(usage)
        }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "devices":
            try rejectExtra(rest, command: name)
            return .devices
        case "apps":
            try rejectExtra(rest, command: name)
            return .apps
        case "route":
            return .route(try parseRoute(rest))
        case "help", "--help", "-h":
            return .help
        default:
            throw RouterError.usage("Unknown command \(name).\n\(usage)")
        }
    }

    /// Parses `n,n+1`. Both values are integers, the second is the first plus one, the first is
    /// at least 1.
    public static func parseChannels(_ text: String) throws -> ChannelPair {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = Int(parts[0]), let second = Int(parts[1]) else {
            throw RouterError.usage("--channels takes two integers like 3,4, got \(text).")
        }
        guard first >= 1 else {
            throw RouterError.usage("--channels counts from 1, got \(first).")
        }
        guard second == first + 1 else {
            throw RouterError.usage("--channels must be two adjacent channels like 3,4, got \(text).")
        }
        return try ChannelPair(first: first)
    }

    private static func rejectExtra(_ rest: [String], command: String) throws {
        if let extra = rest.first {
            throw RouterError.usage("The \(command) command takes no arguments, got \(extra).")
        }
    }

    private static func parseRoute(_ arguments: [String]) throws -> RouteArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--bundle-id", "--device", "--channels"].contains(flag) else {
                throw RouterError.usage("Unknown option \(flag).\n\(usage)")
            }
            guard index + 1 < arguments.count else {
                throw RouterError.usage("\(flag) needs a value.")
            }
            guard values[flag] == nil else {
                throw RouterError.usage("\(flag) given twice.")
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        for flag in ["--bundle-id", "--device", "--channels"] where values[flag] == nil {
            throw RouterError.usage("route needs \(flag).\n\(usage)")
        }
        let bundleID = values["--bundle-id", default: ""]
        let deviceUID = values["--device", default: ""]
        guard !bundleID.isEmpty, !deviceUID.isEmpty else {
            throw RouterError.usage("--bundle-id and --device must not be empty.")
        }
        return RouteArguments(
            bundleID: bundleID,
            deviceUID: deviceUID,
            channels: try parseChannels(values["--channels", default: ""])
        )
    }
}
