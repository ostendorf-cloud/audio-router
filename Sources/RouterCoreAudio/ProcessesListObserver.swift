// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation
import RouterCore

/// Listens on `kAudioHardwarePropertyProcessObjectList` of the system object. Not exercised by
/// unit tests because it needs Core Audio. The owner checks it on a real Mac, see AGENTS.md.
public struct CoreAudioProcessListObserver: ProcessListObserving {
    public init() {}

    public func observeProcessList(_ handler: @escaping @Sendable () -> Void) throws
        -> any Cancellable
    {
        let queue = DispatchQueue(label: "audio-router.process-list")
        let listener = ProcessListListener(queue: queue, handler: handler)
        try listener.install()
        return listener
    }
}

/// Registers a block on the process object list and removes the same block on cancel.
private final class ProcessListListener: Cancellable, @unchecked Sendable {
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var installed = false

    init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.block = { _, _ in handler() }
    }

    func install() throws {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        try CoreAudioProperty.check(
            AudioObjectAddPropertyListenerBlock(CoreAudioProperty.system, &address, queue, block),
            "add process list listener"
        )
        lock.withLock { installed = true }
    }

    func cancel() {
        let wasInstalled = lock.withLock {
            defer { installed = false }
            return installed
        }
        guard wasInstalled else { return }
        var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        // The status is ignored on purpose. A cancel cannot fail its caller, core has no logger,
        // and a failed removal leaves a block that only calls a weakly held monitor.
        _ = AudioObjectRemovePropertyListenerBlock(CoreAudioProperty.system, &address, queue, block)
    }
}

extension ProcessMonitor {
    /// The monitor wired to Core Audio.
    public static func coreAudio() -> ProcessMonitor {
        ProcessMonitor(processes: CoreAudioProcessProvider(), observer: CoreAudioProcessListObserver())
    }
}
