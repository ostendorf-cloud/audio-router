# AudioRouterApp

The app holds `MenuBarExtra`, the menu, the `Settings` scene and the app delegate (activation policy, quit handshake).

## Login item

- The Settings toggle registers `SMAppService.mainApp` through the `LoginItemService` protocol.
- `LoginItemViewModel` in `AudioRouterAppCore` maps the four statuses and an error to a toggle and a hint.
- The live service sits in `LoginItemLive.swift`, because the core has no ServiceManagement import.
- The view takes its model from `LoginItemContext.model` in the same file, not from `@State`.
- Settings reads the real status on each appear and each time the app becomes active,
  because the Settings window is kept on close and `onAppear` may not fire again.
- It only registers the app. Restoring routes is the engine's job.
- Not verified: the behaviour with the ad hoc build and with the notarized release, and from outside `/Applications`.

## App shell

- Quit has no time limit, so a hanging `stopAll` keeps the app from quitting. That keeps the teardown guarantee.
- A failed engine start (`startFailure`) clears only on a new `start`. The menu offers "Retry now" for it.
- The views in `Errors*.swift` only show the issues of `AudioRouterAppCore`, see its `AGENTS.md`.
