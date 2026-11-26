# audio-router

Routes the audio of single macOS apps to channel pairs of any output device.
The concept is `docs/concepts/audio-router.md`. This repository holds the menu bar app (phase 2, release 0.1.0)
and `audio-router-proto`, the command line diagnostic tool from phase 1.
The README describes install and use. Keep it in step with the app sections below.
Stated limits of the release: macOS 14.2 floor, tested on macOS 27 only, arm64 only.
Releases after 0.1.0 are signed with a Developer ID, notarized and stapled. Not verified until the first one ran.

The global baseline already applies here and is not repeated below.

## Layout

- `Sources/RouterCore` is the pure logic.
  It imports only `Foundation` and `Darwin`. Extend that allow list only with a reason.
  `CoreImportTests` and `task lint:core-imports` enforce it.
  Details, the route engine and its limits: `Sources/RouterCore/AGENTS.md`.
- `Sources/RouterCoreAudio` is the real Core Audio implementation of the protocols.
  It holds `routerIOProc` and all code that runs on the audio thread.
  Tap rules and the `package` access rule: `Sources/RouterCoreAudio/AGENTS.md`.
- `Sources/AudioRouterApp` is the SwiftUI menu bar app. Only `Shell*.swift` views and wiring, no logic worth a test.
  Login item and shell limits: `Sources/AudioRouterApp/AGENTS.md`.
- `Sources/AudioRouterAppCore` is the testable part of the app: view model, state mapping and the `ShellEngine`
  seam over `RouteEngine`. An executable target cannot be imported by tests, so this is a library without SwiftUI.
  Editor, meters and errors: `Sources/AudioRouterAppCore/AGENTS.md`.
- `Sources/audio-router-proto` is the command line diagnostic tool, not part of a release.
  It wires signals and the real backend, nothing else.
  Flags, `Info.plist` and the real Mac run: `Sources/audio-router-proto/AGENTS.md`.
- `scripts/` holds the bundle, signing, cask and lint scripts, each with a `_test.sh`.
  Signing, notarization, cask and macro lint: `scripts/AGENTS.md`.
- `Resources/` holds the entitlements and the app bundle inputs.
  `Resources/Branding` holds the icon sources and the committed PNGs: `Resources/Branding/AGENTS.md`.
- `.github/workflows/`: pins, release flow and CodeQL scope are in `.github/workflows/AGENTS.md`.
- `docs/infrastructure-dependencies.md` lists what is set outside this repository and still missing.
- `docs/prototype-findings.md` is a template the owner fills from a real Mac. Never fill it with guesses.
- `docs/hardware-checklist.md` is what the owner runs on a real Mac before a release.

## Commands

```sh
swift build
swift test
task check
```

`task check` runs format, license, RouterCore import, SwiftUI macro, markdown, YAML and workflow lint
and the cask and signing script tests. Then it builds and tests.
`task bundle:verify` and `task lint:cask-audit` are CI only and not part of `check`.
`task lint:cask-audit` (job `cask-audit`) needs Homebrew and taps a scratch tap `audio-router-ci/audit`.
`swift build` builds all five targets.
`task --list` shows the single targets.

## Constraints

- The IO proc runs on the audio thread. It must not allocate, lock, log or touch a reference counted object.
  `ChannelMapper.render` and `routerIOProc` follow that. Keep new code out of them.
- Teardown order is fixed: IO proc, aggregate device, tap. `RouteSession` owns it and tests pin it.
- Every exit path tears down: signal (SIGINT, SIGTERM, SIGHUP), error, device removed.
  They all go through `Finisher.finish` (in `RouterCore`, with an injected exit), which calls
  `RouteSession.stop` and exits only after it returned.
  Add no `exit` that skips it. `RouteSession` holds one lock for all of `start` and every teardown, so a
  second `stop` returns only after the first teardown finished.
- The whole package builds with the Command Line Tools alone, without Xcode (issue 58).
  No source file may use a macro whose compiler plugin ships with Xcode only.
  With the macOS 27 SDK these are `@State`, `@Entry`, `@Animatable`, `@AnimatableIgnored` (plugin
  `SwiftUIMacros`), `@Previewable` and `#Preview` (plugin `PreviewsMacros`), and `#Predicate`, `#Expression` and
  `#bundle` (plugin `FoundationMacros`). The Foundation types `Predicate` and `Expression` without `#` are fine.
  `@Observable` and `@ObservationIgnored` come from the `ObservationMacros` plugin of the Command Line Tools and are
  fine. `@Bindable` is a property wrapper, not a macro.
  View state goes into an `@Observable` model in `AudioRouterAppCore` with a test, for example
  `EditorViewModel.pendingDelete`. A model the view owns comes from a `@MainActor` context like
  `EditorContext` or `LoginItemContext`.
  `task lint:swiftui-macros` enforces it, see `scripts/AGENTS.md`. CI builds with Xcode, so only that lint catches it.
- API names come from the SDK headers, not from memory. Check `AudioHardware.h`, `AudioHardwareTapping.h` and
  `CATapDescription.h` in `$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers`.
- Tests use no network, no audio hardware and no permission. New device or process code goes behind a protocol.
  Agents cannot verify on a real Mac: the sandbox has no audio permission and Core Audio lists no devices there.
- A README claim marked "not verified" stays marked until the owner's hardware checklist confirms it.
- Every Swift file starts with the license header:

  ```swift
  // Copyright 2026 Simon Ostendorf
  // SPDX-License-Identifier: Apache-2.0
  ```

  `Package.swift` keeps the `// swift-tools-version:` line first and the header right after it.
  `task lint:license` checks it.

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
- Workflow and release deviations, such as the copied pins and the ad hoc signing of local builds:
  `.github/workflows/AGENTS.md`.
