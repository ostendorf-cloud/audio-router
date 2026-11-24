# audio-router

Route the audio of single macOS apps to channel pairs of any output device.

## Status

- Phase 1, a command line prototype. Not usable as an app yet.
- Needs macOS 14.2 or later and the system audio capture permission.
- Concept: [docs/concepts/audio-router.md](docs/concepts/audio-router.md).
- Open questions and measurements: [docs/prototype-findings.md](docs/prototype-findings.md).

## Usage

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

## Releases

- Each release carries `audio-router-<version>-arm64.zip` and a SHA-256 file.
- The app is signed ad hoc and not notarised.
  Notarisation needs a Developer ID Application certificate from the paid Apple Developer Program.
  That certificate does not exist yet.
- Gatekeeper blocks the first open, and each new release may ask for the system audio capture permission again
  until a Developer ID exists.
- The app cannot read the permission status. It shows a likely cause when no audio arrives and a button that opens
  System Settings.
- To open the app past Gatekeeper, use one of these two ways.
  - System Settings, Privacy & Security, then Open Anyway.
  - In a terminal: `xattr -dr com.apple.quarantine <path to the app>`.
- To verify the download, put the zip and the `.sha256` file in one folder and run:

  ```sh
  shasum -a 256 -c audio-router-<version>-arm64.zip.sha256
  ```

## License

Apache-2.0, see [LICENSE](LICENSE).
