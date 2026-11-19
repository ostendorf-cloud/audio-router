// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The one way out of a running route. The first caller tears the route down, waits until that
/// is finished and exits. Any later caller waits (`park`) until the process is gone, so a second
/// signal or a device removal cannot exit in the middle of the teardown or change the exit code.
///
/// `exit` and `park` are injected so a test can run it. In the tool `exit` ends the process and
/// `park` sleeps forever, so `finish` never returns there.
public final class Finisher: @unchecked Sendable {
    private let session: RouteSession
    private let exit: @Sendable (Int32) -> Void
    private let write: @Sendable (String) -> Void
    private let park: @Sendable () -> Void
    private let lock = NSLock()
    private var finishing = false

    public init(
        session: RouteSession,
        exit: @escaping @Sendable (Int32) -> Void,
        write: @escaping @Sendable (String) -> Void,
        park: @escaping @Sendable () -> Void
    ) {
        self.session = session
        self.exit = exit
        self.write = write
        self.park = park
    }

    public func finish(code: Int32, message: String?) {
        let first = lock.withLock {
            defer { finishing = true }
            return !finishing
        }
        guard first else {
            park()
            return
        }
        let leftovers = session.stop()  // returns after the teardown completed
        if let message { write(message + "\n") }
        for leftover in leftovers {
            write("teardown: \(leftover)\n")
        }
        exit(leftovers.isEmpty ? code : 1)
    }
}
