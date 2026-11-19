// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Darwin

public enum Diagnostics {
    /// Writes with plain `write(2)` and ignores every error. `FileHandle.write` raises an
    /// Objective-C exception on EIO, which is what a closed terminal (SIGHUP) gives, and that
    /// would crash the process before the teardown finished.
    public static func write(_ text: String, to descriptor: Int32 = STDERR_FILENO) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
