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

## License

Apache-2.0, see [LICENSE](LICENSE).
