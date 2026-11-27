// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

// THROWAWAY for issue 86. Never merge to main. Delete it with .github/workflows/spike-tap-steps.yaml.
//
// Makes the Core Audio calls of a route start one by one, with a time stamp before and after each call, and a
// watchdog that ends the process when one call does not return. The calls and their order follow
// Sources/RouterCoreAudio/CoreAudioRoutingBackend.swift (createTap, createAggregateByStreamDiff, startIO) in the
// default tap mode device-stream: process tap, bare aggregate with the sub device, tap list property, IO proc,
// start. Not copied: the float32 stream checks, the channel layout reads and the channel mapping. The IO proc only
// counts its calls.
//
// Usage:
//   tap-steps tap --bundle-id <id> [--device-name <name>] [--hold <s>] [--watchdog <s>]
//   tap-steps control [--device-name <name>] [--hold <s>] [--watchdog <s>]
// tap      the route start sequence on the process object of the app with the bundle id
// control  a plain IO proc on the device itself, no tap, no aggregate
// Exit codes: 0 every step returned without an error, 2 a step failed or found nothing, 3 a step hung, 64 usage.
// Time stamps are local time with milliseconds, the format of `log stream --style compact`.

import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Output

func stamp() -> String {
    var now = timeval()
    gettimeofday(&now, nil)
    var seconds = now.tv_sec
    var parts = tm()
    localtime_r(&seconds, &parts)
    var buffer = [CChar](repeating: 0, count: 32)
    strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &parts)
    return "\(String(cString: buffer)).\(String(format: "%03d", Int(now.tv_usec / 1000)))"
}

func say(_ text: String) {
    print("\(stamp()) \(text)")
}

func describe(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    let code = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
    return "\(status)\(code)"
}

// MARK: Options

var mode = ""
var bundleID = ""
var deviceName = "Null Audio Device"
var hold = 5.0
var limit = 55.0

func parseOptions() -> Bool {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let first = arguments.first, first == "tap" || first == "control" else { return false }
    mode = first
    arguments.removeFirst()
    var index = 0
    while index < arguments.count {
        guard index + 1 < arguments.count else { return false }
        let value = arguments[index + 1]
        switch arguments[index] {
        case "--bundle-id": bundleID = value
        case "--device-name": deviceName = value
        case "--hold": hold = Double(value) ?? hold
        case "--watchdog": limit = Double(value) ?? limit
        default: return false
        }
        index += 2
    }
    return mode == "control" || !bundleID.isEmpty
}

guard parseOptions() else {
    print("usage: tap-steps tap --bundle-id <id> | control  [--device-name <name>] [--hold <s>] [--watchdog <s>]")
    exit(64)
}

// MARK: Watchdog

/// Which step runs and since when. The watchdog thread ends the process when one step runs too long. A start
/// cannot be cancelled, so the end is `_exit`.
final class Watch: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?
    private var began = DispatchTime.now().uptimeNanoseconds

    func begin(_ step: String) {
        lock.lock()
        name = step
        began = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func end() {
        lock.lock()
        name = nil
        lock.unlock()
    }

    func overdue(seconds: Double) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let name else { return nil }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
        return elapsed >= seconds ? name : nil
    }
}

let watch = Watch()

Thread.detachNewThread {
    while true {
        usleep(200_000)
        if let hung = watch.overdue(seconds: limit) {
            say("HANG step=\(hung), no return after \(Int(limit)) s, the watchdog ends the process")
            say("RESULT mode=\(mode) outcome=hang step=\(hung)")
            fflush(stdout)
            _exit(3)
        }
    }
}

/// Runs one call between two time stamps. The body returns the OSStatus of the call.
@discardableResult
func step(_ name: String, _ body: () -> OSStatus) -> OSStatus {
    say("STEP \(name) begin")
    watch.begin(name)
    let began = DispatchTime.now().uptimeNanoseconds
    let status = body()
    watch.end()
    let milliseconds = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    say("STEP \(name) end status=\(describe(status)) after \(milliseconds) ms")
    return status
}

// MARK: Property reads

func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readIDs(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> (status: OSStatus, ids: [AudioObjectID]) {
    var property = address(selector, scope)
    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
    guard sizeStatus == noErr else { return (sizeStatus, []) }
    var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    size = UInt32(result.count * MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result)
    let returned = Int(size) / MemoryLayout<AudioObjectID>.size
    if status == noErr, returned < result.count { result.removeLast(result.count - returned) }
    return (status, status == noErr ? result : [])
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var result: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result) == noErr else { return nil }
    return result?.takeRetainedValue() as String?
}

func readInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
    var property = address(selector)
    var size = UInt32(MemoryLayout<Int32>.size)
    var result: Int32 = 0
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result) == noErr else { return nil }
    return result
}

/// Counts the calls of the IO proc. One writer, read by the main thread after the hold.
let callbacks = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
callbacks.initialize(to: 0)

func spikeIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ input: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ output: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    clientData?.assumingMemoryBound(to: UInt32.self).pointee &+= 1
    return noErr
}

// MARK: Lookups

/// The first device with the name, with its UID. Prints every device it sees.
func findDevice(named wanted: String) -> (id: AudioObjectID, uid: String)? {
    var found: (id: AudioObjectID, uid: String)?
    step("read-devices") {
        let list = readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        for id in list.ids {
            let name = readString(id, kAudioObjectPropertyName) ?? "?"
            let uid = readString(id, kAudioDevicePropertyDeviceUID) ?? "?"
            say("device id=\(id) name=\(name) uid=\(uid)")
            if found == nil, name == wanted { found = (id, uid) }
        }
        return list.status
    }
    return found
}

/// The process objects of the app with the bundle id, never this process. Prints every process it sees.
func findProcesses(bundleID wanted: String) -> [AudioObjectID] {
    var found: [AudioObjectID] = []
    step("read-processes") {
        let list = readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        for id in list.ids {
            let pid = readInt32(id, kAudioProcessPropertyPID) ?? -1
            let bundle = readString(id, kAudioProcessPropertyBundleID) ?? ""
            say("process id=\(id) pid=\(pid) bundle=\(bundle)")
            if bundle == wanted, pid != getpid() { found.append(id) }
        }
        return list.status
    }
    return found
}

// MARK: Control

/// A plain IO proc on the device itself. No tap and no aggregate, so no capture permission is involved.
func runControl() -> Int32 {
    guard let device = findDevice(named: deviceName) else {
        say("RESULT mode=control outcome=not-found what=device \(deviceName)")
        return 2
    }
    var procID: AudioDeviceIOProcID?
    var outcome = "started"
    var failed = false
    func fail(_ name: String, _ status: OSStatus) {
        outcome = "failed step=\(name) status=\(describe(status))"
        failed = true
    }
    let createStatus = step("AudioDeviceCreateIOProcID") {
        AudioDeviceCreateIOProcID(device.id, spikeIOProc, callbacks, &procID)
    }
    if createStatus != noErr || procID == nil {
        fail("AudioDeviceCreateIOProcID", createStatus)
    } else {
        let startStatus = step("AudioDeviceStart") { AudioDeviceStart(device.id, procID) }
        if startStatus != noErr {
            fail("AudioDeviceStart", startStatus)
        } else {
            say("HOLD \(hold) s with IO running")
            Thread.sleep(forTimeInterval: hold)
            say("IO proc calls during the hold: \(callbacks.pointee)")
            let stopStatus = step("AudioDeviceStop") { AudioDeviceStop(device.id, procID) }
            if stopStatus != noErr { fail("AudioDeviceStop", stopStatus) }
        }
        let destroyStatus = step("AudioDeviceDestroyIOProcID") { AudioDeviceDestroyIOProcID(device.id, procID!) }
        if destroyStatus != noErr, !failed { fail("AudioDeviceDestroyIOProcID", destroyStatus) }
    }
    say("RESULT mode=control outcome=\(outcome) callbacks=\(callbacks.pointee)")
    return failed ? 2 : 0
}

// MARK: Tap

/// The route start of the tool, one call at a time. Teardown order as in the tool: IO proc, aggregate, tap.
func runTap() -> Int32 {
    let processes = findProcesses(bundleID: bundleID)
    guard !processes.isEmpty else {
        say("RESULT mode=tap outcome=not-found what=process \(bundleID)")
        return 2
    }
    guard let device = findDevice(named: deviceName) else {
        say("RESULT mode=tap outcome=not-found what=device \(deviceName)")
        return 2
    }
    say("target processes \(processes), destination device id=\(device.id) uid=\(device.uid)")

    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var started = false
    var failedStep: String?

    func fail(_ name: String, _ status: OSStatus) {
        failedStep = "\(name) status=\(describe(status))"
    }

    func teardown() {
        if started {
            step("AudioDeviceStop") { AudioDeviceStop(aggregateID, procID) }
            started = false
        }
        if let created = procID {
            step("AudioDeviceDestroyIOProcID") { AudioDeviceDestroyIOProcID(aggregateID, created) }
            procID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            step("AudioHardwareDestroyAggregateDevice") { AudioHardwareDestroyAggregateDevice(aggregateID) }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            step("AudioHardwareDestroyProcessTap") { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // 1. The process tap, as createTap does in device-stream mode.
    let description = CATapDescription(processes: processes, deviceUID: device.uid, stream: 0)
    description.name = "audio-router \(bundleID)"
    description.muteBehavior = .mutedWhenTapped
    description.isPrivate = true
    let tapStatus = step("AudioHardwareCreateProcessTap") { AudioHardwareCreateProcessTap(description, &tapID) }
    guard tapStatus == noErr else {
        say("RESULT mode=tap outcome=failed step=AudioHardwareCreateProcessTap status=\(describe(tapStatus))")
        return 2
    }
    var tapUID = description.uuid.uuidString
    step("read-tap-properties") {
        var property = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &property, 0, nil, &size, &format)
        if let uid = readString(tapID, kAudioTapPropertyUID) { tapUID = uid }
        say(
            "tap id=\(tapID) uid=\(tapUID) rate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame) "
                + "flags=\(format.mFormatFlags)")
        return status
    }

    // 2. The bare aggregate with the sub device only, as createAggregateByStreamDiff does first.
    let bare: [String: Any] = [
        kAudioAggregateDeviceNameKey: "audio-router",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: device.uid,
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceIsStackedKey: 0,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
    ]
    let aggregateStatus = step("AudioHardwareCreateAggregateDevice") {
        AudioHardwareCreateAggregateDevice(bare as CFDictionary, &aggregateID)
    }
    if aggregateStatus != noErr {
        fail("AudioHardwareCreateAggregateDevice", aggregateStatus)
    }

    // 3. The tap joins the aggregate through the tap list property, then the streams are read.
    func inputStreams() -> [AudioObjectID] {
        readIDs(aggregateID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).ids
    }
    if failedStep == nil {
        var before: [AudioObjectID] = []
        step("read-input-streams-A") {
            let list = readIDs(aggregateID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            before = list.ids
            say("input streams A \(before)")
            return list.status
        }
        var tapList = address(kAudioAggregateDevicePropertyTapList)
        let list = [tapUID] as CFArray
        var listRef = Unmanaged.passUnretained(list)
        let setStatus = step("AudioObjectSetPropertyData-TapList") {
            withExtendedLifetime(list) {
                withUnsafeMutablePointer(to: &listRef) {
                    AudioObjectSetPropertyData(
                        aggregateID, &tapList, 0, nil, UInt32(MemoryLayout<Unmanaged<CFArray>>.size), $0)
                }
            }
        }
        if setStatus != noErr {
            fail("AudioObjectSetPropertyData-TapList", setStatus)
        } else {
            step("read-sub-taps") {
                let subTaps = readIDs(aggregateID, kAudioAggregateDevicePropertySubTapList)
                say("sub taps \(subTaps.ids)")
                return subTaps.status
            }
            // The stream list may refresh asynchronously. Poll up to 1 s in steps of 50 ms, as the tool does.
            step("poll-input-streams-B") {
                var after = inputStreams()
                var waited = 0
                while after == before && waited < 1000 {
                    usleep(50_000)
                    waited += 50
                    after = inputStreams()
                }
                say("input streams B after \(waited) ms: \(after)")
                return noErr
            }
        }
    }

    // 4. The IO proc and the start, the two calls where the tool hangs.
    if failedStep == nil {
        let createStatus = step("AudioDeviceCreateIOProcID") {
            AudioDeviceCreateIOProcID(aggregateID, spikeIOProc, callbacks, &procID)
        }
        if createStatus != noErr || procID == nil {
            fail("AudioDeviceCreateIOProcID", createStatus)
        } else {
            let startStatus = step("AudioDeviceStart") { AudioDeviceStart(aggregateID, procID) }
            if startStatus != noErr {
                fail("AudioDeviceStart", startStatus)
            } else {
                started = true
                say("HOLD \(hold) s with IO running")
                Thread.sleep(forTimeInterval: hold)
                say("IO proc calls during the hold: \(callbacks.pointee)")
            }
        }
    }

    teardown()
    if let failedStep {
        say("RESULT mode=tap outcome=failed step=\(failedStep)")
        return 2
    }
    say("RESULT mode=tap outcome=started callbacks=\(callbacks.pointee)")
    return 0
}

say("START mode=\(mode) watchdog=\(Int(limit)) s hold=\(hold) s pid=\(getpid())")
exit(mode == "control" ? runControl() : runTap())
