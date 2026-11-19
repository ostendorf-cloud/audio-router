// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// Groups helper processes under the bundle id of their parent app.
///
/// Browsers and Electron apps play audio from helper processes whose bundle ids extend the
/// parent id, for example `com.google.Chrome.helper.Renderer` under `com.google.Chrome`. Whether
/// every real app follows this scheme is an open question the prototype answers.
public enum BundleGrouping {
    /// The bundle id of the parent app for `bundleID`.
    ///
    /// 1. A component named `helper` cuts the id off, so a helper whose parent plays no audio
    ///    still groups under the parent id.
    /// 2. The shortest other id in `all` that is a dot separated prefix of the result wins.
    /// 3. Otherwise the result is its own parent.
    public static func parentID(of bundleID: String, among all: Set<String>) -> String {
        let components = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        var base = bundleID
        if let index = components.firstIndex(where: { $0.lowercased() == "helper" }), index > 0 {
            base = components[..<index].joined(separator: ".")
        }
        let prefixes = all.filter { $0 != base && base.hasPrefix($0 + ".") }
        return prefixes.min(by: { $0.count < $1.count }) ?? base
    }

    /// Groups the processes by parent app. Processes without a bundle id are left out because a
    /// route cannot name them. Groups and their processes are sorted for stable output.
    public static func groups(_ processes: [AudioProcess]) -> [AppGroup] {
        let named = processes.filter { !$0.bundleID.isEmpty }
        let all = Set(named.map(\.bundleID))
        let byParent = Dictionary(grouping: named) { parentID(of: $0.bundleID, among: all) }
        return byParent.keys.sorted().map { parent in
            let members = byParent[parent, default: []].sorted {
                ($0.bundleID, $0.pid) < ($1.bundleID, $1.pid)
            }
            return AppGroup(bundleID: parent, processes: members)
        }
    }
}
