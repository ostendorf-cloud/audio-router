# Audio router for macOS

Status: draft for review. The phase 1 prototype exists. API names and signatures are checked against the
macOS 27 SDK headers. Items marked (unverified) are runtime behaviour that only a run on a real Mac proves.

## Problem

- macOS has one system output. Spotify, a browser, a call app and a game all land on the same device.
- A multichannel interface, for example a mixer with 32 USB outputs, cannot give each app its own channel pair without a router.
- Loopback does this, but it is closed source, paid and tied to a virtual driver.
- The workaround today is one output device in each app's own settings. Many apps have no such setting.

## Goals

- A user routes a running app to a chosen channel pair of any Core Audio output device in the GUI.
- The routing is stored as a profile and applies again after an app restarts or starts late.
- Switching the default output away from the target device tears the routing down and the apps play normally again.
- The default output returning to the target device rebuilds the routing without a click.
- Added latency stays in the low milliseconds (unverified, measured in the prototype).
- The source is public under Apache-2.0 and builds without a paid Apple account.

## Non goals

- No virtual audio devices in the first release. That is a separate phase with its own concept.
- No microphone routing, mixes, effects, EQ or recording.
- No remote control, no network audio.
- No Windows or Linux port.
- No per app volume in the first release.

## Approach

### Audio path (API names checked against the macOS 27 SDK headers, runtime behaviour unverified)

- One process tap per group of apps: `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)`,
  available from macOS 14.2 (`AudioHardwareTapping.h`).
  The description is a stereo mixdown (`initStereoMixdownOfProcesses:`), so one tap carries one channel pair.
  `muteBehavior = CATapMuted` silences the app on its normal output.
  `isPrivate` hides the tap from other processes.
- A tap takes process object ids (`AudioObjectID`), not bundle ids.
  The ids come from `kAudioHardwarePropertyProcessObjectList`, the bundle id of each from `kAudioProcessPropertyBundleID`.
  Matching by bundle id, helper processes included and never by PID, is therefore done by the router.
- One private aggregate device per target device (`AudioHardwareCreateAggregateDevice`, `kAudioAggregateDeviceIsPrivateKey`).
  The target is the main sub device (`kAudioAggregateDeviceMainSubDeviceKey`) and the time source.
  The clock device key is a separate thing and is not used.
  The tap joins through `kAudioAggregateDeviceTapListKey`, listed by the tap's UUID (`CATapDescription.uuid`).
  Drift compensation is a key of each sub tap (`kAudioSubTapDriftCompensationKey`).
- One IOProc on the aggregate (`AudioDeviceCreateIOProcID`, `AudioDeviceStart`) copies each group's tap input onto its
  configured output channels.
  Core Audio presents the data as 32 bit float and hands over zeroed output buffers (`AudioHardware.h`).
- A process watcher adds a new matching process to its group's tap.
  From macOS 26 `CATapDescription` has `bundleIDs` and `processRestoreEnabled`, which may replace the watcher there.
  The 14.2 floor still needs the watcher. Open: whether `bundleIDs` also covers helper processes.

### Components

- `RouterCore`: Swift package with the audio path, no UI, testable with a fake device layer.
- Routing profile: JSON file, groups to bundle ids, groups to device uid and channel pair.
- Device watcher: listens for default output and device list changes, waits 1 to 2 seconds before a rebuild so Bluetooth reconnect storms settle.
- App: SwiftUI, menu bar item with status and on/off, plus a window with a matrix of apps in rows and output channel pairs in columns. A click sets the route.
- Login item: starts the app at login through `SMAppService`.

### Boundaries

- The GUI edits the profile, the core reads it. The core runs without the GUI.
- Needs the system audio capture permission, with its usage string under `NSAudioCaptureUsageDescription` in `Info.plist`.
  The key is not in the SDK headers. It was read from the `Info.plist` of apps installed on the development Mac.
  The command line prototype embeds it in the binary, see `docs/prototype-findings.md`.
- No kernel code, no driver, no admin install in phase 1.

### Phases

- 1. Command line prototype: one app to one channel pair. Proves latency, mute behaviour and the permission flow.
- 2. Groups and the profile file.
- 3. Device changes and the Bluetooth wait.
- 4. SwiftUI matrix window and menu bar item.
- 5. Login item, signing, release builds.
- 6. Virtual devices as an audio server plug-in, own concept and review.

## Decisions

- Name and repository: `ostendorf-cloud/audio-router`.
- License: Apache-2.0.
- Development target: macOS 27. The lowest supported version follows from what the prototype proves, 14.2 is the API floor from memory.
- Signing: ad hoc during the test phase. A Developer ID follows when the owner has an Apple developer account, so public releases get notarised.
- Distribution: public open source on GitHub.

## Alternatives

- Extend an existing tool such as BlackHole: virtual devices only, no per app routing, driver install needed.
- Build the driver first: largest effort and risk, and the app routing works without it.
- Fixed config file with no GUI: rejected, the owner wants to route in a window.
- One aggregate for all devices: one clock master only, so several target devices need several aggregates.

## Open questions

- Does a muted tap hide the app from the system volume and from AirPods handover: the prototype answers it.
- Do Chromium and WebEx helper processes appear under the parent bundle id: the prototype answers it.
- Which lowest macOS version does the final design support: the prototype answers it.
- Is a private aggregate device enough for several target devices at once: the prototype answers it.
- Hardened runtime and entitlements for the audio capture permission without a Developer ID: owner checks when the account exists.

## Related

- No ADR yet. The virtual driver decision becomes one when phase 6 starts.
