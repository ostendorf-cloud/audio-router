// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation

/// What the IO proc reads. Plain data behind one raw pointer, so the audio thread touches no
/// reference counted object. Allocated before the device starts, freed after it stopped.
struct IOContext {
    var routes: UnsafeMutablePointer<ChannelRoute>
    var routeCount: Int
    /// Set to 1 by the IO proc once a non zero sample went through. Read by the control thread.
    var signalSeen: UnsafeMutablePointer<UInt32>
    /// Nil unless `route --meter` runs.
    var meter: MeterBlock?
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
        output: output,
        signalSeen: context.pointee.signalSeen
    )
    if let meter = context.pointee.meter {
        ChannelMapper.measure(
            routes: context.pointee.routes,
            routeCount: context.pointee.routeCount,
            input: input,
            output: output,
            meter: meter
        )
    }
    return noErr
}

/// The Core Audio implementation of the routing side effects. Not unit tested, because it needs
/// the system audio capture permission and real devices. The calls follow the SDK headers
/// AudioHardwareTapping.h, CATapDescription.h and AudioHardware.h, checked on macOS 27.
public final class CoreAudioRoutingBackend: AudioRoutingBackend, @unchecked Sendable {
    private struct IOState {
        let procID: AudioDeviceIOProcID
        let context: UnsafeMutablePointer<IOContext>
        let info: RouteInfo
    }

    private let lock = NSLock()  // guards the two fields below, control path only
    private var started: [Int: IOState] = [:]
    private var nextHandle = 1

    public init() {}

    public func createTap(processes: [ObjectID], name: String) throws -> TapInfo {
        // A stereo mixdown of the processes. Mono sources play on both channels.
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = name
        // The app is silent on its normal output only while a client reads the tap
        // (CATapDescription.h, CATapMutedWhenTapped). If the IO proc stops but the tap lives, the
        // app plays normally again instead of staying silent.
        description.muteBehavior = .mutedWhenTapped
        // Only this process sees the tap, and it dies with the process.
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioProperty.check(
            AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap (create tap)")

        do {
            let format: AudioStreamBasicDescription = try CoreAudioProperty.value(
                tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard CoreAudioProperty.isFloat32(format) else {
                throw RouterError.unsupportedFormat(
                    "tap format is \(fourCC(Int32(bitPattern: format.mFormatID))), "
                        + "\(format.mBitsPerChannel) bit, not 32 bit float")
            }
            // Read the uid back from the tap object. The description's uuid is the fallback.
            let uid =
                (try? CoreAudioProperty.string(tapID, kAudioTapPropertyUID)) ?? description.uuid.uuidString
            return TapInfo(
                objectID: tapID,
                uid: uid,
                channelCount: Int(format.mChannelsPerFrame),
                isInterleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                sampleRate: format.mSampleRate
            )
        } catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
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

    public func startIO(
        aggregate: ObjectID, tap: TapInfo, device: OutputDevice, channels: ChannelPair, meter: Bool
    ) throws -> IOHandle {
        // Every stream the IO proc touches must be 32 bit float.
        try CoreAudioProperty.requireFloat32Streams(aggregate, scope: kAudioObjectPropertyScopeInput)
        try CoreAudioProperty.requireFloat32Streams(aggregate, scope: kAudioObjectPropertyScopeOutput)

        // The input side holds the target device's own inputs and the tap. Find the tap by its
        // buffer shape and refuse when that is ambiguous, see ChannelMapper.tapBuffers.
        let input = ChannelLayout(
            channelsPerBuffer: try CoreAudioProperty.channelsPerBuffer(
                aggregate, scope: kAudioObjectPropertyScopeInput))
        let tapBuffers = try ChannelMapper.tapBuffers(
            in: input, tapChannels: tap.channelCount, interleaved: tap.isInterleaved, deviceName: device.name)
        let source = ChannelLayout(channelsPerBuffer: Array(input.channelsPerBuffer[tapBuffers]))
        let destination = ChannelLayout(
            channelsPerBuffer: try CoreAudioProperty.channelsPerBuffer(
                aggregate, scope: kAudioObjectPropertyScopeOutput))
        let routes = try ChannelMapper.routes(
            source: source, destination: destination, pair: channels, sourceBufferOffset: tapBuffers.lowerBound)

        let routeMemory = UnsafeMutablePointer<ChannelRoute>.allocate(capacity: routes.count)
        routeMemory.initialize(from: routes, count: routes.count)
        let seenMemory = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        seenMemory.initialize(to: 0)
        let meterBlock = meter ? MeterBlock.allocate(channels: routes.count) : nil
        let context = UnsafeMutablePointer<IOContext>.allocate(capacity: 1)
        context.initialize(
            to: IOContext(
                routes: routeMemory, routeCount: routes.count, signalSeen: seenMemory, meter: meterBlock))
        func free() {
            context.deallocate()
            routeMemory.deallocate()
            seenMemory.deallocate()
            meterBlock?.deallocate()
        }

        // Formats for the report. A failed read leaves a gap, it does not stop the route.
        let info = RouteInfo(
            tap: StreamFormatInfo(
                sampleRate: tap.sampleRate, channels: tap.channelCount, interleaved: tap.isInterleaved),
            inputBuffers: input.channelsPerBuffer,
            tapBuffers: tapBuffers,
            outputBuffers: destination.channelsPerBuffer,
            inputStreams: (try? CoreAudioProperty.streamFormats(aggregate, scope: kAudioObjectPropertyScopeInput))
                ?? [],
            outputStreams: (try? CoreAudioProperty.streamFormats(aggregate, scope: kAudioObjectPropertyScopeOutput))
                ?? [],
            aggregateSampleRate: CoreAudioProperty.nominalSampleRate(aggregate),
            deviceSampleRate: CoreAudioProperty.nominalSampleRate(device.objectID)
        )

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
            started[handle.rawValue] = IOState(procID: procID, context: context, info: info)
            return handle
        }
    }

    public func routeInfo(handle: IOHandle) -> RouteInfo? {
        lock.withLock { started[handle.rawValue]?.info }
    }

    public func readMeter(handle: IOHandle) -> MeterReading? {
        // Under the lock, so stopIO cannot free the memory while it is read.
        lock.withLock { started[handle.rawValue]?.context.pointee.meter?.collect() }
    }

    public func signalSeen(handle: IOHandle) -> Bool {
        // Under the lock, so stopIO cannot free the flag while it is read.
        lock.withLock {
            guard let state = started[handle.rawValue] else { return false }
            return state.context.pointee.signalSeen.pointee != 0
        }
    }

    public func stopIO(aggregate: ObjectID, handle: IOHandle) throws {
        guard let state = lock.withLock({ started.removeValue(forKey: handle.rawValue) }) else {
            return
        }
        let stopStatus = AudioDeviceStop(aggregate, state.procID)
        let destroyStatus = AudioDeviceDestroyIOProcID(aggregate, state.procID)
        // Free the memory only when the proc surely no longer runs. A leak of a few small
        // allocations beats a use after free on the audio thread.
        if stopStatus == noErr && destroyStatus == noErr {
            state.context.pointee.routes.deallocate()
            state.context.pointee.signalSeen.deallocate()
            state.context.pointee.meter?.deallocate()
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
