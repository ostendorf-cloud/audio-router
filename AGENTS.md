# audio-router

Routes the audio of single macOS apps to channel pairs of any output device.
The concept is `docs/concepts/audio-router.md`. This repository holds the menu bar app (phase 2, release 0.1.0)
and `audio-router-proto`, the command line diagnostic tool from phase 1.
The README describes install and use. Keep it in step with the app sections below.
Stated limits of the release: macOS 14.2 floor, tested on macOS 27 only, arm64 only, ad hoc signed, not notarised.

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
- `Sources/AudioRouterApp` is the SwiftUI menu bar app: `MenuBarExtra`, the menu, the `Settings` scene and the
  app delegate (activation policy, quit handshake). Only `Shell*.swift` views and wiring, no logic worth a test.
- `Sources/AudioRouterAppCore` is the testable part of the app: view model, state mapping and the `ShellEngine`
  seam over `RouteEngine`. An executable target cannot be imported by tests, so this is a library without SwiftUI.
  `Tests/AudioRouterAppTests` drives it with a fake engine.
- `Sources/audio-router-proto` is the command line diagnostic tool, not part of a release.
  It wires signals and the real backend, nothing else.
  `Info.plist` next to it is embedded into the binary, see below.
- `scripts/bundle.sh` and `Resources/` build `dist/audio-router.app` (`task bundle`, `task bundle:verify`,
  `task bundle:zip`). Only the `AudioRouterApp` product goes in, never `audio-router-proto`.
  `Resources/AppIcon.iconset` is a placeholder. `task bundle:verify` is not in `task check`, the `bundle` CI job runs it.
- `Tests/RouterCoreTests` has the unit tests (Swift Testing) and the fakes.
  `Tests/RouterCoreAudioTests` runs the real time code on in memory buffer lists.
- `docs/prototype-findings.md` is a template the owner fills from a real Mac. Never fill it with guesses.

## Login item

The Settings toggle registers `SMAppService.mainApp` through the `LoginItemService` protocol.
`LoginItemViewModel` in `AudioRouterAppCore` maps the four statuses and an error to a toggle and a hint.
The live service sits in `Sources/AudioRouterApp/LoginItemLive.swift`, because the core has no ServiceManagement import.
The view takes its model from `LoginItemContext.model` in the same file, not from `@State` (see the constraints).
Settings reads the real status on each appear and each time the app becomes active, because the Settings window
is kept on close and `onAppear` may not fire again. It only registers the app. Restoring routes is the engine's job.
Not verified: the behaviour with the ad hoc build, and from outside `/Applications`.

## Commands

```sh
swift build
swift test
task check
```

`task check` runs format, license, RouterCore import, SwiftUI macro, markdown, YAML and workflow lint.
Then it builds and tests.
`swift build` builds all five targets.
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
  - The destination counts as lost when it is gone, dead, or the default output moved away from it
    (concept, issue 42 and issue 49).
    The route stops, releases the tap and waits in `waitingForDevice`.
    The released tap no longer mutes the app, so it plays on the current default output.
  - `DeviceModel` reports a dead device and a default that moved to another device at once.
    A missing device or a read without any default goes out after a second read 50 ms later.
    A failed alive read keeps the last flag.
    The return, a device back or the default back on the destination, waits for the quiet period.
    The engine adds no second debounce.
  - A default change that does not leave the destination leaves the route alone.
    A route whose destination is not the default at engine start runs. A new run forgets the move.
  - Silence, the tap check and a persisting sample rate mismatch are warnings on `running`, never a stop.
  - Failed starts retry with exponential backoff up to a cap. Other events do not cut the backoff short.
  - A permanent error (`StartErrorClass`) holds `refused` until `retryNow`, a change of that route,
    global off and on, or a new run (`stopAll`, then `start`).
    A transient error after `maxAttempts` holds `retriesExhausted` until the same actions, and also until the
    device comes back after it was gone or the app starts again after it quit.
    The attempt count clears on the same events, a replug and an app restart included.
  - `setOn(false)` and `stopAll` block the caller's thread. The app calls `stopAll` off the main thread on quit:
    `applicationShouldTerminate` answers `terminateLater` and replies when `stopAll` returned.
  - `observe` handlers run on the engine queue and must not call `start`, `setOn` or `stopAll`.
- Known limits of the engine:
  - Several routes at once on one device (two aggregates on one device) are not measured.
    Do not claim they work. The hardware checklist (`docs/hardware-checklist.md`, issue 28) covers it.
  - Whether a denied capture permission fails with an OSStatus or delivers silence is not measured
    (`docs/prototype-findings.md` section 1). As an OSStatus it ends in `retriesExhausted`, as silence in the
    `noSignal` warning. `EngineConfiguration.classify` can map a measured status to `permanent`.
  - Why the default counts: a device stream tap mixes the app's audio "destined for the selected
    device stream" (`CATapDescription.h` line 87, quoted in `docs/prototype-findings.md` line 235,
    paraphrased in line 439). An app that follows the default sends nothing to the destination.
    The hardware checklist verifies that the app is audible on the new default after the move.
  - A destination that is back while the default stays elsewhere keeps the route waiting.
  - The rule assumes every app follows the default output. An app with its own output device
    (concept line 13), for example a DAW set to the X32 while the default is elsewhere, loses a
    working route when the default leaves the X32.
  - A device that stays listed but whose alive read always fails keeps its last flag forever.
    Its route then stays `running` in silence.
    A real unplug most likely leaves the list. Not verified.
  - When the confirm read throws, the loss waits for the quiet period, about 1.5 s.
  - A flapping device with a failing start retries without end and never reaches `retriesExhausted`,
    because every replug clears the attempt count. The quiet period of `DeviceModel` plus the first backoff
    delay bound the pace. A possible follow up: clear the count only after the device stayed present for a while.
  - The single serial queue blocks every other route while one start blocks, for example on a permission prompt.
- Route editor (`Editor*.swift` in `AudioRouterApp` and `AudioRouterAppCore`):
  - `EditorViewModel` holds the logic. It sits behind `DeviceProviding`, `AppProviding` and `EditorRouteStoring`.
    `EditorSnapshotProvider` reads devices and apps from the engine snapshot, so the UI starts no second monitor.
  - Validation is `RouteValidator`. Its errors for the edited route map to field messages.
    Errors of other routes never block a save. The edited route is checked as enabled.
  - Save writes the `RouteStore` first and calls `engine.setRoutes` second. A failed write leaves the engine alone.
    Delete does the same with the route removed, and `setRoutes` tears the removed route down.
  - The destination picker offers the stereo pairs 1,2, 3,4 and so on of the whole device.
    The source picker offers the pairs of output stream 0, because a device stream tap has the format of that
    stream (`CoreAudioRoutingBackend.createTap`). The device model lists buffers, so the first buffer stands for
    stream 0 when it has two channels or more, else the whole device count is used. That is inferred, not
    measured. The validator does not check the source pair, and an `unsupportedFormat` start failure stays with
    issue 23.
  - The menu switch of a route is not stored. A save writes the on and off state of every route and an edit never
    changes the state of the edited route.
  - `RouteEngine.setRoutes` returns before the snapshot changes. `DesiredRoutesEngine` wraps the engine, keeps the
    last list sent and is the one engine of the shell and the editor. A menu toggle, a save and a delete build on
    that list and not on the snapshot. Window left: a change that bypasses the wrapper, for example a second
    caller of the raw engine, would still build on a stale list.
- Known limits of the app shell:
  - Quit has no time limit, so a hanging `stopAll` keeps the app from quitting. That keeps the teardown guarantee.
  - A failed engine start (`startFailure`) clears only on a new `start`. The menu offers "Retry now" for it.
- Meters (issue 22): `RouteEngine.meterReadings()` reads the meter of every running route and returns one
  `MeterReading` per route id. The engine never reads a meter on its own, the snapshot carries none.
  `MeterPoller` (`AudioRouterAppCore`) calls it at about 15 Hz, off the main thread, and only while the menu or
  the settings window is visible. Each part reports itself as a `MeterClient`, and polling stops when none is left.
  The menu shows text lines only and is polled while it tracks: `MeterMenuTracker` follows
  `NSMenu.didBeginTrackingNotification` and `didEndTrackingNotification`, filtered to the menu with the quit item.
  `onAppear` is not used for the menu. The bar is in Settings, driven by the window's own visibility.
  Only one reader may poll, a second one takes intervals from the first.
  Left and right are merged in one level, and `output` equals `tap` by construction, so the UI shows the tap.
  The bar runs from -60 to 0 dBFS (`MeterLevel`), the number is the peak.
- Errors and actions (issue 23):
  - `RouteIssues.of` (`Errors*.swift` in `AudioRouterAppCore`) maps a route state to `RouteIssue` values:
    kind, severity, message and one `RouteAction` (`openAudioCaptureSettings`, `retry`, `chooseDevice`, `none`).
    The views in `Sources/AudioRouterApp/Errors*.swift` only show them. `IssueActionRunner` runs the action
    through `SettingsOpening`, so tests use a fake.
  - `RouteStatus.startError` carries the typed `RouterError` of a failed start, and `RouteIssues.kind(of:)` reads it.
    For an error of another type `kind(ofFailureMessage:)` reads the text. A test pins every `RouterError` text to
    `kind(of:)`. Reword an error text only together with that mapping.
  - A failed teardown step shows for a switched off route too, and warns on the icon while the global switch is on.
  - A new `RouterError` case, `RouteState`, `RouteFailure` or `RouteWarning` case needs a mapping: the exhaustive
    switches in `ErrorsTests` stop compiling. `Tests/AudioRouterAppTests/Errors/Golden/messages.txt` holds every
    message. Change it with the text, never to make a test pass.
  - A message says "likely" where the cause is inferred. The permission is always inferred: no status query is
    verified and a denied tap may deliver silence. The settings button opens the generic privacy pane, the anchor of
    the audio capture list is not verified.
  - The menu bar icon stays `ShellStatus.of`. A test keeps the worst issue severity in step with it.
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
  - `scripts/lint-swiftui-macros.sh` (`task lint:swiftui-macros`, CI job `swiftui-macros`) fails with file, line and
    reason when `Sources` holds one of them. The list sits at the top of the script. Extend it when a new SDK adds a
    macro from a plugin the Command Line Tools lack. Find them with `grep -rn externalMacro` in the swiftinterface
    files of every framework under `/Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk/System/Library/Frameworks`.
    Macros of frameworks the app does not import, such as SwiftData or AppIntents, are not listed yet.
  - It is a line check that drops `//` comments only. A macro name in a block comment or string fails closed.
    A name matches only with its sigil and as a whole word, so `@StateObject` or the type `Predicate` pass.
  - Two contrived spellings escape it: a backticked name such as ``@`State` ``, and code after a string that
    holds `//` on the same line.
  - `scripts/lint-swiftui-macros_test.sh` runs it on temporary trees, and the task runs that test first.
  - CI builds with Xcode, so the `build` job does not catch a macro. Only this lint does.
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

## Verifying on a real Mac

Agents cannot do this. The sandbox has no audio permission and Core Audio lists no devices there.
The owner runs `docs/hardware-checklist.md` for the app before a release.
It covers Gatekeeper, the permission prompt, login item and the device rules.
A README claim marked "not verified" stays marked until the owner's checklist confirms it.
For the prototype, the owner runs, with an app that plays audio and an output device with several channels:

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
  - `fmt`, `build`, `test`, `swiftui-macros`, `markdownlint`, `yamllint`, `actionlint`
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
