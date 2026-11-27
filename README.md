# audio-router

Route the audio of single macOS apps to channel pairs of any output device.

## What it does

- A menu bar app. It has no Dock icon.
- A route sends one app to one stereo channel pair of an output device, for example channels 3 and 4 of a mixer.
- While a route runs, the app is silent on its normal output.
- Routes are stored and start again after an app restart or a device return.
  Start again after a login is not verified.
- Added latency and drift are not measured on the app yet, see the hardware checklist.
- Concept: [docs/concepts/audio-router.md](docs/concepts/audio-router.md).

### Limits

- A device stream route only holds audio that the app sends to the chosen device.
  The destination device must be the system default output.
- When the default output moves to another device, the route stops and waits.
  The app then plays on the new default output.
  The route resumes when the destination is the default output again.
- An app with its own output device, set in the app, loses a working route when the default leaves that device.
- No cross device routing, no device inputs as a source, no gain per route.
- Several routes at once on one device are not measured.
- A helper process that starts after a route started is not tapped until the route restarts.
  The app restarts the route by itself.
- Requires macOS 14.2 or later. That is the API floor of the process tap.
  The app is tested on macOS 27 only. Older versions are not tested.
- The release is arm64 only. There is no Intel build.

## Install

- With Homebrew:

  ```sh
  brew install --cask ostendorf-cloud/tap/audio-router
  ```

  - The cask needs an Apple silicon Mac with macOS 14 or later. The app itself needs 14.2.
  - The cask installs the release zip. A release built after the signing change is notarized, so Gatekeeper
    should not warn. Not verified until a notarized release ran. Releases up to 0.1.0 are ad hoc signed and warn.
  - Not verified: an install from the tap. The first cask reaches the tap with the first release after this change.
  - `brew uninstall --zap --cask audio-router` also removes the stored routes and the preferences.
    It cannot remove the login item registration. That stays in System Settings, Login Items.

- Without Homebrew, download `audio-router-<version>-arm64.zip` and its `.sha256` file from the GitHub release.
- Put both files in one folder and verify the download:

  ```sh
  shasum -a 256 -c audio-router-<version>-arm64.zip.sha256
  ```

- Unzip the file and drag `audio-router.app` to `/Applications`.
  Expected: the app appears in `/Applications`. Not verified.
  Running it from another folder is not verified.
- The release app is signed with a Developer ID Application certificate, notarized by Apple and stapled.
  - Expected: it opens on the first double click without the "Apple could not verify" warning.
    Not verified until the first notarized release ran.
  - Check a download in a terminal. Expected: `accepted` and `source=Notarized Developer ID`.

    ```sh
    spctl -a -vvv -t exec /Applications/audio-router.app
    ```

  - Releases up to 0.1.0 are ad hoc signed and not notarized. For them, and for a local build, see Development.
- The audio capture permission belongs to the signing identity, which stays the same from release to release.
  So the permission should persist across updates. Not verified.

## Use

- After the first open the audio-router symbol appears in the menu bar: a wave that splits into two lines.
- On the first route, macOS asks to allow audio capture.
  The prompt shows the usage text of the app. Which name it shows is not verified.
  - The app cannot read the permission status.
    With no audio it shows a likely cause and a button that opens System Settings.
  - The pane name differs by macOS version. Check it on your version. Not verified.
- Create a route:
  - Choose Settings in the menu, or press the comma key while the menu is open.
  - Under Routes choose Add route.
  - Choose the app, the destination device with a channel pair, and the source pair of the app.
  - Save. Switching a route on or off is a toggle in the menu. A save does not change that state.
- Set the destination device as the system default output. See the limits above.
- The menu bar icon shows one state for the whole app.
  - Off, the symbol with a slash: the Routing toggle is off.
  - Running, the plain symbol: routing is on and nothing needs attention.
    A route whose app plays nothing, for example a paused app, stays Running and shows a plain note.
  - Warning, a small triangle at the lower right: a route runs with a warning or waits for its device.
    Silence while the app plays is a warning, the capture permission may be missing.
  - Error, a small round mark at the lower right: a route failed or the engine could not start.
- The menu has a Routing toggle, one toggle per route and Quit.
  - Each route shows its state and, while the menu is open, live levels as text.
  - An issue shows a message and a button, for example open System Settings or retry.
- Start at login is a toggle in Settings under Startup.
  The login item is not verified, neither with the notarized release nor with an ad hoc build.
  If macOS needs an approval, the toggle shows a hint and a button that opens Login Items.
- Uninstall:
  - Quit the app from the menu.
  - Switch off Start at login in Settings, or remove audio-router in System Settings under Login Items.
    The removal in System Settings is not verified.
  - Delete `/Applications/audio-router.app`.
  - Delete the stored routes: `~/Library/Application Support/audio-router/routes.json`.
  - The audio capture permission entry stays in System Settings. Remove it there. Not verified.

## Development

- Build and test with `swift build` and `swift test`. `task check` runs everything CI runs.
- Building from source needs the Command Line Tools only, Xcode is not required.
  - The sources use no SwiftUI macro such as `@State`, `@Entry` or `#Preview`.
    Their compiler plugins ship with Xcode only, so the Command Line Tools cannot build them.
  - `task lint:swiftui-macros` checks that, and CI runs it.
  - Lines like `ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found`
    are harmless. SwiftPM passes search paths that this Command Line Tools install does not have.
  - Creating the directories may silence them. This is optional and not verified:

    ```sh
    sudo mkdir -p /Library/Developer/CommandLineTools/Developer/Library/Frameworks \
      /Library/Developer/CommandLineTools/Developer/usr/lib
    ```

- Build the app bundle:
  - `task bundle` builds `dist/audio-router.app`, arm64, signed ad hoc with the hardened runtime.
  - With `SIGNING_IDENTITY="Developer ID Application: <name> (<team id>)"` it signs with that identity and a
    secure timestamp instead. `SIGNING_KEYCHAIN` names the keychain, `SIGNING_REQUIRED=true` forbids the ad hoc
    fallback. See `scripts/sign-app.sh`.
  - `task bundle:verify` checks the plist, signature, hardened runtime, entitlements, architecture and that the
    prototype is absent. `VERIFY_SIGNATURE=developer-id` adds the Developer ID chain and the timestamp,
    `VERIFY_SIGNATURE=notarized` adds `spctl` and `stapler validate`. See `scripts/verify-signature.sh`.
  - `task bundle:zip` writes `dist/audio-router-<version>-arm64.zip` and verifies the signature of the unzipped copy.
  - `task bundle:notarize` submits the zip with `notarytool` and staples the app. It needs the `APPLE_NOTARY_*`
    variables of `scripts/notarize.sh`. Run `task bundle:zip` again afterwards.
  - `task test:signing` tests the signing scripts offline with fake tools.
- A local ad hoc build is not notarized. Gatekeeper is assumed to block it when it carries the quarantine flag,
  for example after a download. Open it in one of these ways. Each way is not verified.
  - Right click the app, choose Open, then confirm.
  - System Settings, Privacy & Security, then Open Anyway.
  - In a terminal: `xattr -dr com.apple.quarantine /Applications/audio-router.app`.
  - A new ad hoc build may ask for the audio capture permission again. Not verified.
- The release workflow `app-release.yaml` signs, notarizes and staples the app on a published release.
  Then it attaches the zip and its `.sha256` file to the release.
  - The secrets and the variable it needs are listed in `AGENTS.md`.
  - Its `homebrew` job then pushes `Casks/audio-router.rb` to `ostendorf-cloud/homebrew-tap`.
    `scripts/render-cask.sh` renders the cask, `scripts/publish-homebrew-cask.sh` verifies the zip and pushes it.
  - To push the cask of a published release again, run `app-release.yaml` by hand on `main` with `cask-tag` set.
    The `verify-asset` job checks the asset of that tag first.
    A tag without a notarized asset, such as v0.1.0, fails the check and gets no cask.
  - `task test:cask` tests the cask scripts offline. `task lint:cask-audit` runs `brew audit` and `brew style`.
    It taps a scratch tap, so only CI runs it.
- Open questions and measurements: [docs/prototype-findings.md](docs/prototype-findings.md).
- What the owner checks by hand before a release: [docs/hardware-checklist.md](docs/hardware-checklist.md).
- Rules for contributors and agents: [AGENTS.md](AGENTS.md).

### Diagnostic tool

- `audio-router-proto` is a command line tool for diagnosis.
  It stays in the repository and is not in the release zip. Build it from source:

  ```sh
  swift build -c release
  .build/release/audio-router-proto devices
  .build/release/audio-router-proto apps
  .build/release/audio-router-proto route --bundle-id <id> --device <uid> --channels 3,4
  ```

- `devices` lists output devices with uid, name and channel count.
- `apps` lists audio processes, helper processes grouped under their parent app.
- `route` mutes the app on its normal output and plays it on the channel pair until Ctrl-C.
- `route` prints a warning to stderr when the signal sits outside `--source-channels` or the tap
  shows none while a device input is active. It names the picked tap buffer and how it was picked.
  It does not check the gain, use `--meter` for that. Use `2>&1` to log both streams.
- `route` prints the system audio capture permission warning after 10 silent seconds only when the
  tap shows no signal on any channel. With signal on other tap channels it prints the tap warning
  alone.

## License

Apache-2.0, see [LICENSE](LICENSE).
