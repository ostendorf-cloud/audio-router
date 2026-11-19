# Prototype findings

Template for phase 1. The owner fills the result fields from a real Mac.
Nothing here is measured yet. An empty field means not tested.
The questions come from the open questions of `docs/concepts/audio-router.md`.

## Setup

- Date:
- Commit of the build:
- macOS version and build:
- Mac model:
- Swift toolchain (`swift --version`):
- Output device under test (uid from `devices`):
- Terminal app that ran the command:

Build and run:

```sh
swift build -c release
.build/release/audio-router-proto devices
.build/release/audio-router-proto apps
.build/release/audio-router-proto route --bundle-id <id> --device <uid> --channels 3,4
```

## 1. Permission flow

The usage string `NSAudioCaptureUsageDescription` is embedded in the binary through the linker
section `__TEXT,__info_plist`. Check it first:

```sh
otool -s __TEXT __info_plist -v .build/release/audio-router-proto | head -20
```

- Does the permission prompt appear on the first `route`: <!-- yes / no -->
- Which name does the prompt show, the terminal app or `audio-router-proto`:
- Is the usage string from the embedded plist shown, or the terminal app's own:
- What happens after the user denies it (error text, exit code, or silence):
- Does a denied tap fail with an OSStatus, or does it deliver zeroed audio:
- Does the error text of the tool point to the right place in System Settings:
- What changes when the tool runs from a terminal that has no usage string:
  `Terminal.app` and `iTerm.app` have no `NSAudioCaptureUsageDescription` in their `Info.plist`
  (checked on the development Mac), `Claude.app`, `Discord.app` and `Visual Studio Code.app` have one.
- Which app does System Settings list under the audio capture permission after the first run:
- If the permission is missing, does the tool print the silence warning after 10 seconds
  ("no audio arrived in 10 seconds"):
- Does a paused app trigger the same warning (expected: yes, it cannot tell the two apart):

## 2. Latency added by the route

Method: play a click track in the app, record the app's normal output and the routed output on
the same interface, compare the offset in a DAW. Repeat for several buffer sizes.

| Device | Sample rate | Buffer size | Added latency (ms) | Notes |
| ------ | ----------- | ----------- | ------------------ | ----- |
|        |             |             |                    |       |
|        |             |             |                    |       |

- Goal from the concept: low milliseconds. Reached:
- Does `kAudioSubTapDriftCompensationKey` change the result:

## 3. Muted tap, system volume and AirPods handover

The tap uses `CATapMutedWhenTapped`, not `CATapMuted`. The header says the app plays normally until
a client reads the tap, and is silent on its normal output while the read goes on. The choice makes
every failure where the IO proc stops but the tap lives fail open (audible) instead of silent.
It supersedes the plain muted tap of the first concept. Questions from the concept:

- With `mutedWhenTapped`, is the app silent on the system output while `route` runs (it must be):
- Is the app audible again on the system output after `route` stopped (it must be):
- While `route` is suspended with `kill -STOP <pid>` (the tool ignores `SIGTSTP` for this reason, but
  `SIGSTOP` cannot be ignored), is the app audible or silent:
- Does the app flash audible at the start before the muting begins:
- Does the tapped app disappear from the system volume and from the Control Center audio list:
- Ctrl-C during a slow start, for example while the permission prompt is open: Core Audio calls
  cannot be cancelled. The tool prints a notice, then stops as soon as the start returns. If it
  hangs, kill it with `kill -KILL <pid>`. Is the app audible and is a tap or aggregate device
  left behind after that:
- Does the app play normally again right after `Ctrl-C`:
- Does it play normally again after `kill -TERM` and after `kill -HUP` (or closing the terminal window):
- Does `Ctrl-Z` do nothing (it is ignored on purpose):
- Does it play normally again after `kill -KILL` (no teardown can run):
- Is a tap or an aggregate device left behind after `kill -KILL`:
- AirPods handover (a call app or another Apple device takes the AirPods): does the tapped
  app still route:
- Does changing the system output volume change the routed level:

## 4. Helper processes under the parent bundle id

Run `apps` while the app plays and record what it lists.

| App | Bundle ids listed by `apps` | Grouped under the parent as expected |
| --- | --------------------------- | ------------------------------------ |
| Google Chrome |  |  |
| WebEx |  |  |
| Slack or another Electron app |  |  |
| Safari |  |  |
| Spotify |  |  |

- Does `route --bundle-id <parent>` capture the audio of the helper that plays:
- Does an app that starts a new helper after `route` started keep playing normally on its own
  output, as expected without the process watcher (phase 2):
- On macOS 26 and later: does `CATapDescription.bundleIDs` cover helper processes:
- Helper processes that start after `route` started are not tapped in phase 1 (the process watcher
  is phase 2). Which helpers did start late and kept playing on the normal output:

## 5. Several target devices

The prototype routes one app to one device per run. Run two instances at once.

```sh
.build/release/audio-router-proto route --bundle-id <idA> --device <uidA> --channels 1,2
.build/release/audio-router-proto route --bundle-id <idB> --device <uidB> --channels 1,2
```

- Do two private aggregate devices on two different devices run together:
- Do two apps routed to different channel pairs of the same device run together:
- Any glitch, dropout or clock drift after 30 minutes:
- Is the target device removed during the run handled cleanly (unplug it):

## 5b. Target device with its own inputs

The target device is a sub device of the aggregate, so its input channels join the aggregate's input
buffer list. The headers do not say in which order the streams come. The tool finds the tap by its
buffer shape and refuses when the shape is ambiguous. Test with a device that has inputs, for example
an X32 with 32 inputs, and make sure no input signal reaches the output.

- Input buffer layout of the aggregate with that device, for example `[32, 2]` or `[2, 32]`
  (`route` prints it on success as `aggregate input buffers: ... tap in buffer N`, the refusal
  message lists the buffers when it is ambiguous):
- Tap format as printed (`tap format:` line, interleaved or not):
- Did `route` start, or did it refuse with "Cannot tell the tap from the input channels":
  Reported by the owner from the first run, X32 over USB with 32 channels: it started, so the
  shape check passed. The layout itself was not printed yet, take it from the next run.
- With a signal on the device inputs and silence in the app: is the routed output silent:
- With a device whose input is one stereo stream (same shape as the tap, layout `[2, 2]`): refused
  as expected, the message names the device and the layout. Phase 1 does not handle this case,
  it has to be solved before phase 2:
- A non interleaved tap is handled (one buffer per channel, shape `[1, 1]`) and covered by unit
  tests. Did any run report `not interleaved`:
- Do all streams of the aggregate pass the 32 bit float check ("not 32 bit float" error otherwise):

## 6. Lowest macOS version

The API floor from the SDK headers is macOS 14.2 for `AudioHardwareCreateProcessTap`.
Test on the oldest macOS you can reach.

| macOS version | `devices` | `apps` | `route` | Notes |
| ------------- | --------- | ------ | ------- | ----- |
|               |           |        |         |       |

- Lowest version that works:
- Anything that behaves differently between versions:

## 7. Real time path

The IO proc must not allocate, lock or log. The code is `ChannelMapper.render`. Repeat the
disassembly check on a release build:

```sh
otool -tV .build/release/audio-router-proto \
  | awk '/ChannelMapperO6render.*:$/{p=1;print;next} p&&/^[_$].*:$/{exit} p' \
  | grep -E "\bbl\b"
```

- Calls found other than trap calls (expected: none):
- Dropouts at the smallest buffer size the device offers:
- Measured CPU load of the process while routing:

## 8. Other observations

- Channel numbering on the device matches the labels of the mixer:
- A device with several output streams: pair across a stream boundary works:
- Anything else the concept should change:

## 9. Level difference

Reported by the owner from the first run (X32 over USB, `route --bundle-id com.spotify.client`
to channels 1,2 and 3,4): the routed app is clearly quieter than before routing, on both pairs,
with the X32 strips unchanged. The X32 channel meters read about -21 dB on the USB returns.
The cause is not known. `ChannelMapper.render` copies samples at unity gain (read in the code),
and `CATapDescription.h` says nothing about the gain of a stereo mixdown.

Measurement with the meter. Use release builds. The meter prints to stdout once a second, the
reading covers the interval before the last one.

```sh
.build/release/audio-router-proto route --bundle-id com.spotify.client --device <uid> --channels 1,2 --meter
```

1. Note the lines printed at start: `tap format`, `sample rate` and the buffer layout.
2. Play a steady signal at fixed app volume. A music track is fine for a first look. For the
   separation below use a sine file of known level (for example 1 kHz at -6 dBFS) in an app that
   plays it without normalization. Keep the app volume and the system volume unchanged during one run.
3. Read `tap peak` and `tap rms` (what the IO proc received) and `out peak` and `out rms` (what it
   wrote). Compare them with the channel meter of the X32 return.
4. Stop `route`. Play the same signal directly on the X32 (default output on the same channels)
   and note the X32 meter again. Same app volume, same system volume.

| Signal | App volume | System volume | tap peak | tap rms | out peak | out rms | X32 meter routed | X32 meter unrouted |
| ------ | ---------- | ------------- | -------- | ------- | -------- | ------- | ---------------- | ------------------ |
|        |            |               |          |         |          |         |                  |                    |
|        |            |               |          |         |          |         |                  |                    |

- Printed sample rates (tap, aggregate, device) and the effective rate (`frames` per line):
- Does `tap` equal `out` in every line (it must, the copy is unity):

Candidate causes. None is excluded without a measurement. The table says which measurement
separates them.

| Candidate | Measurement that separates it |
| --------- | ----------------------------- |
| The stereo mixdown of the tap changes the level | Play the sine file of known level. If `tap peak` differs from the file level at app volume 100 percent and no normalization, the tap changes it. If it matches, the tap is not the cause. |
| The app applies its volume before the tap | Move the app volume slider. If `tap` follows it, the volume is applied before the tap, which is expected. Then compare with the unrouted run at the same slider position. |
| The system output volume is applied after the tap | Change the system output volume. If the unrouted X32 meter follows it and `tap` does not, the unrouted path had a gain that the routed path lacks. |
| Sample rate conversion or a rate mismatch | Compare the three printed rates and the effective rate. Equal rates do not exclude a converter inside the tap, but a level change from conversion alone is not expected. A mismatch would call for a run with the device set to the tap's rate. |
| Trim or meter reference on the X32 USB return | Compare `out` with the X32 return meter for the same signal. If `out` matches the file level and the X32 reads about -21 dB, the loss is on the X32 side and the unrouted path would read the same. |
| The two runs differ in Spotify settings | Spotify has its own volume and a normalization setting. Keep both fixed between the routed and the unrouted run. |

Reading the result:

- `tap` below the file level: the loss happens before the IO proc (mixdown, app volume or rate).
- `tap` at the file level, `out` equal to `tap`, X32 meter lower: the loss is after the IO proc, on the device side.
- `out` below `tap`: the copy loses level, which would be a bug in `ChannelMapper`.
