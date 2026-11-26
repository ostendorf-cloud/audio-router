# audio-router-proto

The command line diagnostic tool. It is not part of a release. Flags come from `--help`.

## Route behaviour

- Channels count from 1 and must be two adjacent channels.
- `--tap-mode device-stream` (the default) taps output stream 0 of the device without the stereo mixdown.
- `--tap-mode stereo-mixdown` loses 24 dB on a 32 channel device (measured), see `docs/prototype-findings.md`
  section 9.
- `--source-channels` names the tap channels that carry the app (default 1,2).
- `--tap-buffer` forces the tap buffer (from 0). Without it the tap stream is found by the stream id diff.
- About two seconds after the first signal, or when the wait for a signal ends silent, the route prints the
  signal line and, through `TapCheck`, a warning when the tap side shows channels outside `--source-channels` or
  none while a device input is active.
  It is a warning, never a refusal, and it does not check the gain: `--meter` does that.
- When the wait ends silent the tap check runs first (`TapCheck.silentWait`).
- Signal outside `--source-channels` prints the specific warning only.
- No tap signal with a device input active prints it plus one short permission sentence.
- Nothing active prints the full permission warning only.
- `--meter` prints peak and RMS in dBFS of the tap and the output to stdout once a second.
  `ChannelMapper.measure` runs next to `render` in the IO proc with the same real time contract.

## Signals

- `SIGTSTP` is ignored on purpose, a suspended process cannot tear down. The code sits in `AudioRouterProto.swift`.

## Info.plist

- The usage string for the system audio capture permission lives in `Info.plist` next to these sources under
  `NSAudioCaptureUsageDescription`.
- `Package.swift` embeds it with the linker flags `-sectcreate __TEXT __info_plist <path>`.
- Check it with `otool -s __TEXT __info_plist -v .build/debug/audio-router-proto`.

## Run on a real Mac

Agents cannot do this, see the root file. The owner runs, with an app that plays audio and an output device with
several channels:

```sh
swift build -c release
.build/release/audio-router-proto devices
.build/release/audio-router-proto apps
.build/release/audio-router-proto route --bundle-id <id> --device <uid> --channels 3,4
```

- Then the owner answers every field of `docs/prototype-findings.md`.
- Never fill that file with guesses.
- Ctrl-C must leave the app playing on its normal output again.
