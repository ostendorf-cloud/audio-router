# AudioRouterAppCore

## Route editor (`Editor*.swift` here and in `AudioRouterApp`)

- `EditorViewModel` holds the logic. It sits behind `DeviceProviding`, `AppProviding` and `EditorRouteStoring`.
  `EditorSnapshotProvider` reads devices and apps from the engine snapshot, so the UI starts no second monitor.
- Validation is `RouteValidator`. Its errors for the edited route map to field messages.
  Errors of other routes never block a save. The edited route is checked as enabled.
- Save writes the `RouteStore` first and calls `engine.setRoutes` second. A failed write leaves the engine alone.
  Delete does the same with the route removed, and `setRoutes` tears the removed route down.
- The destination picker offers the stereo pairs 1,2, 3,4 and so on of the whole device.
- The source picker offers the pairs of output stream 0, because a device stream tap has the format of that
  stream (`CoreAudioRoutingBackend.createTap`).
  The device model lists buffers, so the first buffer stands for stream 0 when it has two channels or more,
  else the whole device count is used. That is inferred, not measured.
  The validator does not check the source pair, and an `unsupportedFormat` start failure stays with issue 23.
- The menu switch of a route is not stored. A save writes the on and off state of every route.
  An edit never changes the state of the edited route.
- `RouteEngine.setRoutes` returns before the snapshot changes.
  `DesiredRoutesEngine` wraps the engine, keeps the last list sent and is the one engine of the shell and the editor.
  A menu toggle, a save and a delete build on that list and not on the snapshot.
  Window left: a change that bypasses the wrapper, for example a second caller of the raw engine,
  would still build on a stale list.

## Meters (issue 22)

- `RouteEngine.meterReadings()` reads the meter of every running route and returns one `MeterReading` per route id.
  The engine never reads a meter on its own, the snapshot carries none.
- `MeterPoller` calls it at about 15 Hz, off the main thread, and only while the menu or the settings window
  is visible. Each part reports itself as a `MeterClient`, and polling stops when none is left.
- The menu shows text lines only and is polled while it tracks: `MeterMenuTracker` follows
  `NSMenu.didBeginTrackingNotification` and `didEndTrackingNotification`, filtered to the menu with the quit item.
  `onAppear` is not used for the menu. The bar is in Settings, driven by the window's own visibility.
- Only one reader may poll, a second one takes intervals from the first.
- Left and right are merged in one level, and `output` equals `tap` by construction, so the UI shows the tap.
- The bar runs from -60 to 0 dBFS (`MeterLevel`), the number is the peak.

## Errors and actions (issue 23)

- `RouteIssues.of` (`Errors*.swift`) maps a route state to `RouteIssue` values:
  kind, severity, message and one `RouteAction` (`openAudioCaptureSettings`, `retry`, `chooseDevice`, `none`).
  The views in `Sources/AudioRouterApp/Errors*.swift` only show them.
  `IssueActionRunner` runs the action through `SettingsOpening`, so tests use a fake.
- `RouteStatus.startError` carries the typed `RouterError` of a failed start, and `RouteIssues.kind(of:)` reads it.
  For an error of another type `kind(ofFailureMessage:)` reads the text.
  A test pins every `RouterError` text to `kind(of:)`. Reword an error text only together with that mapping.
- A failed teardown step shows for a switched off route too, and warns on the icon while the global switch is on.
- A new `RouterError` case, `RouteState`, `RouteFailure` or `RouteWarning` case needs a mapping:
  the exhaustive switches in `ErrorsTests` stop compiling.
  `Tests/AudioRouterAppTests/Errors/Golden/messages.txt` holds every message.
  Change it with the text, never to make a test pass.
- A message says "likely" where the cause is inferred. The permission is always inferred:
  no status query is verified and a denied tap may deliver silence.
  The settings button opens the generic privacy pane, the anchor of the audio capture list is not verified.
- `ShellStatus.of` derives the menu bar icon from `RouteIssues.worstSeverity`, so the two cannot drift.
  `ErrorsTests` writes the icon of every fixture out, so a changed severity shows as a changed icon.
  `ShellRowState.of` reads the severity of a running route's warnings the same way.
- Silence of an app that plays nothing (`appNotPlaying`, likely paused) is `info`: no triangle, row `Running`
  (issue 61). Silence while the app plays stays a warning, the permission may be missing.
  Known limit: the snapshot reads `isRunningOutput` at app start and helper events only, not live.
  So the text claims nothing about what happens when the app plays again.
