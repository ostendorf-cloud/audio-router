// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RouterCore

/// Golden files live in `Golden/` next to this file. The tests only read them, they never
/// rewrite one, so a change of the format shows up as a failing diff.
enum Golden {
    static func url(_ name: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent("Golden").appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

enum RouteSamples {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012x", n))!
    }

    static func route(
        _ n: Int, bundle: String = "com.example.player", uid: String = "device-uid-a", pair: Int = 3,
        enabled: Bool = true
    ) -> Route {
        Route(
            id: id(n), name: "Route \(n)", appBundleID: bundle, destinationUID: uid,
            destinationPair: try! ChannelPair(first: pair), sourcePair: .firstPair, enabled: enabled)
    }

    static let goldenRoutes = [
        Route(
            id: id(1), name: "Player to 3,4", appBundleID: "com.example.player", destinationUID: "device-uid-a",
            destinationPair: try! ChannelPair(first: 3)),
        Route(
            id: id(2), name: "Browser to 5,6", appBundleID: "com.example.browser", destinationUID: "device-uid-a",
            destinationPair: try! ChannelPair(first: 5), enabled: false),
    ]
}

struct RouteStoreTests {
    private func temporaryStore() throws -> (RouteStore, URL) {
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("audio-router-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (RouteStore(url: directory.appendingPathComponent("nested/routes.json")), directory)
    }

    @Test func encodeMatchesTheGoldenFile() throws {
        let data = try RouteStore.encode(RouteFile(routes: RouteSamples.goldenRoutes))
        #expect(String(decoding: data, as: UTF8.self) == (try Golden.text("routes-v1.json")))
    }

    @Test func decodeReadsTheGoldenFile() throws {
        let file = try RouteStore.decode(try Golden.data("routes-v1.json"))
        #expect(file == RouteFile(routes: RouteSamples.goldenRoutes))
    }

    @Test func aMissingFileLoadsEmpty() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.load().isEmpty)
    }

    @Test func saveThenLoadRoundTripsAndWritesTheGoldenBytes() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(RouteSamples.goldenRoutes)
        #expect(try store.load() == RouteSamples.goldenRoutes)
        #expect(try String(contentsOf: store.url, encoding: .utf8) == (try Golden.text("routes-v1.json")))
    }

    @Test func saveLeavesNoTemporaryFileBehind() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(RouteSamples.goldenRoutes)
        try store.save([])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        #expect(names == ["routes.json"])
    }

    @Test func aNewerSchemaIsRefusedAndTheFileStaysAsItWas() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Golden.data("routes-v2-unknown.json")
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: store.url)

        #expect(throws: RouteStoreError.newerSchema(found: 2, supported: 1)) { try store.load() }
        #expect(throws: RouteStoreError.newerSchema(found: 2, supported: 1)) {
            try store.save(RouteSamples.goldenRoutes)
        }
        #expect(try Data(contentsOf: store.url) == original)
    }

    @Test func anUnreadableFileIsNotOverwritten() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let garbage = Data("not json".utf8)
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try garbage.write(to: store.url)

        #expect(throws: RouteStoreError.self) { try store.save([]) }
        #expect(try Data(contentsOf: store.url) == garbage)
    }

    @Test func aPairBelowOneFailsToDecode() throws {
        let json =
            #"{"schemaVersion":1,"routes":[{"id":"00000000-0000-0000-0000-000000000001","name":"n","#
            + #""appBundleID":"b","destinationUID":"u","destinationPair":0,"sourcePair":1,"enabled":true}]}"#
        #expect(throws: RouteStoreError.self) { try RouteStore.decode(Data(json.utf8)) }
    }

    @Test func theDefaultPathIsUnderApplicationSupport() throws {
        let url = try RouteStore.defaultURL()
        #expect(url.path.hasSuffix("Application Support/audio-router/routes.json"))
    }
}

struct RouteValidationTests {
    private func clash(_ route: Int, _ first: Int, with other: Int, _ otherFirst: Int) -> RouteValidationError {
        .duplicateDestinationPair(
            route: RouteSamples.id(route), first: first, other: RouteSamples.id(other), otherFirst: otherFirst,
            uid: "device-uid-a")
    }

    private let devices = [
        OutputDevice(objectID: 1, uid: "device-uid-a", name: "Device A", channelCount: 8)
    ]

    @Test func validRoutesReturnNoErrors() {
        let routes = [
            RouteSamples.route(1, pair: 1), RouteSamples.route(2, pair: 3), RouteSamples.route(3, pair: 7),
        ]
        #expect(RouteValidator.validate(routes, devices: devices, processes: []).isEmpty)
    }

    @Test func eachErrorMatchesTheGoldenFile() throws {
        let routes = [
            RouteSamples.route(0xa1, bundle: "", pair: 1),
            RouteSamples.route(0xa2, uid: "missing-uid"),
            RouteSamples.route(0xa3, pair: 7),
            RouteSamples.route(0xa4, pair: 3),
            RouteSamples.route(0xa5, pair: 3),
            RouteSamples.route(0xa1, pair: 5, enabled: false),
            RouteSamples.route(0xa7, pair: 4),
        ]
        let small = [OutputDevice(objectID: 1, uid: "device-uid-a", name: "Device A", channelCount: 7)]
        let errors = RouteValidator.validate(routes, devices: small, processes: [])
        let lines = errors.map(\.description).joined(separator: "\n") + "\n"
        #expect(lines == (try Golden.text("validation-errors.txt")))
    }

    @Test func theErrorsAreTyped() {
        let small = [OutputDevice(objectID: 1, uid: "device-uid-a", name: "Device A", channelCount: 7)]
        let id = RouteSamples.id
        #expect(
            RouteValidator.validate([RouteSamples.route(1, bundle: " ")], devices: devices, processes: [])
                == [.emptyBundleID(route: id(1))])
        #expect(
            RouteValidator.validate([RouteSamples.route(1, uid: "x")], devices: devices, processes: [])
                == [.unknownDevice(route: id(1), uid: "x")])
        #expect(
            RouteValidator.validate([RouteSamples.route(1, pair: 7)], devices: small, processes: [])
                == [.pairOutOfRange(route: id(1), first: 7, deviceChannels: 7)])
        #expect(
            RouteValidator.validate(
                [RouteSamples.route(1), RouteSamples.route(2)], devices: devices, processes: [])
                == [clash(2, 3, with: 1, 3)])
        #expect(
            RouteValidator.validate(
                [RouteSamples.route(1), RouteSamples.route(1, pair: 5)], devices: devices, processes: [])
                == [.duplicateRouteID(route: id(1))])
    }

    @Test func overlappingPairsOfOneDeviceClash() {
        // 3,4 against 4,5 and 4,5 against 3,4 share channel 4.
        #expect(
            RouteValidator.validate(
                [RouteSamples.route(1, pair: 3), RouteSamples.route(2, pair: 4)], devices: devices, processes: [])
                == [clash(2, 4, with: 1, 3)])
        #expect(
            RouteValidator.validate(
                [RouteSamples.route(1, pair: 4), RouteSamples.route(2, pair: 3)], devices: devices, processes: [])
                == [clash(2, 3, with: 1, 4)])
    }

    @Test func adjacentPairsWithoutASharedChannelDoNotClash() {
        let routes = [RouteSamples.route(1, pair: 3), RouteSamples.route(2, pair: 5)]
        #expect(RouteValidator.validate(routes, devices: devices, processes: []).isEmpty)
    }

    @Test func aDisabledRouteDoesNotClash() {
        let routes = [RouteSamples.route(1), RouteSamples.route(2, enabled: false)]
        #expect(RouteValidator.validate(routes, devices: devices, processes: []).isEmpty)
        let overlapping = [RouteSamples.route(1, pair: 3), RouteSamples.route(2, pair: 4, enabled: false)]
        #expect(RouteValidator.validate(overlapping, devices: devices, processes: []).isEmpty)
    }

    @Test func aDisabledRouteSkipsTheDeviceChecks() {
        let route = RouteSamples.route(1, uid: "unplugged-uid", pair: 99, enabled: false)
        #expect(RouteValidator.validate([route], devices: devices, processes: []).isEmpty)
        let outOfRange = RouteSamples.route(2, pair: 99, enabled: false)
        #expect(RouteValidator.validate([outOfRange], devices: devices, processes: []).isEmpty)
    }

    @Test func aDisabledRouteStillNeedsABundleID() {
        let route = RouteSamples.route(1, bundle: "", uid: "unplugged-uid", pair: 99, enabled: false)
        #expect(
            RouteValidator.validate([route], devices: devices, processes: [])
                == [.emptyBundleID(route: RouteSamples.id(1))])
    }

    @Test func aDuplicateRouteIDCountsForDisabledRoutesToo() {
        let routes = [RouteSamples.route(1, enabled: false), RouteSamples.route(1, pair: 5, enabled: false)]
        #expect(
            RouteValidator.validate(routes, devices: devices, processes: [])
                == [.duplicateRouteID(route: RouteSamples.id(1))])
    }

    @Test func theSamePairOnAnotherDeviceDoesNotClash() {
        let two = devices + [OutputDevice(objectID: 2, uid: "device-uid-b", name: "Device B", channelCount: 8)]
        let routes = [RouteSamples.route(1), RouteSamples.route(2, uid: "device-uid-b")]
        #expect(RouteValidator.validate(routes, devices: two, processes: []).isEmpty)
    }
}
