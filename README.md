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

- Download `audio-router-<version>-arm64.zip` and its `.sha256` file from the GitHub release.
- Put both files in one folder and verify the download:

  ```sh
  shasum -a 256 -c audio-router-<version>-arm64.zip.sha256
  ```

- Unzip the file and drag `audio-router.app` to `/Applications`.
  Expected: the app appears in `/Applications`. Not verified.
  Running it from another folder is not verified.
- The app is signed ad hoc and not notarised.
  Notarisation needs a Developer ID Application certificate from the paid Apple Developer Program.
  That certificate does not exist yet.
- Gatekeeper is assumed to block the first open. Not verified.
  Open the app in one of these ways. Each way is not verified.
  - Right click the app, choose Open, then confirm. Assumed, not verified.
  - System Settings, Privacy & Security, then Open Anyway. Not verified.
  - In a terminal: `xattr -dr com.apple.quarantine /Applications/audio-router.app`. Not verified.
  - Expected after any way: the speaker icon appears in the menu bar. Not verified.
- Each new release may ask for the audio capture permission again, until a Developer ID exists.
  Not verified.

## Use

- After the first open a speaker icon appears in the menu bar.
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
  - Off: the Routing toggle is off.
  - Running: routing is on and nothing needs attention.
  - Warning: a route runs with a warning or waits for its device.
  - Error: a route failed or the engine could not start.
- The menu has a Routing toggle, one toggle per route and Quit.
  - Each route shows its state and, while the menu is open, live levels as text.
  - An issue shows a message and a button, for example open System Settings or retry.
- Start at login is a toggle in Settings under Startup.
  The login item with an ad hoc signed app is not verified.
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
  - `task bundle` builds `dist/audio-router.app`, arm64, ad hoc signed.
  - `task bundle:verify` checks the plist, signature, architecture and that the prototype is absent.
  - `task bundle:zip` writes `dist/audio-router-<version>-arm64.zip`.
- The release workflow `app-release.yaml` attaches the zip and its `.sha256` file to a published release.
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
