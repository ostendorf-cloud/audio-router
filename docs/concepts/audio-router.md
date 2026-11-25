# Audio router for macOS

Status: draft for review. The phase 1 prototype exists. API names and signatures are checked against the
macOS 27 SDK headers. Items marked (unverified) are runtime behaviour that only a run on a real Mac proves.
The scope of the first app release, 0.1.0, is fixed in the section Decisions for 0.1.0.

## Problem

- macOS has one system output. Spotify, a browser, a call app and a game all land on the same device.
- A multichannel interface, for example a mixer with 32 USB outputs, cannot give each app its own channel pair
  without a router.
- Loopback does this, but it is closed source, paid and tied to a virtual driver.
- The workaround today is one output device in each app's own settings. Many apps have no such setting.

## Goals

- A user routes a running app to a chosen channel pair of an output device in the GUI.
  In 0.1.0 that device is the one the app already plays to, see the product constraint below.
- The routing is stored as a profile and applies again after an app restarts or starts late.
- Switching the default output away from the target device tears the routing down and the apps play normally again.
  The route waits in `waitingForDevice`, see the engine transitions.
- The default output returning to the target device rebuilds the routing without a click.
- Added latency stays in the low milliseconds (unverified, measured in the prototype).
- The source is public under Apache-2.0 and builds without a paid Apple account.

## Non goals

- No virtual audio devices in the first release. That is a separate phase with its own concept.
- No device inputs as a source in 0.1.0, microphones included. Sources are apps only.
  Device inputs are a candidate after 0.1.0, see the backlog.
- No routing to another device than the one the app plays to in 0.1.0.
- No mixes, effects, EQ or recording.
- No remote control, no network audio.
- No Windows or Linux port.
- No per app volume and no gain per route in 0.1.0. Every route copies at unity.
- No App Store release and no App Sandbox in 0.1.0.
- No Intel build in 0.1.0.

## Approach

### Audio path (API names checked against the macOS 27 SDK headers, runtime behaviour unverified)

- One process tap per route in 0.1.0. The processes of one bundle id, helpers included, share it.
  Groups of apps on one tap are a candidate after 0.1.0.
  The call is `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)`,
  available from macOS 14.2 (`AudioHardwareTapping.h`).
  The first design used a stereo mixdown (`initStereoMixdownOfProcesses:`).
  It loses 24.1 dB on a 32 channel device (measured, `docs/prototype-findings.md` section 9).
  0.1.0 uses the device stream tap (`initWithProcesses:andDeviceUID:withStream:`).
  It read unity on the same device.
  `muteBehavior = CATapMutedWhenTapped` silences the app on its normal output only while a client reads the tap
  (`CATapDescription.h`). This supersedes the earlier plain muted tap: if the IO proc stops but the tap lives,
  the app plays normally again instead of staying silent. Whether the app is really silent while the route runs
  is unverified.
  `isPrivate` hides the tap from other processes.
- A tap takes process object ids (`AudioObjectID`), not bundle ids.
  The ids come from `kAudioHardwarePropertyProcessObjectList`, the bundle id of each from `kAudioProcessPropertyBundleID`.
  Matching by bundle id, helper processes included and never by PID, is therefore done by the router.
- One session per route in 0.1.0: tap, private aggregate device and IO proc.
  One shared aggregate per target device is a candidate after 0.1.0.
  The aggregate is private: `AudioHardwareCreateAggregateDevice` with
  `kAudioAggregateDeviceIsPrivateKey`.
  The target is the main sub device (`kAudioAggregateDeviceMainSubDeviceKey`) and the time source.
  The clock device key is a separate thing and is not used.
  The tap joins through `kAudioAggregateDeviceTapListKey`, listed by the tap's UUID (`CATapDescription.uuid`).
  Drift compensation is a key of each sub tap (`kAudioSubTapDriftCompensationKey`).
- The IO proc on the route's aggregate (`AudioDeviceCreateIOProcID`, `AudioDeviceStart`) copies the
  tap input onto the configured output channels.
  `AudioHardware.h` says in its AudioStream overview that linear PCM data is always presented as 32 bit native
  endian float, and in the `AudioDeviceIOProc` documentation that the output buffers are zeroed on entry.
  The overview is general, not specific to aggregate devices, so the prototype checks the stream formats at start.
- The target device is a sub device of the aggregate, so its own input channels (a mixer can have 32) join the
  aggregate's input buffer list. The headers do not say in which order sub device and tap streams come.
  The prototype finds the tap by its buffer shape and refuses to route when that is ambiguous, because a device
  input could otherwise reach the output. Open: the real order on a device with inputs.
  The stream id diff now names the tap buffer, measured on one device only.
  See `docs/prototype-findings.md` section 9.
- A process watcher adds a new matching process to its route's tap.
  From macOS 26 `CATapDescription` has `bundleIDs` and `processRestoreEnabled`, which may replace the watcher there.
  The 14.2 floor still needs the watcher. Open: whether `bundleIDs` also covers helper processes.

### Product constraint: the device stream limit

- A device stream tap only holds audio destined for the target device (`CATapDescription.h`).
- So a route works only while the app already plays to the destination device.
  If the app plays elsewhere, the tap is silent.
- The UI states this per route as "app not playing to the target device".
  It is not an error of the router.
- The intended signal is `kAudioProcessPropertyDevices` in output scope.
  `AudioHardware.h` describes it as the devices currently used by the process for output.
  Its runtime behaviour is unverified.
- Routing to another device needs the mixdown with gain compensation or a device to device
  aggregate. Both are candidates after 0.1.0.

### Components

- Core libraries: `RouterCore` holds the logic without Core Audio, `RouterCoreAudio` the audio path.
  See the app architecture below.
- Routing profile: JSON file with one entry per route.
  An entry holds the app bundle id, destination device uid, source pair, destination pair and an
  enabled flag.
- Device watcher: listens for default output and device list changes, waits 1 to 2 seconds before a rebuild
  so Bluetooth reconnect storms settle.
- App: SwiftUI menu bar item with status and on/off, plus a settings window with the route list.
  Each route has two pickers: source pair and destination pair.
  The matrix view is a candidate after 0.1.0.
- Login item: starts the app at login through `SMAppService`.

### App architecture (0.1.0)

- `RouterCore` (library): models, route model, JSON persistence, validation, `RoutePlanner`, the
  pure parts of `ChannelMapper` and the engine state machine. It imports no Core Audio and no UI.
- `RouterCoreAudio` (library): the Core Audio implementation of the `RouterCore` protocols.
  It moves out of `Sources/RouterCore/CoreAudio`.
  It holds the listeners for devices, default output, sample rate and the process list.
- `AudioRouterApp` (executable, SwiftUI): menu bar, settings, route editor, meters, login item.
  It talks only to the engine and never calls Core Audio.
- `audio-router-proto` stays as a diagnostic tool for the hardware checks. It is not shipped.
- The route engine is one serial owner, never on the audio thread.
  It reconciles the stored routes against device and process events.
  It runs one `RouteSession` per route.
- Engine states per route: `disabled`, `waitingForDevice`, `waitingForApp`, `starting`,
  `running` with warnings, `failed` with an error.
  Silence and the tap check map to warnings, never to a stop.
- Main transitions:
  - Enabled with device and app both present goes straight to `starting`.
    Otherwise it waits in `waitingForDevice` or `waitingForApp` until both are present.
  - `starting` goes to `running` or `failed`.
  - `running` goes to `failed` at runtime, for example on an IO proc error or a sample rate change.
  - `failed` goes to `starting` again after a retry with backoff.
  - Device lost goes to `waitingForDevice`, app quit to `waitingForApp`.
    Both apply from every state except `disabled`.
  - The default output moving away from the route's target device counts as device lost.
    The route goes to `waitingForDevice` and is torn down in the fixed order.
    The default output returning goes to `starting` without a click.
  - Disabling the route or global off goes to `disabled` from any state.
    Enabling it or global on is the way back out.
- Quit tears every route down in the fixed order (IO proc, aggregate, tap) before the app exits.
  Global off does the same without exiting.
  Quit or off during `starting` waits for the session lock, then tears down.
- Routes persist in `routes.json` under Application Support with a schema version.
  They reference devices by uid and apps by bundle id, never by object id or PID.

### Boundaries

- The GUI edits the profile, the core reads it. The core runs without the GUI.
- Needs the system audio capture permission, with its usage string under `NSAudioCaptureUsageDescription` in `Info.plist`.
  The key is not in the SDK headers. It was read from the `Info.plist` of apps installed on the development Mac.
  The command line prototype embeds it in the binary, see `docs/prototype-findings.md`.
- No kernel code, no driver, no admin install in phase 1.

### Phases

- Phase 1: command line prototype, one app to one channel pair. Proves latency, mute behaviour and the
  permission flow.
- Phase 2, release 0.1.0: the menu bar app. Routes with two pickers, the stored routes file, live meters,
  errors with actions, device loss and the default output rule (the route waits and the app plays on the new
  default), late apps, login item, ad hoc signed arm64 release builds. The release waits for the hardware checklist.
- Phase 3, after 0.1.0: candidates such as the groups matrix view, device inputs, cross device
  routing and gain. See the backlog below.
- Phase 4: Developer ID signing and notarisation, when the owner has the account.
- Phase 5: virtual devices as an audio server plug-in, own concept and review.

## Decisions

- Name and repository: `ostendorf-cloud/audio-router`.
- License: Apache-2.0.
- Development target: macOS 27. The lowest supported version is set in the decisions for 0.1.0.
- Signing: ad hoc, the public 0.1.0 release included (D11). A Developer ID and notarisation follow
  in phase 4, when the owner has an Apple developer account.
- Distribution: public open source on GitHub.

### Decisions for 0.1.0

Made by the owner on 2026-11-20. Each line names the reason.

- D1 sources: apps only, process tap in device stream mode.
  Measured at unity on the 32 channel device.
  Device inputs are a candidate after 0.1.0.
  They need their own concept section and a prototype run first.
- D2 destination: the device the app already plays to, any channel pair.
  The device stream tap cannot reach another device. No cross device routing in 0.1.0.
- D3 UI: SwiftUI `MenuBarExtra` and `Settings`. Both exist in the SDK.
  Judgement, not measured: they need less code than AppKit.
- D4 route editing: two pickers per route, source pair and destination pair.
  It maps one to one onto the route model. The matrix view is a candidate after 0.1.0.
- D5 gain: none per route. The device stream tap was measured at unity on the 32 channel device.
  The non goal of no per app volume stays.
- D6 App Sandbox off, hardened runtime on. There is no App Store release.
  Assumed, not verified: notarisation later needs no code change.
- D7 `audio-router-proto` stays a diagnostic tool in the repository.
  It runs the hardware checks and is not part of the release.
- D8 arm64 only. A universal build with SwiftPM and no Xcode is not verified.
- D9 lowest macOS 14.2, the API floor of the process tap. Documented as tested on macOS 27 only.
- D10 the release pull request for v0.1.0 stays open until the hardware checklist passes.
  Assumed: no usable audio device on the CI runner.
- D11 a new permission prompt per release is accepted until a Developer ID exists.
  TCC behaviour with ad hoc signatures is not verified, see Unverified for the app.

## Alternatives

- Extend an existing tool such as BlackHole: virtual devices only, no per app routing, driver install needed.
- Build the driver first: largest effort and risk, and the app routing works without it.
- Fixed config file with no GUI: rejected, the owner wants to route in a window.
- One aggregate for all devices: one clock master only, so several target devices need several aggregates.

## Open questions

- Does a muted tap (`mutedWhenTapped`) hide the app from the system volume and from AirPods handover:
  the prototype answers it.
- Do Chromium and WebEx helper processes appear under the parent bundle id: the prototype answers it.
- Does 0.1.0 run below macOS 27 (D9): findings section 6 answers it.
- Is a private aggregate device enough for several target devices at once: the prototype answers it.
- Which app does the permission prompt name for a command line tool, and does a denied tap fail or deliver silence:
  the prototype answers it. `NSAudioCaptureUsageDescription` was found in Claude.app, Discord.app and VS Code,
  and not in Terminal.app and iTerm.app.

### Unverified for the app

None of these is measured. The hardware checklist of 0.1.0 has to answer them.

- The permission flow for the app bundle: prompt, name shown, denial as an error or as silence.
- TCC with an ad hoc signature: whether a grant survives a new build or every release prompts again.
- Two routes at once: two private aggregates on the same device.
  See `docs/prototype-findings.md` section 5.
- Drift over a long run in device stream mode, where drift compensation is skipped.
- Gatekeeper with a downloaded, quarantined, ad hoc signed app on first open.
- `SMAppService.mainApp` as a login item with an ad hoc signed app.
- Hardened runtime and entitlements for the audio capture permission without a Developer ID.
- `kAudioProcessPropertyDevices` as the signal that the app plays to the target device.
- The real behaviour of a running tap when the default output changes. Untested.

## Backlog after 0.1.0

Candidates after 0.1.0, not issues. Each needs a concept update first.

- Device inputs as a source. Needs its own concept section and a prototype run.
- Cross device routing: the stereo mixdown with gain compensation, or a device to device
  aggregate with clock and drift handling. No prototype evidence for the aggregate yet.
- The matrix view: apps in rows, channel pairs in columns, one click sets a route.
- Groups of apps on one tap.
- One shared aggregate per target device instead of one per route.
- Gain per route in the IO proc. Needs lock free reads and the `otool` check of findings section 7.
- Per channel meters and peak hold.
- The macOS 26 tap API: `CATapDescription.bundleIDs` and `processRestoreEnabled`.
  They may replace the process watcher.
- Developer ID signing and notarisation. Needs the paid Apple Developer Program.
- Universal binary. SwiftPM without Xcode is not verified for it.
- Virtual devices, own concept and ADR.

## Related

- No ADR yet. The virtual driver decision becomes one when phase 5 starts.
