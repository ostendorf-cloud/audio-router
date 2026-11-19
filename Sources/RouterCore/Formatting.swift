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
