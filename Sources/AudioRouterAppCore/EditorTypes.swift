// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore

/// An output device the editor offers as destination.
public struct EditorDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    /// Output channels summed over all streams.
    public let channelCount: Int

    public var id: String { uid }

    public init(uid: String, name: String, channelCount: Int) {
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
    }
}

/// A running app the editor offers in its app list.
public struct EditorApp: Equatable, Sendable, Identifiable {
    public let bundleID: String
    public let isPlaying: Bool

    public var id: String { bundleID }

    public init(bundleID: String, isPlaying: Bool) {
        self.bundleID = bundleID
        self.isPlaying = isPlaying
    }

    /// The menu text, for example `com.example.music (playing)`.
    public var title: String { isPlaying ? "\(bundleID) (playing)" : bundleID }
}

/// Lists the output devices for the editor. The real one reads the engine snapshot, tests use a fake.
public protocol DeviceProviding: Sendable {
    func devices() -> [EditorDevice]
}

/// Lists the running audio apps for the editor. The real one reads the engine snapshot, tests use a fake.
public protocol AppProviding: Sendable {
    func apps() -> [EditorApp]
}

/// The route file as the editor sees it. `RouteStore` is the real one.
public protocol EditorRouteStoring: Sendable {
    func load() throws -> [Route]
    func save(_ routes: [Route]) throws
}

extension RouteStore: EditorRouteStoring {}

/// The store used when the application support directory cannot be found. Every call fails with the
/// reason, so the editor shows it and writes nothing anywhere else.
public struct EditorUnavailableStore: EditorRouteStoring {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func load() throws -> [Route] { throw RouteStoreError.io(reason) }
    public func save(_ routes: [Route]) throws { throw RouteStoreError.io(reason) }
}

/// Reads devices and apps from the engine snapshot. The engine owns the one device model and the one
/// process monitor, the UI starts no second one.
public struct EditorSnapshotProvider: DeviceProviding, AppProviding {
    private let engine: any ShellEngine

    public init(engine: any ShellEngine) {
        self.engine = engine
    }

    public func devices() -> [EditorDevice] {
        engine.snapshot.devices
            .filter { $0.outputChannelCount > 0 }
            .map { EditorDevice(uid: $0.uid, name: $0.name, channelCount: $0.outputChannelCount) }
    }

    public func apps() -> [EditorApp] {
        engine.snapshot.apps.map { group in
            EditorApp(bundleID: group.bundleID, isPlaying: group.processes.contains(where: \.isRunningOutput))
        }
    }
}

/// The values of the form. Pairs hold the number of their first channel, counted from 1.
public struct EditorDraft: Equatable, Sendable {
    /// Nil for a new route.
    public var id: UUID?
    public var name: String
    public var appBundleID: String
    public var destinationUID: String
    public var destinationFirst: Int
    public var sourceFirst: Int
    public var enabled: Bool

    public init(
        id: UUID? = nil, name: String = "", appBundleID: String = "", destinationUID: String = "",
        destinationFirst: Int = 1, sourceFirst: Int = 1, enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.appBundleID = appBundleID
        self.destinationUID = destinationUID
        self.destinationFirst = destinationFirst
        self.sourceFirst = sourceFirst
        self.enabled = enabled
    }

    public init(route: Route) {
        self.init(
            id: route.id, name: route.name, appBundleID: route.appBundleID, destinationUID: route.destinationUID,
            destinationFirst: route.destinationPair.first, sourceFirst: route.sourcePair.first,
            enabled: route.enabled)
    }
}

/// The form field an inline message belongs to.
public enum EditorField: Equatable, Sendable {
    case app
    case device
    case destinationPair
    case sourcePair
    /// A problem that no field owns.
    case general
}

/// One inline message, shown under its field.
public struct EditorIssue: Equatable, Sendable {
    public let field: EditorField
    public let message: String

    public init(field: EditorField, message: String) {
        self.field = field
        self.message = message
    }
}

/// One line of the route list in the settings window.
public struct EditorRouteRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    /// For example `com.example.music to Mixer, channels 3,4`.
    public let detail: String

    public init(id: UUID, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// The short texts of the editor. No runtime error texts live here, issue 23 owns those.
public enum EditorText {
    public static let destinationHint =
        "The app must play to this device. An app that plays to another output sends nothing to the route."
    public static let appNotRunning = "Not running now. The route waits for the app."
    public static let chooseApp = "Choose an app or type a bundle id."
    public static let chooseDevice = "Choose a device."
    public static let deviceMissing = "This device is not connected."
    public static let sameRouteTwice = "The route id is used twice."
    public static let invalidPair = "The channels must count from 1."

    public static func channelCount(_ count: Int) -> String {
        count == 1 ? "1 output channel" : "\(count) output channels"
    }

    public static func pairLabel(_ first: Int) -> String { "\(first),\(first + 1)" }
}
