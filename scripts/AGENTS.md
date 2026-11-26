# scripts

## Signing (issue 67)

- `sign-app.sh` signs nested code first, then the app, always with the hardened runtime
  and `Resources/AudioRouter.entitlements`. Ad hoc without `SIGNING_IDENTITY`, Developer ID with a timestamp with it.
  `SIGNING_REQUIRED=true` forbids the ad hoc fallback.
- `verify-signature.sh` is the signature part of `task bundle:verify` and `task bundle:zip`.
  `VERIFY_SIGNATURE` picks `any`, `developer-id` or `notarized`.
- `signing-keychain.sh` creates and removes the temporary release keychain.
- `notarize.sh` runs `notarytool` and `stapler` (`task bundle:notarize`).
- Each script has a `_test.sh` with fake tools, run by `task test:signing` (CI job `signing`, macOS).
- No script may print a secret value. The tests check that with sentinel values, keep them when a script changes.
- `notarize.sh` polls for up to `NOTARY_TIMEOUT` (45m in the workflow). A timeout prints the submission id.
  `NOTARY_SUBMISSION_ID` continues that submission without an upload. The ticket only fits the same signed code.
- `app-release.yaml` passes the id from the manual input `notary-submission-id`.
  Only a run on a `refs/tags/v*` ref with a non-empty id signs, a branch with an id fails.
  An empty id keeps the ad hoc dry run.
- The entitlements file is empty on purpose, its comment gives the reasons. Add a key only with a documented
  reason in that comment.
  Not verified: whether the tap path needs `com.apple.security.device.audio-input` under the hardened runtime.
  0.1.0 already ran hardened without it.

## Bundle

- `bundle.sh` and `Resources/` build `dist/audio-router.app` (`task bundle`, `task bundle:verify`,
  `task bundle:zip`). Only the `AudioRouterApp` product goes in, never `audio-router-proto`.
- `task bundle:verify` is not in `task check`, the `bundle` CI job runs it.
- `bundle.sh` copies the menu bar PNGs into `Contents/Resources`, see `Resources/Branding/AGENTS.md`.

## Homebrew cask

- `render-cask.sh`, `publish-homebrew-cask.sh` and `audit-cask.sh` are the Homebrew cask.
- The `homebrew` job of `app-release.yaml` renders `Casks/audio-router.rb` from the hash of the published zip
  and pushes it to `ostendorf-cloud/homebrew-tap`.
- The cask is generated: never edit it in the tap, change the render script.
- Each script has a `_test.sh` with a fake `gh` or `brew`, run by `task test:cask`.

## Macro lint

- `lint-swiftui-macros.sh` (`task lint:swiftui-macros`, CI job `swiftui-macros`) fails with file, line and reason
  when `Sources` holds a macro whose plugin ships with Xcode only. The list sits at the top of the script.
- Extend the list when a new SDK adds a macro from a plugin the Command Line Tools lack.
  Find them with `grep -rn externalMacro` in the swiftinterface files of every framework under
  `/Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk/System/Library/Frameworks`.
  Macros of frameworks the app does not import, such as SwiftData or AppIntents, are not listed yet.
- It is a line check that drops `//` comments only. A macro name in a block comment or string fails closed.
  A name matches only with its sigil and as a whole word, so `@StateObject` or the type `Predicate` pass.
- Two contrived spellings escape it: a backticked name such as ``@`State` ``,
  and code after a string that holds `//` on the same line.
- `lint-swiftui-macros_test.sh` runs it on temporary trees, and the task runs that test first.
- CI builds with Xcode, so the `build` job does not catch a macro. Only this lint does.
