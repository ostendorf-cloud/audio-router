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
  (print it by running `route`, the refusal message lists the buffers when it is ambiguous):
- Did `route` start, or did it refuse with "Cannot tell the tap from the input channels":
- With a signal on the device inputs and silence in the app: is the routed output silent:
- With a device whose input is one stereo stream (same shape as the tap): refused as expected:
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
