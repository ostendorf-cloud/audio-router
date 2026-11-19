// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation

/// Thin typed wrappers around AudioObjectGetPropertyData. Not exercised by unit tests because
/// they need Core Audio objects. The owner checks them on a real Mac, see AGENTS.md.
enum CoreAudioProperty {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw RouterError.coreAudio(operation: operation, status: status)
        }
    }

    /// Reads a fixed size value such as UInt32, Int32 or AudioStreamBasicDescription.
    static func value<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> T {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        try check(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result),
            "read property \(fourCC(Int32(bitPattern: selector)))"
        )
        return result
    }

    /// Reads an array of fixed size elements such as AudioObjectID.
    static func array<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        let name = "read property \(fourCC(Int32(bitPattern: selector)))"
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), name)
        var result = [T](repeating: initial, count: Int(size) / MemoryLayout<T>.size)
        size = UInt32(result.count * MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result), name)
        return result
    }

    /// Reads a CFString property. The property follows the create rule, so the string is owned.
    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        try check(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result),
            "read property \(fourCC(Int32(bitPattern: selector)))"
        )
        return result?.takeRetainedValue() as String? ?? ""
    }

    /// The channel count of every buffer of a device in one scope, in buffer order.
    static func channelsPerBuffer(
        _ device: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        let name = "read stream configuration"
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), name)
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory), name)
        let list = UnsafeMutableAudioBufferListPointer(
            memory.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
