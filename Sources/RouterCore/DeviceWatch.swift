// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// Ends a route when its target device disappears.
public enum DeviceWatch {
    /// A failed list read counts as not present.
    public static func isPresent(uid: String, devices: any AudioDeviceProviding) -> Bool {
        (try? devices.outputDevices())?.contains { $0.uid == uid } ?? false
    }

    /// Registers the list observer, then checks once. A device lost while the route started, before
    /// the observer existed, would otherwise never be noticed. `onGone` can run more than once,
    /// the caller must tolerate that.
    public static func start(
        devices: any AudioDeviceProviding,
        uid: String,
        onGone: @escaping @Sendable () -> Void
    ) throws -> any Cancellable {
        let check: @Sendable () -> Void = {
            if !isPresent(uid: uid, devices: devices) { onGone() }
        }
        let observer = try devices.observeDeviceList(check)
        check()
        return observer
    }
}
