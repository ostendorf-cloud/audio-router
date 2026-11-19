// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// The arguments of the route command, after parsing and before they meet real devices.
public struct RouteArguments: Equatable, Sendable {
    public let bundleID: String
    public let deviceUID: String
    public let channels: ChannelPair
    /// Print the levels of the tap and of the output once a second.
    public let meter: Bool
    public let tapMode: TapMode
    /// The pair of tap channels that carries the app, counted from 1.
    public let sourceChannels: ChannelPair
    /// Index of the first tap buffer in the aggregate's input list, counted from 0. Nil: detect.
    public let tapBuffer: Int?

    public init(
        bundleID: String, deviceUID: String, channels: ChannelPair, meter: Bool = false,
        tapMode: TapMode = .stereoMixdown, sourceChannels: ChannelPair = .firstPair, tapBuffer: Int? = nil
    ) {
        self.bundleID = bundleID
        self.deviceUID = deviceUID
        self.channels = channels
        self.meter = meter
        self.tapMode = tapMode
        self.sourceChannels = sourceChannels
        self.tapBuffer = tapBuffer
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
          audio-router-proto route --bundle-id <id> --device <uid> --channels <n>,<n+1> [--meter]
                                   [--tap-mode stereo-mixdown|device-stream]
                                   [--source-channels <n>,<n+1>] [--tap-buffer <n>]

        Channels count from 1. The pair must be two adjacent channels, for example 3,4.
        --tap-mode picks how the tap is made. The default is stereo-mixdown. device-stream taps the
        output stream 0 of the device without a mixdown, see docs/prototype-findings.md section 9.
        --source-channels names the tap channels that carry the app, default 1,2.
        --tap-buffer forces the index (from 0) of the first tap buffer in the aggregate's input list.
        --meter prints the peak and RMS level of the tap and of the output in dBFS once a second to stdout.
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
    public static func parseChannels(_ text: String, flag: String = "--channels") throws -> ChannelPair {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = Int(parts[0]), let second = Int(parts[1]) else {
            throw RouterError.usage("\(flag) takes two integers like 3,4, got \(text).")
        }
        guard first >= 1 else {
            throw RouterError.usage("\(flag) counts from 1, got \(first).")
        }
        guard second == first + 1 else {
            throw RouterError.usage("\(flag) must be two adjacent channels like 3,4, got \(text).")
        }
        return try ChannelPair(first: first, flag: flag)
    }

    /// Parses the value of `--tap-mode`.
    public static func parseTapMode(_ text: String) throws -> TapMode {
        guard let mode = TapMode(rawValue: text) else {
            let names = TapMode.allCases.map(\.rawValue).joined(separator: ", ")
            throw RouterError.usage("--tap-mode takes one of \(names), got \(text).")
        }
        return mode
    }

    /// Parses the value of `--tap-buffer`, a buffer index from 0.
    public static func parseTapBuffer(_ text: String) throws -> Int {
        guard let index = Int(text), index >= 0, index <= 65_536 else {
            throw RouterError.usage("--tap-buffer takes a buffer index from 0, got \(text).")
        }
        return index
    }

    private static func rejectExtra(_ rest: [String], command: String) throws {
        if let extra = rest.first {
            throw RouterError.usage("The \(command) command takes no arguments, got \(extra).")
        }
    }

    private static let knownFlags: Set<String> = [
        "--bundle-id", "--device", "--channels", "--tap-mode", "--source-channels", "--tap-buffer",
    ]

    private static func parseRoute(_ arguments: [String]) throws -> RouteArguments {
        var values: [String: String] = [:]
        var meter = false
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--meter" {
                guard !meter else { throw RouterError.usage("--meter given twice.") }
                meter = true
                index += 1
                continue
            }
            guard knownFlags.contains(flag) else {
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
            channels: try parseChannels(values["--channels", default: ""]),
            meter: meter,
            tapMode: try values["--tap-mode"].map(parseTapMode) ?? .stereoMixdown,
            sourceChannels: try values["--source-channels"].map { try parseChannels($0, flag: "--source-channels") }
                ?? .firstPair,
            tapBuffer: try values["--tap-buffer"].map(parseTapBuffer)
        )
    }
}
