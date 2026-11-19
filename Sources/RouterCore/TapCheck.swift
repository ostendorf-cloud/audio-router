// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// What the activity of the tap says about the picked tap buffer.
public enum TapVerdict: Equatable, Sendable {
    /// Nothing contradicts the pick.
    case consistent
    /// Signal on tap channels outside the source pair.
    case outsideSource(channels: [Int])
    /// No signal on the tap while a device input shows activity.
    case tapSilentDeviceActive
}

/// Compares the tap side of the activity with the source pair. A warning only, never a refusal:
/// a multichannel app is legitimate and noise on a device input counts as activity.
public enum TapCheck {
    /// Pure decision. `tap` and `device` are the active channels from 1 inside their group.
    /// A tap that is silent while the device side is silent too says nothing.
    public static func verdict(tap: [Int], device: [Int], source: ChannelPair) -> TapVerdict {
        let outside = tap.filter { $0 != source.first && $0 != source.second }
        if !outside.isEmpty { return .outsideSource(channels: outside) }
        if tap.isEmpty && !device.isEmpty { return .tapSilentDeviceActive }
        return .consistent
    }

    /// How the buffer was chosen, in words for the warning.
    static func method(_ choice: TapBufferChoice) -> String {
        switch choice {
        case .streamDiff: return "stream id diff"
        case .override: return "--tap-buffer"
        case .uniqueShape: return "the only buffer of the tap shape"
        case .lastByMeasuredOrder: return "the last buffer of the tap shape"
        }
    }

    /// The warning text, nil when the pick is consistent.
    public static func warning(
        tap: [Int], device: [Int], source: ChannelPair, buffer: Int, choice: TapBufferChoice
    ) -> String? {
        let list = { (channels: [Int]) in channels.map(String.init).joined(separator: ",") }
        let pair = "\(source.first),\(source.second)"
        let what: String
        switch verdict(tap: tap, device: device, source: source) {
        case .consistent:
            return nil
        case .outsideSource(let channels):
            what = "signal on tap channels \(list(channels)), outside --source-channels \(pair)"
        case .tapSilentDeviceActive:
            what = "no signal on the tap, but on device input channels \(list(device))"
        }
        return "warning: tap buffer \(buffer) was picked by \(method(choice)): \(what). "
            + "The app may play on other channels, or the wrong buffer was picked. "
            + "If the app plays on other channels, retry with --tap-buffer <n> or --source-channels <a>,<b>."
    }

    /// What the route prints when the wait for a signal ends silent, in this order: the activity
    /// line (stdout), then the warnings (stderr).
    public struct SilentWaitOutput: Equatable, Sendable {
        public var activity: String?
        public var warnings: [String]
    }

    /// Decides the output of a wait that ended silent. The tap check comes first, because the
    /// permission hint names a cause that is wrong when the tap carries signal elsewhere.
    /// - Signal on tap channels outside the source pair: the specific warning only. Capture works.
    /// - No signal on the tap, a device input active: the specific warning, then the short hint.
    /// - Nothing active, or no activity data (stopped): the full permission warning only.
    public static func silentWait(
        active: [Int]?, info: RouteInfo?, fullHint: String, shortHint: String
    ) -> SilentWaitOutput {
        guard let active, let info else { return SilentWaitOutput(activity: nil, warnings: [fullHint]) }
        let found = ChannelMapper.activity(
            active: active, inputBuffers: info.inputBuffers, tapBuffers: info.tapBuffers)
        let activity = Formatting.activity(tap: found.tap, device: found.device, preferred: info.preferredStereo)
        let specific = warning(
            tap: found.tap, device: found.device, source: info.sourceChannels,
            buffer: info.tapBuffers.lowerBound, choice: info.tapBufferChoice)
        switch verdict(tap: found.tap, device: found.device, source: info.sourceChannels) {
        case .outsideSource:
            return SilentWaitOutput(activity: activity, warnings: specific.map { [$0] } ?? [])
        case .tapSilentDeviceActive:
            return SilentWaitOutput(activity: activity, warnings: (specific.map { [$0] } ?? []) + [shortHint])
        case .consistent:
            return SilentWaitOutput(activity: activity, warnings: [fullHint])
        }
    }

    /// The lines printed about two seconds after the first signal: the activity line, then the
    /// warning when there is one. Control thread only.
    public static func report(active: [Int], info: RouteInfo) -> (activity: String, warning: String?) {
        let found = ChannelMapper.activity(
            active: active, inputBuffers: info.inputBuffers, tapBuffers: info.tapBuffers)
        return (
            Formatting.activity(tap: found.tap, device: found.device, preferred: info.preferredStereo),
            warning(
                tap: found.tap, device: found.device, source: info.sourceChannels,
                buffer: info.tapBuffers.lowerBound, choice: info.tapBufferChoice)
        )
    }
}
