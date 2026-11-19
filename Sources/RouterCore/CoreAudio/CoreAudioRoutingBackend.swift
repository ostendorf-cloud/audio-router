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
    /// One flag per input channel over all input buffers, set to 1 by the IO proc once the
    /// channel carried a sample that is not zero. Read by the control thread.
    var activity: UnsafeMutablePointer<UInt32>
    var activityCount: Int
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
    ChannelMapper.markActive(
        input: input, flags: context.pointee.activity, flagCount: context.pointee.activityCount)
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
    /// Input stream IDs of an aggregate before and after the tap joined it. Guarded by `lock`.
    private var streamLists: [ObjectID: (before: [UInt32], after: [UInt32])] = [:]
    /// What happened in the stream id diff, per aggregate. Guarded by `lock`.
    private var diffLogs: [ObjectID: StreamDiffLog] = [:]

    public init() {}

    public func createTap(processes: [ObjectID], name: String, mode: TapMode, deviceUID: String) throws -> TapInfo {
        let description: CATapDescription
        switch mode {
        case .stereoMixdown:
            // A stereo mixdown of the processes. Mono sources play on both channels. Measured on
            // a 32 channel device: 24.1 dB too quiet, see docs/prototype-findings.md section 9.
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        case .deviceStream:
            // The tap has the format of output stream 0 of the target device (CATapDescription.h,
            // "the format of the tap will match the format of this stream"). No mixdown.
            description = CATapDescription(processes: processes, deviceUID: deviceUID, stream: 0)
        }
        try mode.validateDescription(isExclusive: description.isExclusive)
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
                sampleRate: format.mSampleRate,
                mode: mode,
                isMixdown: description.isMixdown,
                isExclusive: description.isExclusive
            )
        } catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    private func composition(deviceUID: String, tap: TapInfo?) -> [String: Any] {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "audio-router",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // The target device is the time source. The tap follows it with drift compensation.
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
        ]
        if let tap {
            description[kAudioAggregateDeviceTapListKey] = [
                [
                    kAudioSubTapUIDKey: tap.uid,
                    kAudioSubTapDriftCompensationKey: 1,
                ]
            ]
        }
        return description
    }

    /// Creates the aggregate with the sub device only, reads its input streams, adds the tap
    /// through `kAudioAggregateDevicePropertyTapList` (the owner's run showed it is settable),
    /// switches drift compensation on for the sub tap and reads the streams again. The two lists
    /// go to `startIO`. The header does not describe this order of operations, so any failure
    /// destroys the aggregate and throws, and `createAggregate` falls back to the tap in the
    /// composition from the start.
    ///
    /// Every step is written to `log`, so a failing step is visible in the start lines and before
    /// a refusal. The header (AudioHardware.h, `kAudioAggregateDevicePropertyTapList`: "A CFArray
    /// of CFStrings that contain the UUIDs of all the tap objects") does not say whether the
    /// stream list updates at once, so the streams are polled for up to one second.
    private func createAggregateByStreamDiff(
        deviceUID: String, tap: TapInfo, log: inout StreamDiffLog
    ) throws -> ObjectID {
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let bare = composition(deviceUID: deviceUID, tap: nil) as CFDictionary
        try CoreAudioProperty.check(
            AudioHardwareCreateAggregateDevice(bare, &aggregateID),
            "AudioHardwareCreateAggregateDevice (create aggregate with the sub device only)"
        )
        do {
            func streams() throws -> [AudioObjectID] {
                try CoreAudioProperty.array(
                    aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, initial: 0)
            }
            let before = try streams()
            log.step("aggregate \(aggregateID) created with the sub device only, input streams A \(before)")
            var address = CoreAudioProperty.address(kAudioAggregateDevicePropertyTapList)
            // The property data is one CFArrayRef.
            let list = [tap.uid] as CFArray
            var listRef = Unmanaged.passUnretained(list)
            let setStatus = withExtendedLifetime(list) {
                withUnsafeMutablePointer(to: &listRef) {
                    AudioObjectSetPropertyData(
                        aggregateID, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFArray>>.size), $0)
                }
            }
            log.step("set kAudioAggregateDevicePropertyTapList ('tap#') to [\(tap.uid)]: OSStatus \(setStatus)")
            try CoreAudioProperty.check(setStatus, "set kAudioAggregateDevicePropertyTapList ('tap#')")
            let subTaps: [AudioObjectID] = try CoreAudioProperty.array(
                aggregateID, kAudioAggregateDevicePropertySubTapList, initial: 0)
            log.step("sub taps (kAudioAggregateDevicePropertySubTapList 'atap'): \(subTaps)")
            guard !subTaps.isEmpty else {
                throw RouterError.unsupportedFormat(
                    "the aggregate has no sub tap (kAudioAggregateDevicePropertySubTapList) after the tap list was set")
            }
            // Read only: what kind of object are the ids, for the next run to explain a bad object.
            func classText(_ id: AudioObjectID) -> String {
                guard
                    let value: UInt32 = try? CoreAudioProperty.value(
                        id, kAudioObjectPropertyClass, initial: UInt32(0))
                else { return "\(id) class not available" }
                return "\(id) class '\(fourCC(Int32(bitPattern: value)))'"
            }
            log.step(
                "object classes (kAudioObjectPropertyClass): aggregate \(classText(aggregateID)), "
                    + "tap \(classText(tap.objectID)), sub taps " + subTaps.map(classText).joined(separator: ", "))
            if StreamDiffPlan.setsDrift(mode: tap.mode) {
                for subTap in subTaps {
                    var drift = address
                    drift.mSelector = kAudioSubTapPropertyDriftCompensation
                    var on: UInt32 = 1
                    let status = AudioObjectSetPropertyData(
                        subTap, &drift, 0, nil, UInt32(MemoryLayout<UInt32>.size), &on)
                    log.step(
                        "set kAudioSubTapPropertyDriftCompensation ('drft') on sub tap \(subTap): OSStatus \(status)")
                    if status != noErr {
                        log.driftNotSet(
                            reason: "\(RouterError.coreAudio(operation: "set 'drft'", status: status))")
                    }
                }
            } else {
                log.step(StreamDiffPlan.driftSkipped)
            }
            // The stream list may refresh asynchronously. Poll up to 1 s in steps of 50 ms.
            var after = try streams()
            var waited = 0
            while after == before && waited < 1000 {
                usleep(50_000)
                waited += 50
                after = try streams()
            }
            log.step("input streams B after \(waited) ms: \(after)")
            lock.withLock { streamLists[aggregateID] = (before, after) }
            return aggregateID
        } catch {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            throw error
        }
    }

    public func createAggregate(deviceUID: String, tap: TapInfo) throws -> ObjectID {
        var log = StreamDiffLog()
        var diffID: ObjectID?
        if StreamDiffPlan.usesDiff(mode: tap.mode) {
            do {
                diffID = try createAggregateByStreamDiff(deviceUID: deviceUID, tap: tap, log: &log)
            } catch {
                log.fail("\(error)")
            }
        } else {
            log.fail("stereo-mixdown keeps the tap in the composition, with the drift compensation key")
        }
        if let diffID {
            lock.withLock { diffLogs[diffID] = log }
            return diffID
        }
        log.step("created the aggregate again with the tap in its composition, no diff possible")
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let full = composition(deviceUID: deviceUID, tap: tap) as CFDictionary
        try CoreAudioProperty.check(
            AudioHardwareCreateAggregateDevice(full, &aggregateID),
            "AudioHardwareCreateAggregateDevice (create aggregate)"
        )
        lock.withLock { diffLogs[aggregateID] = log }
        return aggregateID
    }

    public func startIO(
        aggregate: ObjectID, tap: TapInfo, device: OutputDevice, channels: ChannelPair,
        sourceChannels: ChannelPair, tapBuffer: Int?, meter: Bool
    ) throws -> IOHandle {
        // Every stream the IO proc touches must be 32 bit float.
        try CoreAudioProperty.requireFloat32Streams(aggregate, scope: kAudioObjectPropertyScopeInput)
        try CoreAudioProperty.requireFloat32Streams(aggregate, scope: kAudioObjectPropertyScopeOutput)

        // The input side holds the target device's own inputs and the tap. Find the tap by its
        // buffer shape, by the measured order or by the override, and refuse when that is
        // ambiguous, see ChannelMapper.chooseTapBuffers. The device's own input layout is read
        // from the device, so the order rule only applies when the list is exactly those buffers
        // plus the tap.
        let input = ChannelLayout(
            channelsPerBuffer: try CoreAudioProperty.channelsPerBuffer(
                aggregate, scope: kAudioObjectPropertyScopeInput))
        let deviceInputs = try? CoreAudioProperty.channelsPerBuffer(
            device.objectID, scope: kAudioObjectPropertyScopeInput)
        // The stream id diff, when createAggregate could take it. A failure only means the old
        // rules decide, and the reason is printed.
        var diffBuffer: Int?
        var diffLog = lock.withLock { diffLogs[aggregate] } ?? StreamDiffLog()
        if let lists = lock.withLock({ streamLists[aggregate] }) {
            do {
                let formats = try CoreAudioProperty.streamFormats(aggregate, scope: kAudioObjectPropertyScopeInput)
                let index = try ChannelMapper.tapBufferByStreamDiff(
                    before: lists.before, after: lists.after, streamChannels: formats.map(\.channels),
                    inputBuffers: input.channelsPerBuffer, tapChannels: tap.channelCount,
                    interleaved: tap.isInterleaved)
                diffBuffer = index
                diffLog.used(index: index)
            } catch {
                diffLog.fail("\(error)")
            }
        }
        let probeLines = tap.mode == .deviceStream ? Self.probes(aggregate: aggregate, tap: tap) : []
        let tapBuffers: Range<Int>
        let choice: TapBufferChoice
        do {
            (tapBuffers, choice) = try ChannelMapper.chooseTapBuffers(
                in: input, tapChannels: tap.channelCount, interleaved: tap.isInterleaved,
                deviceName: device.name, deviceInputBuffers: deviceInputs, override: tapBuffer,
                streamDiffBuffer: diffBuffer)
        } catch {
            // Print what a successful start prints, then refuse with the diff outcome in the text.
            let lines = Formatting.refusalDiagnostics(
                tap: StreamFormatInfo(
                    sampleRate: tap.sampleRate, channels: tap.channelCount, interleaved: tap.isInterleaved),
                inputBuffers: input.channelsPerBuffer,
                inputStreams: (try? CoreAudioProperty.streamFormats(
                    aggregate, scope: kAudioObjectPropertyScopeInput)) ?? [],
                tapIsMixdown: tap.isMixdown, tapIsExclusive: tap.isExclusive,
                diff: diffLog, probes: probeLines)
            Diagnostics.write(lines.joined(separator: "\n") + "\n", to: STDOUT_FILENO)
            throw RouterError.refusedWithDiff(reason: "\(error)", diff: diffLog.outcome)
        }
        let source = ChannelLayout(channelsPerBuffer: Array(input.channelsPerBuffer[tapBuffers]))
        let destination = ChannelLayout(
            channelsPerBuffer: try CoreAudioProperty.channelsPerBuffer(
                aggregate, scope: kAudioObjectPropertyScopeOutput))
        let routes = try ChannelMapper.routes(
            source: source, destination: destination, pair: channels, sourceBufferOffset: tapBuffers.lowerBound,
            sourcePair: sourceChannels)

        let routeMemory = UnsafeMutablePointer<ChannelRoute>.allocate(capacity: routes.count)
        routeMemory.initialize(from: routes, count: routes.count)
        let seenMemory = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        seenMemory.initialize(to: 0)
        let meterBlock = meter ? MeterBlock.allocate(channels: routes.count) : nil
        let activityCount = input.totalChannels
        let activityMemory = UnsafeMutablePointer<UInt32>.allocate(capacity: max(activityCount, 1))
        activityMemory.initialize(repeating: 0, count: max(activityCount, 1))
        let context = UnsafeMutablePointer<IOContext>.allocate(capacity: 1)
        context.initialize(
            to: IOContext(
                routes: routeMemory, routeCount: routes.count, signalSeen: seenMemory, meter: meterBlock,
                activity: activityMemory, activityCount: activityCount))
        func free() {
            context.deallocate()
            routeMemory.deallocate()
            seenMemory.deallocate()
            activityMemory.deallocate()
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
            deviceSampleRate: CoreAudioProperty.nominalSampleRate(device.objectID),
            tapBufferChoice: choice,
            sourceChannels: sourceChannels,
            tapMode: tap.mode,
            tapIsMixdown: tap.isMixdown,
            tapIsExclusive: tap.isExclusive,
            probes: diffLog.lines + probeLines,
            preferredStereo: Self.preferredStereo(device.objectID)
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

    /// Read only probes for the owner's first device stream run. They print, never decide and
    /// never throw: any error shows as "not available". They look for a property that names the
    /// tap's stream, see docs/prototype-findings.md section 9.
    private static func probes(aggregate: ObjectID, tap: TapInfo) -> [String] {
        func ids(_ list: [AudioObjectID]) -> String {
            list.isEmpty ? "none" : list.map(String.init).joined(separator: ",")
        }
        var lines = ["probe: aggregate object \(aggregate), tap object \(tap.objectID)"]
        let streams: [AudioObjectID]? = try? CoreAudioProperty.array(
            aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, initial: 0)
        if let streams {
            lines.append("probe: aggregate input streams \(ids(streams))")
            for stream in streams {
                let owner: AudioObjectID? = try? CoreAudioProperty.value(
                    stream, kAudioObjectPropertyOwner, initial: AudioObjectID(0))
                lines.append("probe: stream \(stream) owner \(owner.map(String.init) ?? "not available")")
            }
        } else {
            lines.append("probe: aggregate input streams not available")
        }
        let owned: [AudioObjectID]? = try? CoreAudioProperty.array(
            tap.objectID, kAudioObjectPropertyOwnedObjects, initial: 0)
        lines.append("probe: tap owned objects \(owned.map(ids) ?? "not available")")
        var address = CoreAudioProperty.address(kAudioAggregateDevicePropertyTapList)
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(aggregate, &address, &settable)
        lines.append(
            "probe: aggregate tap list settable "
                + (status == noErr ? (settable.boolValue ? "yes" : "no") : "not available"))
        return lines
    }

    /// The pair the device names for stereo output, for information. Not used as a default.
    private static func preferredStereo(_ device: AudioObjectID) -> String {
        guard
            let pair: [UInt32] = try? CoreAudioProperty.array(
                device, kAudioDevicePropertyPreferredChannelsForStereo,
                scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)),
            pair.count == 2
        else { return "not available" }
        return "\(pair[0]),\(pair[1])"
    }

    public func routeInfo(handle: IOHandle) -> RouteInfo? {
        lock.withLock { started[handle.rawValue]?.info }
    }

    public func readMeter(handle: IOHandle) -> MeterReading? {
        // Under the lock, so stopIO cannot free the memory while it is read.
        lock.withLock { started[handle.rawValue]?.context.pointee.meter?.collect() }
    }

    public func activeInputChannels(handle: IOHandle) -> [Int]? {
        // Under the lock, so stopIO cannot free the flags while they are read.
        lock.withLock {
            guard let state = started[handle.rawValue] else { return nil }
            let context = state.context.pointee
            return (0..<context.activityCount).filter { context.activity[$0] != 0 }
        }
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
            state.context.pointee.activity.deallocate()
            state.context.pointee.meter?.deallocate()
            state.context.deallocate()
        }
        try CoreAudioProperty.check(stopStatus, "AudioDeviceStop (stop IO)")
        try CoreAudioProperty.check(destroyStatus, "AudioDeviceDestroyIOProcID (destroy IO proc)")
    }

    public func destroyAggregate(_ aggregate: ObjectID) throws {
        lock.withLock {
            _ = streamLists.removeValue(forKey: aggregate)
            _ = diffLogs.removeValue(forKey: aggregate)
        }
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
