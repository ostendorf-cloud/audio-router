# audio-router

Routes the audio of single macOS apps to channel pairs of any output device.
The concept is `docs/concepts/audio-router.md`. This repository holds phase 1, a command line prototype.

The global baseline already applies here and is not repeated below.

## Layout

- `Sources/RouterCore` is the pure logic.
  It imports only `Foundation` and `Darwin`. Extend that allow list only with a reason.
  `CoreImportTests` and `task lint:core-imports` enforce it.
  - `Protocols.swift` defines `AudioDeviceProviding`, `ProcessProviding` and `AudioRoutingBackend`.
  - `BundleGrouping`, `RoutePlanner`, `ArgumentParser`, `ChannelMapper`, `RouteSession` and `Formatting` are the logic.
    Unit tests cover all of them with fakes.
  - `Engine*.swift` is the route engine (`RouteEngine`), see the constraints below.
    `EngineTests`, `EngineRecoveryTests` and `EngineFakes` drive it with scripted events and an injected clock.
- `Sources/RouterCoreAudio` is the real Core Audio implementation of the protocols.
  It needs a Mac, devices and the capture permission.
  It holds `routerIOProc` and all code that runs on the audio thread.
  - `ChannelMapper` is split. Its pure parts stay in `RouterCore`.
    `render`, `markActive` and `measure` read `AudioBufferList`.
    So they are an extension in `ChannelMapperRealTime.swift`, next to `MeterBlock`.
  - Symbols both libraries need are `package`, not `public`.
    `package` keeps them out of the public API. Every target of this package still sees them.
- `Sources/AudioRouterApp` is the SwiftUI menu bar app. For now a menu bar icon with a Quit item.
- `Sources/audio-router-proto` is the command line diagnostic tool, not part of a release.
  It wires signals and the real backend, nothing else.
  `Info.plist` next to it is embedded into the binary, see below.
- `scripts/bundle.sh` and `Resources/` build `dist/audio-router.app` (`task bundle`, `task bundle:verify`,
  `task bundle:zip`). Only the `AudioRouterApp` product goes in, never `audio-router-proto`.
  `Resources/AppIcon.iconset` is a placeholder. `task bundle:verify` is not in `task check`, the `bundle` CI job runs it.
- `Tests/RouterCoreTests` has the unit tests (Swift Testing) and the fakes.
  `Tests/RouterCoreAudioTests` runs the real time code on in memory buffer lists.
- `docs/prototype-findings.md` is a template the owner fills from a real Mac. Never fill it with guesses.

## Commands

```sh
swift build
swift test
task check
```

`task check` runs format, license, RouterCore import, markdown, YAML and workflow lint.
Then it builds and tests.
`swift build` builds all four targets.
`task --list` shows the single targets.
The prototype binary:

```sh
.build/debug/audio-router-proto devices
.build/debug/audio-router-proto apps
.build/debug/audio-router-proto route --bundle-id <id> --device <uid> --channels <n>,<n+1> [--meter] \
  [--tap-mode stereo-mixdown|device-stream] [--source-channels <n>,<n+1>] [--tap-buffer <n>]
```

Channels count from 1 and must be two adjacent channels.
`--tap-mode device-stream` (the default) taps output stream 0 of the device without the stereo mixdown.
`--tap-mode stereo-mixdown` loses 24 dB on a 32 channel device (measured), see `docs/prototype-findings.md`
section 9. `--source-channels` names the tap channels that carry the app (default 1,2).
`--tap-buffer` forces the tap buffer (from 0). Without it the tap stream is found by the stream id diff.
About two seconds after the first signal, or when the wait for a signal ends silent, the route prints the
signal line and, through `TapCheck`, a warning when the tap side shows channels outside `--source-channels` or
none while a device input is active. It is a warning, never a refusal, and it does not check the gain:
`--meter` does that.
When the wait ends silent the tap check runs first (`TapCheck.silentWait`).
Signal outside `--source-channels` prints the specific warning only.
No tap signal with a device input active prints it plus one short permission sentence.
Nothing active prints the full permission warning only.
`--meter` prints peak and RMS in dBFS of the tap and the output to stdout once a second.
`ChannelMapper.measure` runs next to `render` in the IO proc with the same real time contract.

## Constraints

- The IO proc runs on the audio thread. It must not allocate, lock, log or touch a reference counted object.
  `ChannelMapper.render` and `routerIOProc` follow that. Keep new code out of them.
- Teardown order is fixed: IO proc, aggregate device, tap. `RouteSession` owns it and tests pin it.
- Every exit path tears down: signal (SIGINT, SIGTERM, SIGHUP), error, device removed.
  They all go through `Finisher.finish` (in `RouterCore`, with an injected exit), which calls
  `RouteSession.stop` and exits only after it returned.
  Add no `exit` that skips it. `RouteSession` holds one lock for all of `start` and every teardown, so a
  second `stop` returns only after the first teardown finished.
- The tap uses `mutedWhenTapped`, so a stopped IO proc lets the app play again. Do not switch to `muted`
  without a new decision in the concept.
- The target device is a sub device of the aggregate. `ChannelMapper.chooseTapBuffers` finds the tap among the
  device inputs and refuses when that is ambiguous. Keep that check. The stream id diff (`createAggregate`, then
  `ChannelMapper.tapBufferByStreamDiff`) names the tap buffer when it can. When it fails and the device inputs have
  the tap shape, the layout cannot prove the order and the route needs `--tap-buffer`. Do not widen the rule.
- `SIGTSTP` is ignored on purpose, a suspended process cannot tear down.
- `ProcessMonitoring` (`ProcessesMonitoring.swift`) reports app start, helper start, helper stop and app quit.
  Known limit: a helper that starts after a route started is not tapped until the route restarts.
  The tap covers the process objects that existed at creation, and the macOS 26 `CATapDescription.bundleIDs`
  API is out of reach with the 14.2 floor. `RouteEngine` restarts the route on `helperStarted`.
- `RouteEngine` is the one serial owner of the routes: a private serial dispatch queue, never the audio thread.
  A queue and not an actor, because `RouteSession.start` and `stop` block on Core Audio.
  It is the only consumer of its `DeviceModel` and its `ProcessMonitoring`.
  The UI reads the engine's snapshot (`snapshot`, `observe`), which carries the devices and apps too.
  Do not start a second monitor for the UI.
  - Every callback (monitor, retry timer, poll timer) carries a generation and is dropped when it is stale.
  - `setOn(false)` and `stopAll` return only when every route is down, in the fixed teardown order.
  - Device recovery uses the quiet period of `DeviceModel`. The engine adds no second debounce.
  - Silence, the tap check and a persisting sample rate mismatch are warnings on `running`, never a stop.
  - Failed starts retry with exponential backoff up to a cap. Other events do not cut the backoff short.
  - A permanent error (`StartErrorClass`) holds `refused` until `retryNow`, a change of that route,
    global off and on, or a new run (`stopAll`, then `start`).
    A transient error after `maxAttempts` holds `retriesExhausted` until the same actions, and also until the
    device comes back after it was gone or the app starts again after it quit.
  - `setOn(false)` and `stopAll` block the caller's thread. The app calls `stopAll` off the main thread on quit:
    `applicationShouldTerminate` answers `terminateLater` and replies when `stopAll` returned.
  - `observe` handlers run on the engine queue and must not call `start`, `setOn` or `stopAll`.
- Known limits of the engine:
  - Several routes at once on one device (two aggregates on one device) are not measured.
    Do not claim they work. The hardware checklist (issue 15) covers it.
  - Whether a denied capture permission fails with an OSStatus or delivers silence is not measured
    (`docs/prototype-findings.md` section 1). As an OSStatus it ends in `retriesExhausted`, as silence in the
    `noSignal` warning. `EngineConfiguration.classify` can map a measured status to `permanent`.
  - The default output moving away from a route's device does not count as device lost yet.
    A follow up issue tracks it.
  - The single serial queue blocks every other route while one start blocks, for example on a permission prompt.
- API names come from the SDK headers, not from memory. Check `AudioHardware.h`, `AudioHardwareTapping.h` and
  `CATapDescription.h` in `$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers`.
- Tests use no network, no audio hardware and no permission. New device or process code goes behind a protocol.
- Every Swift file starts with the license header:

  ```swift
  // Copyright 2026 Simon Ostendorf
  // SPDX-License-Identifier: Apache-2.0
  ```

  `Package.swift` keeps the `// swift-tools-version:` line first and the header right after it.
  `task lint:license` checks it.
- The usage string for the system audio capture permission lives in `Sources/audio-router-proto/Info.plist` under
  `NSAudioCaptureUsageDescription`. `Package.swift` embeds it with the linker flags
  `-sectcreate __TEXT __info_plist <path>`. Check it with
  `otool -s __TEXT __info_plist -v .build/debug/audio-router-proto`.

## Verifying the prototype on a real Mac

Agents cannot do this. The sandbox has no audio permission and Core Audio lists no devices there.
The owner runs, with an app that plays audio and an output device with several channels:

```sh
swift build -c release
.build/release/audio-router-proto devices
.build/release/audio-router-proto apps
.build/release/audio-router-proto route --bundle-id <id> --device <uid> --channels 3,4
```

Then answer every field of `docs/prototype-findings.md`.
Press Ctrl-C and confirm the app plays on its normal output again.

## Depends on the infrastructure repository

This repository was created by hand. Until the infrastructure repository covers it, these are set outside it.
Never change them with a CLI or the web UI. Propose the change in the infrastructure repository.

Still missing:

- A ruleset on `main`: required checks, merge method, no direct push.
  The check names below come from the job ids in `checks.yaml` and the called workflows' job names.
  Copy the exact names from a pull request run before writing the ruleset.
  - `fmt`, `build`, `test`, `markdownlint`, `yamllint`, `actionlint`
  - `renovate-config / Renovate configuration is valid`
  - `license / License headers`
  - `signoff / Every commit carries a DCO sign-off`
  - the app check `DCO`
- Allow auto-merge is off. Turn it on for the repository.
- Private vulnerability reporting is off. `SECURITY.md` names it as the preferred channel.

Already provided by the organisation, nothing to do here:

- The variables `GH_APP_RELEASE_APP_ID` and `GH_APP_DEPENDENCIES_APP_ID`.
- The secrets `GH_APP_RELEASE_PRIVATE_KEY`, `GH_APP_DEPENDENCIES_PRIVATE_KEY` and `GH_APP_SECURITY_PRIVATE_KEY`.
- The labels `dependencies` and `release: pending`, `release: tagged`, `release: alpha`, `release: beta`,
  `release: rc`.

Not verified: that the release and dependencies GitHub Apps are installed on this repository.
The security app is, its `DCO` check ran.

## Deviations

- The Swift toolchain is not pinned in `mise.toml`.
  The mise registry has `swift` as a core tool, but a macOS 27 SDK needs the Apple toolchain from Xcode or the
  Command Line Tools, and the pinned version could not be checked offline.
  CI uses the toolchain of the macOS runner image.
- `swift format` is part of the toolchain and is the only formatter and linter.
  There is no SwiftLint, so no rule set beyond the defaults of `swift format lint`.
  `.swift-format` sets four space indentation and a line length of 120.
- Swift jobs in `checks.yaml` run on `macos-latest`, because Core Audio only exists on macOS.
  `swift-tools-version: 6.0` needs Swift 6.0 or later, which means Xcode 16 or later, so the runner image must
  provide that. Not verified: the Xcode version of `macos-latest` was not checked.
  Source files avoid syntax from Swift 6.1 and later, such as trailing commas in argument lists.
- `codeql.yaml` scans the workflow files only (language `actions`). The shared reusable workflow runs on Linux and
  has no Swift build mode, so Swift code is not scanned yet.
- The workflow pins (`actions/checkout`, `jdx/mise-action` and the shared `ostendorf-cloud/workflows` calls at `v0.2.2`)
  are copied from `ostendorf-cloud/burnlink/.github/workflows`. A newer tag of `ostendorf-cloud/workflows` exists
  locally (`v0.6.0`), its inputs were not checked against this repository.
- `release-me.yaml` has no `files` list, because a Swift package has no version file. The version lives in the
  git tag and `CHANGELOG.md`. `release.yaml` and `renovate.yaml` are copied from burnlink at the same pins.
  `renovate.json` extends `github>ostendorf-cloud/workflows#v0.3.0` like govue, gitcd and wishlist.
  The `renovate.yaml` caller has no `workflow_run` trigger, workflows#74 is not merged.
- Local builds are signed ad hoc by the toolchain. There is no notarization and no Homebrew formula.
  `release.yaml` builds and publishes no binary.
  `app-release.yaml` attaches the ad hoc signed arm64 zip to a published release.
  It runs `task bundle`, `task bundle:verify` and `task bundle:zip`.
- `lint:license` in the Taskfile and `find-commands` in `checks.yaml` are kept in step by hand.
