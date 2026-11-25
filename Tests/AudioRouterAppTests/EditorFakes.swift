// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RouterCore

@testable import AudioRouterAppCore

/// An in memory route file that records every save.
final class FakeRouteStore: EditorRouteStoring, @unchecked Sendable {
    struct Refused: Error, CustomStringConvertible {
        var description: String { "disk full" }
    }

    private let lock = NSLock()
    private var current: [Route]
    private var written: [[Route]] = []
    private var refuses = false

    init(_ routes: [Route] = []) { current = routes }

    var failSaves: Bool {
        get { lock.withLock { refuses } }
        set { lock.withLock { refuses = newValue } }
    }
    var saves: [[Route]] { lock.withLock { written } }
    var stored: [Route] { lock.withLock { current } }

    func load() throws -> [Route] { lock.withLock { current } }

    func save(_ routes: [Route]) throws {
        try lock.withLock {
            if refuses { throw Refused() }
            current = routes
            written.append(routes)
        }
    }
}

final class FakeDevices: DeviceProviding, AppProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var deviceList: [EditorDevice]
    private var appList: [EditorApp]

    init(devices: [EditorDevice] = [], apps: [EditorApp] = []) {
        deviceList = devices
        appList = apps
    }

    func set(devices: [EditorDevice]) { lock.withLock { deviceList = devices } }
    func devices() -> [EditorDevice] { lock.withLock { deviceList } }
    func apps() -> [EditorApp] { lock.withLock { appList } }
}

/// Like the real engine: `setRoutes` only queues, the snapshot follows at `flush`.
final class LateApplyEngine: ShellEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var applied: [Route]
    private var queued: [[Route]] = []
    private var sent: [[Route]] = []

    init(routes: [Route] = []) { applied = routes }

    var sentLists: [[Route]] { lock.withLock { sent } }

    var snapshot: EngineSnapshot {
        let routes = lock.withLock { applied }
        return EngineSnapshot(
            isOn: true,
            routes: routes.map {
                RouteStatus(route: $0, state: $0.enabled ? .waitingForApp : .disabled, teardownFailures: [])
            }, devices: [], apps: [])
    }

    func observe(_ handler: @escaping @Sendable (EngineSnapshot) -> Void) -> any Cancellable { NoCancel() }
    func start() throws {}
    func setOn(_ on: Bool) {}
    func retryNow(_ id: UUID) {}
    func meterReadings() -> [UUID: MeterReading] { [:] }
    func stopAll() -> [UUID: [String]] { [:] }

    func setRoutes(_ routes: [Route]) {
        lock.withLock {
            queued.append(routes)
            sent.append(routes)
        }
    }

    /// The engine queue catches up.
    func flush() {
        lock.withLock {
            if let last = queued.last { applied = last }
            queued = []
        }
    }

    private struct NoCancel: Cancellable {
        func cancel() {}
    }
}

enum EditorSamples {
    static let mixer = EditorDevice(uid: "mixer", name: "Mixer", channelCount: 32)
    static let stereo = EditorDevice(uid: "stereo", name: "Speakers", channelCount: 2)
    static let musicApp = EditorApp(bundleID: "com.example.music", isPlaying: true)

    static func route(
        _ id: Int, name: String, device: String = "mixer", pair: Int, enabled: Bool = true
    ) -> Route {
        Route(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000010\(id)")!, name: name,
            appBundleID: "com.example.app\(id)", destinationUID: device,
            destinationPair: try! ChannelPair(first: pair), enabled: enabled)
    }
}
