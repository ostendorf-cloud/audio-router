// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// Every failure the tool reports. The description is the text the user sees.
public enum RouterError: Error, Equatable, CustomStringConvertible {
    case usage(String)
    case unknownDevice(uid: String)
    case channelsOutOfRange(first: Int, deviceChannels: Int, deviceName: String)
    case noMatchingProcess(bundleID: String)
    case coreAudio(operation: String, status: Int32)
    case unsupportedFormat(String)
    case ambiguousTapStream(device: String, buffers: [Int], tapShape: [Int])
    case sessionAlreadyStopped
    case teardownFailed([String])

    public var description: String {
        switch self {
        case .usage(let message):
            return message
        case .unknownDevice(let uid):
            return "No output device with uid \(uid). Run the devices command to list them."
        case .channelsOutOfRange(let first, let deviceChannels, let deviceName):
            return
                "Channels \(first),\(first + 1) do not fit: \(deviceName) has \(deviceChannels) output channels."
        case .noMatchingProcess(let bundleID):
            return
                "No audio process with bundle id \(bundleID). Start the app and run the apps command to list them."
        case .coreAudio(let operation, let status):
            var text = "\(operation) failed with OSStatus \(status) (\(fourCC(status)))."
            if operation.contains("(create tap)") || operation.contains("(create aggregate)") {
                text +=
                    " If the system audio capture permission is missing, allow it for the terminal app in"
                    + " System Settings, Privacy and Security, Screen and System Audio Recording,"
                    + " System Audio Recording Only."
            }
            return text
        case .unsupportedFormat(let message):
            return "Unsupported audio format: \(message)"
        case .ambiguousTapStream(let device, let buffers, let tapShape):
            return
                "Cannot tell the tap from the input channels of \(device): input buffers are \(buffers),"
                + " the tap is \(tapShape). Refusing to route, a device input could reach the output."
                + " A device with an input stream of the same shape as the tap is not supported yet."
        case .sessionAlreadyStopped:
            return "The route was stopped before it started."
        case .teardownFailed(let messages):
            return "Teardown finished with errors: " + messages.joined(separator: "; ")
        }
    }
}

/// Renders an OSStatus as its four character code when printable, otherwise as an empty marker.
func fourCC(_ status: Int32) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "no four character code" }
    return String(decoding: bytes, as: UTF8.self)
}
