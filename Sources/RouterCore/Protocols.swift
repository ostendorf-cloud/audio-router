// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// Lists output devices. The real implementation reads Core Audio, tests use a fake.
public protocol AudioDeviceProviding: Sendable {
    func outputDevices() throws -> [OutputDevice]

    /// Calls `handler` on an arbitrary queue when the device list changes. The handler must
    /// re-read `outputDevices()`. Keep the returned value alive as long as the callback is wanted.
    func observeDeviceList(_ handler: @escaping @Sendable () -> Void) throws -> any Cancellable
}

/// Lists the processes that are connected to Core Audio.
public protocol ProcessProviding: Sendable {
    func processes() throws -> [AudioProcess]
}

/// Something a caller stops when it no longer wants callbacks.
public protocol Cancellable: Sendable {
    func cancel()
}

/// Opaque handle for a started IO proc. The backend maps it to its own state.
public struct IOHandle: Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// A created process tap.
public struct TapInfo: Equatable, Sendable {
    public let objectID: ObjectID
    /// The tap's UUID string. The aggregate device lists the tap under this uid.
    public let uid: String

    public init(objectID: ObjectID, uid: String) {
        self.objectID = objectID
        self.uid = uid
    }
}

/// The side effects of one route: tap, aggregate device and IO proc. `RouteSession` drives it and
/// owns the order of creation and teardown.
public protocol AudioRoutingBackend: Sendable {
    /// Creates a private, muted stereo tap over the given process objects.
    func createTap(processes: [ObjectID], name: String) throws -> TapInfo

    /// Creates a private aggregate device with `deviceUID` as main sub device and the tap as
    /// sub tap, drift compensation on.
    func createAggregate(deviceUID: String, tap: TapInfo) throws -> ObjectID

    /// Registers the IO proc that copies the tap onto `channels` and starts it.
    func startIO(aggregate: ObjectID, channels: ChannelPair) throws -> IOHandle

    /// Stops the IO proc and destroys it. Returns only after the proc is no longer called.
    func stopIO(aggregate: ObjectID, handle: IOHandle) throws

    func destroyAggregate(_ aggregate: ObjectID) throws

    func destroyTap(_ tap: ObjectID) throws
}
