// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Plain text output of the devices and apps commands.
public enum Formatting {
    public static func devices(_ devices: [OutputDevice]) -> String {
        guard !devices.isEmpty else { return "No output devices." }
        let sorted = devices.sorted { ($0.name, $0.uid) < ($1.name, $1.uid) }
        let header = ["UID", "NAME", "CHANNELS"]
        let rows = sorted.map { [$0.uid, $0.name, String($0.channelCount)] }
        return table([header] + rows)
    }

    public static func apps(_ processes: [AudioProcess]) -> String {
        let groups = BundleGrouping.groups(processes)
        guard !groups.isEmpty else { return "No audio processes with a bundle id." }
        var lines: [String] = []
        for group in groups {
            let playing = group.processes.filter(\.isRunningOutput).count
            lines.append("\(group.bundleID)  (\(group.processes.count) processes, \(playing) playing)")
            for process in group.processes {
                let state = process.isRunningOutput ? "playing" : "idle"
                lines.append("  \(process.bundleID)  pid \(process.pid)  \(state)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Decibels with one decimal. Silence is `-inf`.
    static func decibels(_ value: Double) -> String {
        value == -Double.infinity ? "-inf" : String(format: "%.1f", value)
    }

    /// One line per interval: peak and RMS of the tap input and of the output, in dBFS.
    public static func meter(_ reading: MeterReading) -> String {
        func level(_ name: String, _ level: LevelReading) -> String {
            "\(name) peak \(decibels(level.peakDBFS)) dBFS rms \(decibels(level.rmsDBFS)) dBFS"
        }
        return "meter: \(level("tap", reading.input)) | \(level("out", reading.output)) | \(reading.frames) frames"
    }

    static func hertz(_ value: Double?) -> String {
        guard let value, value > 0 else { return "unknown" }
        return value == value.rounded() ? String(format: "%.0f Hz", value) : String(format: "%.1f Hz", value)
    }

    static func stream(_ format: StreamFormatInfo) -> String {
        "\(hertz(format.sampleRate)), \(format.channels) channels, "
            + (format.interleaved ? "interleaved" : "not interleaved")
    }

    /// The lines printed once the route runs: formats, buffer layout and the tap's buffers.
    public static func routeInfo(_ info: RouteInfo) -> [String] {
        let tapBuffers =
            info.tapBuffers.count == 1
            ? "buffer \(info.tapBuffers.lowerBound)"
            : "buffers \(info.tapBuffers.lowerBound) to \(info.tapBuffers.upperBound - 1)"
        return [
            "tap format: \(stream(info.tap))",
            "aggregate input buffers: \(info.inputBuffers), tap in \(tapBuffers)",
            "aggregate input streams: " + info.inputStreams.map(stream).joined(separator: "; "),
            "aggregate output buffers: \(info.outputBuffers)",
            "aggregate output streams: " + info.outputStreams.map(stream).joined(separator: "; "),
            "sample rate: tap \(hertz(info.tap.sampleRate)), aggregate \(hertz(info.aggregateSampleRate)), "
                + "device \(hertz(info.deviceSampleRate))",
            "tap mode: \(info.tapMode.rawValue), source channels \(info.sourceChannels.first),"
                + "\(info.sourceChannels.second), tap buffer: \(choice(info.tapBufferChoice))",
            "tap description: mixdown \(info.tapIsMixdown), exclusive \(info.tapIsExclusive)",
        ] + info.probes
    }

    static func choice(_ choice: TapBufferChoice) -> String {
        switch choice {
        case .uniqueShape:
            return "the only buffer of the tap shape"
        case .lastByMeasuredOrder:
            return "the last of several buffers of the tap shape, the layout excludes the other order "
                + "(device inputs plus tap shape). The buffer content is not proven. Check the signal line "
                + "or force the buffer with --tap-buffer"
        case .override:
            return "named by --tap-buffer"
        }
    }

    /// One line: the channels that carried signal, tap channels and device input channels, each
    /// counted from 1 inside their group.
    /// The flags are sticky and any non zero sample counts, so the device side shows input noise.
    /// `preferred` is information only, the pair the device itself names for stereo.
    public static func activity(tap: [Int], device: [Int], preferred: String? = nil) -> String {
        func list(_ channels: [Int]) -> String {
            channels.isEmpty ? "none" : channels.map(String.init).joined(separator: ",")
        }
        var line = "signal on tap channels: \(list(tap)) | on device input channels (noise counts): \(list(device))"
        if let preferred { line += " | device preferred stereo pair: \(preferred)" }
        return line
    }

    /// The warning after 10 seconds without a sample. In the device stream mode the tap only
    /// holds audio that goes to the target device, so the app must play there.
    public static func silenceWarning(bundleID: String, mode: TapMode, deviceName: String) -> String {
        var text =
            "warning: no audio arrived in 10 seconds. If \(bundleID) is playing, the system audio "
            + "capture permission may be missing or denied for this terminal app: a denied tap may "
            + "deliver silence instead of an error. See docs/prototype-findings.md."
        if mode == .deviceStream {
            text +=
                " In device-stream mode the tap only holds audio that \(bundleID) plays to \(deviceName). "
                + "If the app plays to another output device, set that device as the macOS default output "
                + "or route to that device."
        }
        return text + "\n"
    }

    /// Left aligned columns separated by two spaces, no trailing spaces.
    static func table(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1
                    ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
