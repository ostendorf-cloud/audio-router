// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation

/// What the IO proc reads. Plain data behind one raw pointer, so the audio thread touches no
/// reference counted object. Allocated before the device starts, freed after it stopped.
struct IOContext {
    var routes: UnsafeMutablePointer<ChannelRoute>
    var routeCount: Int
}

/// The IO proc. Runs on the audio thread. It only calls `ChannelMapper.render`, whose comment
/// holds the real time contract: no allocation, no lock, no logging, no reference counting.
private func routerIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ input: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ output: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let context = clientData.assumingMemoryBound(to: IOContext.self)
    ChannelMapper.render(
        routes: context.pointee.routes,
        routeCount: context.pointee.routeCount,
        input: input,
        output: output
    )
    return noErr
}

/// The Core Audio implementation of the routing side effects. Not unit tested, because it needs
/// the system audio capture permission and real devices. The calls follow the SDK headers
/// AudioHardwareTapping.h, CATapDescription.h and AudioHardware.h, checked on macOS 27.
public final class CoreAudioRoutingBackend: AudioRoutingBackend, @unchecked Sendable {
    private struct IOState {
        let procID: AudioDeviceIOProcID
        let context: UnsafeMutablePointer<IOContext>
    }

    private let lock = NSLock()  // guards the two fields below, control path only
    private var started: [Int: IOState] = [:]
    private var nextHandle = 1

    public init() {}

    public func createTap(processes: [ObjectID], name: String) throws -> TapInfo {
        // A stereo mixdown of the processes. Mono sources play on both channels.
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = name
        // The app is silent on its normal output while the tap exists.
        description.muteBehavior = .muted
        // Only this process sees the tap, and it dies with the process.
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioProperty.check(
            AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap (create tap)")

        do {
            let format: AudioStreamBasicDescription = try CoreAudioProperty.value(
                tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            guard format.mFormatID == kAudioFormatLinearPCM, isFloat, format.mBitsPerChannel == 32
            else {
                throw RouterError.unsupportedFormat(
                    "tap format is \(fourCC(Int32(bitPattern: format.mFormatID))), "
                        + "\(format.mBitsPerChannel) bit, not 32 bit float")
            }
        } catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
        return TapInfo(objectID: tapID, uid: description.uuid.uuidString)
    }

    public func createAggregate(deviceUID: String, tap: TapInfo) throws -> ObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "audio-router",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // The target device is the time source. The tap follows it with drift compensation.
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uid,
                    kAudioSubTapDriftCompensationKey: 1,
                ]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioProperty.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "AudioHardwareCreateAggregateDevice (create aggregate)"
        )
        return aggregateID
    }

    public func startIO(aggregate: ObjectID, channels: ChannelPair) throws -> IOHandle {
        // The layouts come from the aggregate itself: its input is the tap, its output is the
        // target device's streams in order.
        let source = ChannelLayout(
            channelsPerBuffer: try CoreAudioProperty.channelsPerBuffer(
                aggregate, scope: kAudioObjectPropertyScopeInput))
        let destination = ChannelLayout(
            channelsPerBuffer: try CoreAudioProperty.channelsPerBuffer(
                aggregate, scope: kAudioObjectPropertyScopeOutput))
        let routes = try ChannelMapper.routes(source: source, destination: destination, pair: channels)

        let routeMemory = UnsafeMutablePointer<ChannelRoute>.allocate(capacity: routes.count)
        routeMemory.initialize(from: routes, count: routes.count)
        let context = UnsafeMutablePointer<IOContext>.allocate(capacity: 1)
        context.initialize(to: IOContext(routes: routeMemory, routeCount: routes.count))
        func free() {
            context.deallocate()
            routeMemory.deallocate()
        }

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(aggregate, routerIOProc, context, &procID)
        guard createStatus == noErr, let procID else {
            free()
            throw RouterError.coreAudio(
                operation: "AudioDeviceCreateIOProcID (create IO proc)", status: createStatus)
        }
        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregate, procID)
            free()
            throw RouterError.coreAudio(operation: "AudioDeviceStart (start IO)", status: startStatus)
        }
        return lock.withLock {
            let handle = IOHandle(rawValue: nextHandle)
            nextHandle += 1
            started[handle.rawValue] = IOState(procID: procID, context: context)
            return handle
        }
    }

    public func stopIO(aggregate: ObjectID, handle: IOHandle) throws {
        guard let state = lock.withLock({ started.removeValue(forKey: handle.rawValue) }) else {
            return
        }
        let stopStatus = AudioDeviceStop(aggregate, state.procID)
        let destroyStatus = AudioDeviceDestroyIOProcID(aggregate, state.procID)
        // Free the memory only when the proc surely no longer runs. A leak of two small
        // allocations beats a use after free on the audio thread.
        if stopStatus == noErr && destroyStatus == noErr {
            state.context.pointee.routes.deallocate()
            state.context.deallocate()
        }
        try CoreAudioProperty.check(stopStatus, "AudioDeviceStop (stop IO)")
        try CoreAudioProperty.check(destroyStatus, "AudioDeviceDestroyIOProcID (destroy IO proc)")
    }

    public func destroyAggregate(_ aggregate: ObjectID) throws {
        try CoreAudioProperty.check(
            AudioHardwareDestroyAggregateDevice(aggregate),
            "AudioHardwareDestroyAggregateDevice (destroy aggregate)"
        )
    }

    public func destroyTap(_ tap: ObjectID) throws {
        try CoreAudioProperty.check(
            AudioHardwareDestroyProcessTap(tap), "AudioHardwareDestroyProcessTap (destroy tap)")
    }
}
