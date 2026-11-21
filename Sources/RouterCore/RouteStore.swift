// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The content of `routes.json`.
public struct RouteFile: Equatable, Codable, Sendable {
    /// The schema this build reads and writes.
    public static let currentVersion = 1

    public var schemaVersion: Int
    public var routes: [Route]

    public init(schemaVersion: Int = RouteFile.currentVersion, routes: [Route]) {
        self.schemaVersion = schemaVersion
        self.routes = routes
    }
}

public enum RouteStoreError: Error, Equatable, CustomStringConvertible {
    /// The file was written by a newer build. It is neither read nor overwritten.
    case newerSchema(found: Int, supported: Int)
    /// The file exists but is not a valid route file. It is not overwritten.
    case unreadable(String)
    case io(String)

    public var description: String {
        switch self {
        case .newerSchema(let found, let supported):
            return "routes file has schema version \(found), this build supports up to \(supported). Update the app."
        case .unreadable(let reason):
            return "routes file cannot be read: \(reason)"
        case .io(let reason):
            return "routes file cannot be written: \(reason)"
        }
    }
}

/// Reads and writes the route file as versioned JSON. The path is injected, tests use a
/// temporary directory.
public struct RouteStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/audio-router/routes.json`.
    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return base.appendingPathComponent("audio-router", isDirectory: true)
            .appendingPathComponent("routes.json")
    }

    /// The stored routes, empty when the file does not exist.
    public func load() throws -> [Route] {
        guard let data = try readData() else { return [] }
        return try Self.decode(data).routes
    }

    /// Writes the routes atomically. Refuses, and leaves the file as it is, when the file on disk
    /// has a newer schema or cannot be read.
    public func save(_ routes: [Route]) throws {
        if let existing = try readData() {
            _ = try Self.decode(existing)
        }
        let data = try Self.encode(RouteFile(routes: routes))
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw RouteStoreError.io(String(cString: strerror(errno)))
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? RouteStoreError { throw error }
            throw RouteStoreError.io(error.localizedDescription)
        }
    }

    /// Stable output: sorted keys, indented, a final newline.
    public static func encode(_ file: RouteFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file) + Data("\n".utf8)
    }

    /// Checks the version before the routes, so a newer file with another shape reports the
    /// version and not a decoding error.
    public static func decode(_ data: Data) throws -> RouteFile {
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw RouteStoreError.unreadable("no schemaVersion")
        }
        guard header.schemaVersion <= RouteFile.currentVersion else {
            throw RouteStoreError.newerSchema(found: header.schemaVersion, supported: RouteFile.currentVersion)
        }
        guard header.schemaVersion >= 1 else {
            throw RouteStoreError.unreadable("schemaVersion \(header.schemaVersion) is not valid")
        }
        do {
            return try decoder.decode(RouteFile.self, from: data)
        } catch {
            throw RouteStoreError.unreadable(String(describing: error))
        }
    }

    private func readData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw RouteStoreError.unreadable(error.localizedDescription)
        }
    }
}
