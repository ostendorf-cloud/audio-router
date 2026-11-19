# audio-router

Routes the audio of single macOS apps to channel pairs of any output device.
The concept is `docs/concepts/audio-router.md`. This repository holds phase 1, a command line prototype.

The global baseline already applies here and is not repeated below.

## Layout

- `Sources/RouterCore` is the library. Pure logic plus the Core Audio implementation.
  - `Protocols.swift` defines `AudioDeviceProviding`, `ProcessProviding` and `AudioRoutingBackend`.
  - `BundleGrouping`, `RoutePlanner`, `ArgumentParser`, `ChannelMapper`, `RouteSession` and `Formatting` are the logic.
    Unit tests cover all of them with fakes.
  - `CoreAudio/` is the real implementation of the protocols. It needs a Mac, devices and the capture permission.
- `Sources/audio-router-proto` is the executable. It wires signals and the real backend, nothing else.
  `Info.plist` next to it is embedded into the binary, see below.
- `Tests/RouterCoreTests` has the unit tests (Swift Testing) and the fakes.
- `docs/prototype-findings.md` is a template the owner fills from a real Mac. Never fill it with guesses.

## Commands

```sh
swift build
swift test
task check
```

`task check` runs format, license, markdown, YAML and workflow lint, then build and test.
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
- `lint:license` in the Taskfile and `find-commands` in `checks.yaml` are kept in step by hand.
