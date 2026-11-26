# RouterCore

## Layout

- `Protocols.swift` defines `AudioDeviceProviding`, `ProcessProviding` and `AudioRoutingBackend`.
- `BundleGrouping`, `RoutePlanner`, `ArgumentParser`, `ChannelMapper`, `RouteSession` and `Formatting` are the logic.
  Unit tests cover all of them with fakes.
- `Engine*.swift` is the route engine (`RouteEngine`), see below.
  `EngineTests`, `EngineRecoveryTests` and `EngineFakes` drive it with scripted events and an injected clock.
- `Tests/RouterCoreTests` has the unit tests (Swift Testing) and the fakes.

## Process monitoring

- `ProcessMonitoring` (`ProcessesMonitoring.swift`) reports app start, helper start, helper stop and app quit.
- Known limit: a helper that starts after a route started is not tapped until the route restarts.
  The tap covers the process objects that existed at creation.
  The macOS 26 `CATapDescription.bundleIDs` API is out of reach with the 14.2 floor.
- `RouteEngine` restarts the route on `helperStarted`.

## Engine

- `RouteEngine` is the one serial owner of the routes: a private serial dispatch queue, never the audio thread.
  A queue and not an actor, because `RouteSession.start` and `stop` block on Core Audio.
- It is the only consumer of its `DeviceModel` and its `ProcessMonitoring`.
- The UI reads the engine's snapshot (`snapshot`, `observe`), which carries the devices and apps too.
  Do not start a second monitor for the UI.
- Every callback (monitor, retry timer, poll timer) carries a generation and is dropped when it is stale.
- `setOn(false)` and `stopAll` return only when every route is down, in the fixed teardown order.
  They block the caller's thread. The app calls `stopAll` off the main thread on quit:
  `applicationShouldTerminate` answers `terminateLater` and replies when `stopAll` returned.
- `observe` handlers run on the engine queue and must not call `start`, `setOn` or `stopAll`.
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
- A transient error after `maxAttempts` holds `retriesExhausted` until the same actions,
  and also until the device comes back after it was gone or the app starts again after it quit.
  The attempt count clears on the same events, a replug and an app restart included.

## Known limits of the engine

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
  Its route then stays `running` in silence. A real unplug most likely leaves the list. Not verified.
- When the confirm read throws, the loss waits for the quiet period, about 1.5 s.
- A flapping device with a failing start retries without end and never reaches `retriesExhausted`,
  because every replug clears the attempt count. The quiet period of `DeviceModel` plus the first backoff
  delay bound the pace. A possible follow up: clear the count only after the device stayed present for a while.
- The single serial queue blocks every other route while one start blocks, for example on a permission prompt.
