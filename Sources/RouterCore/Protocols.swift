// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// Lists output devices. The real implementation reads Core Audio, tests use a fake.
public protocol AudioDeviceProviding: Sendable {
    func outputDevices() throws -> [OutputDevice]

    /// Calls `handler` on an arbitrary queue when the device list changes. The handler must
    /// re-read `outputDevices()`. Keep the returned value alive as long as the callback is wanted.
    func observeDeviceList(_ handler: @escaping @Sendable () -> Void) throws -> any Cancellable
}

/// Lists the processes that are connected to Core Audio.
public protocol ProcessProviding: Sendable {
    func processes() throws -> [AudioProcess]
}

/// Something a caller stops when it no longer wants callbacks.
public protocol Cancellable: Sendable {
    func cancel()
}

/// Opaque handle for a started IO proc. The backend maps it to its own state.
public struct IOHandle: Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// A created process tap.
public struct TapInfo: Equatable, Sendable {
    public let objectID: ObjectID
    /// The tap's UUID string. The aggregate device lists the tap under this uid.
    public let uid: String
    /// Channels per frame of the tap, from `kAudioTapPropertyFormat`.
    public let channelCount: Int
    public let isInterleaved: Bool
    /// Sample rate of the tap format in Hz, 0 when unknown.
    public let sampleRate: Double
    /// How the tap was made.
    public let mode: TapMode

    public init(
        objectID: ObjectID, uid: String, channelCount: Int = 2, isInterleaved: Bool = true,
        sampleRate: Double = 0, mode: TapMode = .stereoMixdown
    ) {
        self.mode = mode
        self.objectID = objectID
        self.uid = uid
        self.channelCount = channelCount
        self.isInterleaved = isInterleaved
        self.sampleRate = sampleRate
    }
}

/// The format of one stream, as the owner needs it to compare sample rates and layouts.
public struct StreamFormatInfo: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let interleaved: Bool

    public init(sampleRate: Double, channels: Int, interleaved: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.interleaved = interleaved
    }
}

/// What the aggregate device looks like once the route runs. Printed on success.
public struct RouteInfo: Equatable, Sendable {
    public let tap: StreamFormatInfo
    /// Channels per buffer of the aggregate's input side, in buffer order.
    public let inputBuffers: [Int]
    /// The buffers of `inputBuffers` that hold the tap.
    public let tapBuffers: Range<Int>
    public let outputBuffers: [Int]
    public let inputStreams: [StreamFormatInfo]
    public let outputStreams: [StreamFormatInfo]
    /// Nominal sample rates in Hz, nil when Core Audio did not answer.
    public let aggregateSampleRate: Double?
    public let deviceSampleRate: Double?
    /// How the tap buffer was found.
    public let tapBufferChoice: TapBufferChoice
    /// The tap channels (from 1) the route copies, and the mode the tap was made in.
    public let sourceChannels: ChannelPair
    public let tapMode: TapMode

    public init(
        tap: StreamFormatInfo, inputBuffers: [Int], tapBuffers: Range<Int>, outputBuffers: [Int],
        inputStreams: [StreamFormatInfo], outputStreams: [StreamFormatInfo],
        aggregateSampleRate: Double?, deviceSampleRate: Double?,
        tapBufferChoice: TapBufferChoice = .uniqueShape, sourceChannels: ChannelPair = .firstPair,
        tapMode: TapMode = .stereoMixdown
    ) {
        self.tapBufferChoice = tapBufferChoice
        self.sourceChannels = sourceChannels
        self.tapMode = tapMode
        self.tap = tap
        self.inputBuffers = inputBuffers
        self.tapBuffers = tapBuffers
        self.outputBuffers = outputBuffers
        self.inputStreams = inputStreams
        self.outputStreams = outputStreams
        self.aggregateSampleRate = aggregateSampleRate
        self.deviceSampleRate = deviceSampleRate
    }
}

/// The side effects of one route: tap, aggregate device and IO proc. `RouteSession` drives it and
/// owns the order of creation and teardown.
public protocol AudioRoutingBackend: Sendable {
    /// Creates a private tap over the given process objects. `mode` says how, `deviceUID` is the
    /// target device that the device stream mode taps. The tap mutes the app only while a client
    /// reads it (`mutedWhenTapped`), so a stopped IO proc lets the app play again.
    func createTap(processes: [ObjectID], name: String, mode: TapMode, deviceUID: String) throws -> TapInfo

    /// Creates a private aggregate device with `deviceUID` as main sub device and the tap as
    /// sub tap, drift compensation on.
    func createAggregate(deviceUID: String, tap: TapInfo) throws -> ObjectID

    /// Registers the IO proc that copies the tap onto `channels` and starts it. Throws when the
    /// tap cannot be told from the device's own input channels or a stream format is not 32 bit
    /// float. `sourceChannels` are the tap channels to copy, `tapBuffer` forces the first tap
    /// buffer. With `meter` the IO proc also accumulates levels, see `readMeter`.
    func startIO(
        aggregate: ObjectID, tap: TapInfo, device: OutputDevice, channels: ChannelPair,
        sourceChannels: ChannelPair, tapBuffer: Int?, meter: Bool
    ) throws -> IOHandle

    /// The channels of the aggregate's input side that carried a sample that is not zero since the
    /// start, as indices over all input buffers in order (buffer major). Nil for an unknown handle.
    func activeInputChannels(handle: IOHandle) -> [Int]?

    /// The layout and formats found when the IO proc started, nil for an unknown handle.
    func routeInfo(handle: IOHandle) -> RouteInfo?

    /// The levels of the last full interval, nil when the meter is off, still priming or the
    /// handle is unknown.
    func readMeter(handle: IOHandle) -> MeterReading?

    /// True once the IO proc copied a sample that is not zero.
    func signalSeen(handle: IOHandle) -> Bool

    /// Stops the IO proc and destroys it. Returns only after the proc is no longer called.
    func stopIO(aggregate: ObjectID, handle: IOHandle) throws

    func destroyAggregate(_ aggregate: ObjectID) throws

    func destroyTap(_ tap: ObjectID) throws
}
