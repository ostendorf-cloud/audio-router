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
  Reported by the owner, X32 over USB with 32 channels: it started, so the shape check passed.
  The layout printed was `[32, 2]` with the tap in buffer 1.
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
The cause was not known at that point. `ChannelMapper.render` copies samples at unity gain (read
in the code), and `CATapDescription.h` says nothing about the gain of a stereo mixdown. The
measurement below found it.

Reported by the owner from later runs with `--meter` (X32, Spotify and Chrome, both with the X-USB
as macOS default output): layout `[32, 2]` with the tap in buffer 1, all rates 48000 Hz, `tap`
equal to `out`, and a `tap` peak of only about -30 to -33 dBFS (rms about -43 dBFS) for both apps.
So the loss happens before the IO proc, and it is the same for two different apps.

### Measured: the stereo mixdown tap loses 24.1 dB

Measured by the owner on macOS 27 with the X32 over USB (uid
`AppleUSBAudioEngine:BEHRINGER:X-USB:21B4A92B:1,2`, 32 channels, 48 kHz, default output of macOS).
QuickTime Player played a 1 kHz sine at -6 dBFS (`sine-1khz-minus6dbfs.wav`, not stored in this
repository). `route --meter` printed `tap peak` -30.1 dBFS and `tap rms` -33.1 dBFS. That is
-24.1 dB, a division by 16: 32 channels as 16 pairs. The copy to the output is unity (`tap` equals
`out`). The aggregate layout was input buffers `[32, 2]` and output buffers `[32]`. The tap was in
input buffer 1, which was found by measurement. No header defines that order.

Why: `CATapDescription(stereoMixdownOfProcesses:)` makes a description with `isMixdown` true and
`isMono` false (checked by creating the description in a scratch Swift file, no tap, no hardware).
`CATapDescription.h` says a mixdown is "a mono or stereo mix of the tapped device's channels" and
gives no gain. No property of `CATapDescription` sets a gain. `mono` switches to one channel,
`exclusive` inverts the process list into "all except", and `mixdown` is a read and write flag with
no further text. So the loss cannot be tuned in the description. The measured 1/16 is consistent
with a mix of all device channels that divides by the number of pairs. That reading is a
hypothesis, only the 24.1 dB is measured. A stereo device is expected to be unity under the same
hypothesis, and the MacBook speaker run below tests that.

### Fix: the device stream tap

`CATapDescription(processes:deviceUID:stream:)` taps one output stream of the device. The Swift
overlay signature is `init(processes: [AudioObjectID], deviceUID: String, stream: UInt)`, proven by
compiling a scratch file with `swiftc` against the SDK (the header calls it
`initWithProcesses:andDeviceUID:withStream:`). The resulting description has `isMixdown` false,
`deviceUID` and `stream` set.

What the header says (`CATapDescription.h`, the method comment and the `stream` property):

- "Mix all given process audio streams destined for the selected device stream".
- `stream` is "NSInteger that represents the index of the stream on the device whose audio will be
  captured. The format of the tap will match the format of this stream."
- The property `stream` says "the index of the hardware stream".

What the header does not say, so it is not verified:

- Which scope the index counts in. The tool uses index 0 and the X32 has one output stream.
- That the tap then has 32 channels. The format rule implies it, the first run must show it in
  the `tap format` line.
- That the app's stereo lands on tap channels 1 and 2. A process plays on the device's default
  channel pair, but no header text says so. The route prints the tap channels that carried signal
  two seconds after the first signal, and `--source-channels <n>,<n+1>` (default 1,2) names the
  pair to copy.
- That the gain is unity. The header says nothing about gain, in either mode.

The header evidence for unity was not solid, so the first version kept `stereo-mixdown` as the
default. The owner then measured it (see the results below): `device-stream` reads unity on the
X32. `device-stream` is now the default (`TapMode.standard`) and `stereo-mixdown` stays as the
alternative. Both modes run with the same command:

```sh
.build/release/audio-router-proto route --bundle-id <id> --device <uid> --channels 1,2 --meter --tap-mode stereo-mixdown
.build/release/audio-router-proto route --bundle-id <id> --device <uid> --channels 1,2 --meter --tap-mode device-stream
```

### Telling the tap from the device inputs

A 32 channel tap next to 32 device inputs has the same buffer shape, so the shape alone is
ambiguous. Checked in the headers, none names the tap's stream:

- `kAudioDevicePropertyIOProcStreamUsage` (`AudioHardware.h`) switches the streams an IO proc
  receives on and off by index, an unused stream shows as a NULL buffer pointer. It needs the
  index of the tap stream as input, it does not name it.
- `kAudioAggregateDevicePropertyTapList` lists the tap uids and `kAudioSubTapUIDKey` is the key of
  a tap in the description. Neither lists streams.
- `kAudioAggregateDevicePropertyFullSubDeviceList` says the order of the sub devices decides the
  order of the streams. It says nothing about taps.
- `kAudioObjectPropertyOwnedObjects` and `kAudioObjectPropertyOwner` exist for every object. No
  header says that the stream of a tap is owned by the tap. Not tried on hardware.

So there is no documented way to name the tap stream, and nothing is claimed as proven. What the
code does instead (`ChannelMapper.chooseTapBuffers`):

1. One buffer of the tap shape: that one. As before.
2. Several buffers of the tap shape, and the layout can tell the order: the last one. This needs
   the aggregate's input list to be exactly the device's own input buffers (read from the device
   itself) followed by the tap shape, and that list to differ from the tap shape followed by the
   device inputs. Example: device `[2, 32]` and tap `[32]` give `[2, 32, 32]`, tap first would be
   `[32, 2, 32]`. What this proves: the layout excludes the other order, assuming the aggregate
   lists its parts one after the other. What it does not prove: anything about the content of
   the buffers.
3. Several buffers of the tap shape and the device inputs have the tap shape too (device `[32]`
   and tap `[32]`, the X32 with a 32 channel tap): both orders give `[32, 32]`, so the layout
   proves nothing. The route refuses and asks for `--tap-buffer <n>`. The measured order on the
   X32 is the tap in buffer 1 with the stereo mixdown tap (`[32, 2]`), so `--tap-buffer 1` is the
   measured order. Whether the 32 channel tap lands in buffer 1 too is the first thing the run
   must show.
4. Anything else with several matches: refused, as before.
5. `--tap-buffer <n>` forces the first tap buffer (counted from 0). The shape found there must
   equal the tap shape, otherwise the route refuses. It is printed as `named by --tap-buffer`.

The route prints which channels carried signal, split into tap channels and device input channels
(`signal on tap channels: ... | on device input channels (noise counts): ... | device preferred
stereo pair: ...`). The flags are sticky and any non zero sample counts, so preamp noise lights
device input channels. Read it like this, with the -6 dBFS sine playing in QuickTime:

- RIGHT: the tap side shows exactly `1,2`. The device side shows anything (noise).
- WRONG: the tap side shows 32 channels or channels other than `1,2`, or the tap side is `none`
  while `tap peak` is not `-inf`. Then the buffer is a device input. Stop, try the other
  `--tap-buffer`.

This is a diagnostic for the owner, the tool does not refuse on it. `device preferred stereo
pair` is `kAudioDevicePropertyPreferredChannelsForStereo` of the target device (output scope), for
information only, not used as a default.

### Probes for an order free choice

In `device-stream` mode the route prints read only probes (`probe:` lines). They never decide and
never throw, an error prints `not available`:

- For each aggregate input stream, `kAudioObjectPropertyOwner` (`AudioHardwareBase.h`).
- For the tap object, `kAudioObjectPropertyOwnedObjects`.
- Whether `kAudioAggregateDevicePropertyTapList` is settable (`AudioObjectIsPropertySettable`).

Look for a stream ID that appears in the tap's owned objects, or an owner of a stream that equals
the tap object ID. That would name the tap's stream and allow an order free choice. It is
evidence only.

Measured by the owner on the X32 (device-stream, `--tap-buffer 1`): aggregate object 237, tap
object 236, input streams `239,240`, both streams owned by 237 (the aggregate), the tap owns no
objects, the aggregate tap list is settable. So the tap does not own its stream and no owner
relation names it. The settable tap list led to the stream id diff below.

### Stream id diff (order free choice)

`createAggregate` creates the aggregate with the sub device only and reads
`kAudioDevicePropertyStreams` (input scope, IDs A). It then sets
`kAudioAggregateDevicePropertyTapList` (a CFArray of the tap uid, the type in `AudioHardware.h`),
and reads the streams again (IDs B). The one new ID is the tap's stream. Drift compensation is
skipped in `device-stream` mode (see the second run below), the composition key for it is not
available when the list is set afterwards.
`ChannelMapper.tapBufferByStreamDiff` checks: exactly one new stream, the old streams keep their
order, the channels per stream equal the buffer list, the new stream has the tap's channel count,
the tap is interleaved. Its index in B is the tap buffer. The route prints `tap buffer: by stream
id diff` and a `stream id diff:` line with the lists.

Any failure (an error, no new stream, several, a mismatch, a non interleaved tap) is not fatal:
the route falls back to the rules above, which refuse a symmetric layout and need `--tap-buffer`.
If setting the tap list fails, the aggregate is destroyed and created again with the tap in its
composition, as before. A failed drift compensation set only logs and does not stop the diff.
`--tap-buffer <n>` always wins.

First run of this method on the X32 (without `--tap-buffer`): the route was refused as ambiguous
and printed no `stream id diff:` line, because the diagnostics were only printed on success and the
failure of the diff step was swallowed. Now every step prints (`stream id diff step:` lines:
aggregate created with the sub device only and streams A, tap list set with its OSStatus, sub taps,
drift property with its OSStatus, streams B after the wait) and the outcome line `stream id diff:
used, tap at index k` or `not used (reason)` always appears, also before a refusal, and the
refusal text carries it. The header (`AudioHardware.h`) describes `kAudioAggregateDevicePropertyTapList`
only as a CFArray of tap UUID strings and says nothing about the dictionary form, the scope, a
stopped device or an asynchronous stream list. The streams are therefore polled for up to 1 s in
steps of 50 ms after the tap list was set.

Second run: streams A were `[239]`, the tap list set returned OSStatus 0 and the aggregate had one
sub tap (4403). Setting `kAudioSubTapPropertyDriftCompensation` on 4403 failed with 560947818
(`!obj`, bad object), which aborted the diff. Now the drift step is skipped in `device-stream`
mode: the tap is of the output stream of the same device that is the aggregate's main sub device,
so there is one hardware clock. This is reasoning, not header text: `AudioHardware.h` says only
that `kAudioSubTapDriftCompensationKey` means "drift compensation is enabled for the AudioSubTap"
and does not say for which clock. No long run was measured, so drift over time is not excluded.
The stereo mixdown keeps the tap in the composition with the drift key. A failed drift set no
longer stops the diff. A `kAudioObjectPropertyClass` step line names the class of the aggregate,
the tap and the sub tap, to explain the bad object.

What is not proven. The header does not say that the buffers of the IO proc follow the order of
`kAudioDevicePropertyStreams`, and it does not describe the order of operations (tap list set
while the aggregate exists and is stopped, whether stream IDs of the sub device stay). The channel
count check cannot tell two streams with the same count apart, as on the X32 (`[32, 32]`). Only
a run proves the index. Measured on the X32 without `--tap-buffer`: streams A `[239]`, tap list
set with OSStatus 0, sub tap `[4446]` (its class is not available, the id is not a settable
object), drift skipped, streams B after 0 ms `[239, 241]`, `stream id diff: used, tap at index 1`,
`tap buffer: by stream id diff`, `tap peak` -6.0 dBFS, rms -9.0 dBFS, signal on tap channels
exactly `1,2`. That is the same buffer the `--tap-buffer 1` run used. This proves it for one
device only. Not measured: the -20 dBFS file, the MacBook speakers or any other stereo device, a
long run for drift, a device with several input streams.
Not testable here: the Core Audio calls (the tests cover the decision logic with fakes).

Other limits, stated plainly:

- The stream index scope is undocumented (input and output streams, or output only), and so is
  the behaviour of an index that is out of range. Only index 0 is used.
- The activity flags are written by the audio thread and read by the control thread without
  synchronisation, a formal data race like `signalSeen`. They are a diagnostic only.
- A device stream tap only holds audio that goes to the target device (header: "destined for the
  selected device stream"). If the app plays to another output device, the tap is silent. This is
  a limit of the mode: it works only when the app already plays to the target device. The 10
  second silence warning says so in this mode and names the device.
- The header text of the stream initializer calls its `processes` the ones "to exclude". That
  looks like a copy paste. The route reads `isExclusive` back, prints it next to `isMixdown`
  (`tap description:`) and refuses to start when it is true in this mode.

The tap warning. The assumption that the IO buffers follow the order of the stream list is
measured on one device only, and for a symmetric layout such as `[32, 32]` or `[2, 2]` nothing in
the buffer shapes can contradict it. About two seconds after the first signal the route prints the
signal line and, when it looks wrong, a line starting with `warning: tap buffer`. It never stops
the route. A multichannel app is legitimate and noise on a device input counts as activity, so a
refusal would be wrong.

The check runs about two seconds after the first signal. When no routed channel ever carries a
sample, it runs once after 10 seconds, before the generic no audio warning, and the generic
warning depends on the result:

- Signal on tap channels outside `--source-channels`: the specific warning only. Capture works,
  so the permission hint would name a wrong cause. Measured in run 3 below: the permission
  warning came first and was misleading, that order was the defect.
- No signal on the tap, a device input active: the specific warning, then one short sentence
  that the capture permission may also be missing.
- Nothing active: the generic no audio warning with the permission hint only.

That is the case of a wrong buffer or an app on another pair, silent on the source pair. The
warning goes to stderr and the signal line to stdout, so use `2>&1` when both go to a log.

The warning does not detect the 1/16 gain loss of a stereo mixdown tap (see the measurement
above). It checks where the signal sits, not how loud it is. Check the gain with `--meter`.

The warning fires in two cases:

- The tap side of the signal line shows channels outside `--source-channels` (default 1,2). Either
  the app plays on another pair, or the picked buffer is not the tap.
- The tap side shows none while the device input side shows activity. The picked buffer may be a
  device input.

It names the picked buffer, how it was chosen (`stream id diff`, `--tap-buffer`, or by layout) and
the retry flags. How to read it:

- Signal line `signal on tap channels: 1,2 | on device input channels (noise counts): ...` and no
  warning: the pick matches the source pair. This is the X-USB result.
- Warning with tap channels outside the pair: look at the channels it names. If they are the pair
  the app should use, retry with `--source-channels <a>,<b>`. If the tap side looks like device
  noise (for example `1,2,3,31,32`), the buffer is wrong: retry with `--tap-buffer <n>` for each
  other buffer of the tap shape in the `aggregate input buffers` line.
- Warning with no signal on the tap: the app may not play to the target device (device stream mode
  only taps audio that goes there), or the buffer is wrong. Check the macOS default output first.
- No warning is not proof. An app that writes only inside the pair on a wrong buffer that carries
  device noise inside the pair looks the same as a right pick.

Measured on 2026-11-19 on the owner's Mac, branch `feat/11-tap-warning` at 74557ae, release
build. Device X-USB (BEHRINGER), 32 channels, 48000 Hz. App `com.spotify.client` playing music,
output routed with `--channels 3,4`. The music is not the calibration tone, so no level in this
table is a gain check.

| Run | Command (options) | Tap buffer | Source channels | Warning printed | Observed lines |
| --- | ----------------- | ---------- | --------------- | --------------- | -------------- |
| 1, right pick | `--meter` | 1, by stream id diff (`aggregate input buffers: [32, 32], tap in buffer 1`) | 1,2 (default) | no (expected: none) | `signal on tap channels: 1,2 \| on device input channels (noise counts): 1,2,3,5,6,31,32 \| device preferred stereo pair: 1,2`. Meter: `tap` and `out` peak identical on every line, peak -23.3 to -31.9 dBFS, rms -35.0 to -45.7 dBFS |
| 2, forced wrong buffer | `--tap-buffer 0` | 0, by `--tap-buffer` (the stream id diff still found index 1) | 1,2 (default) | yes (expected: yes) | `signal on tap channels: 1,2,3,5,6,31,32 \| on device input channels (noise counts): 1,2 \| device preferred stereo pair: 1,2`, then `warning: tap buffer 0 was picked by --tap-buffer: signal on tap channels 3,5,6,31,32, outside --source-channels 1,2. ...`. The owner heard their microphone on output channels 3 and 4: buffer 0 is the device input, not the app |
| 3, source pair the app does not use | `--source-channels 3,4` | 1, by stream id diff (the correct buffer) | 3,4 | yes, in the wrong order at 74557ae: first the generic `warning: no audio arrived in 10 seconds ... the system audio capture permission may be missing or denied ...` (misleading, capture works and the pair is wrong), then the specific warning | `signal on tap channels: 1,2 \| on device input channels (noise counts): 1,2,3,31,32 \| ...`, then `warning: tap buffer 1 was picked by stream id diff: signal on tap channels 1,2, outside --source-channels 3,4. ...`. The specific warning fires after the silence wait, so the fix of 74557ae works in the live flow. The order is fixed after this run, not yet measured again |

Not measured:

- The gain check with the calibration tone (`--tap-mode stereo-mixdown` against the default),
  QuickTime file `sine-1khz-minus20dbfs.wav`. The -20 dBFS rows above and below stay empty.
- Ctrl-C restores the normal output (the app plays on its normal output again).
- A forced right buffer `--tap-buffer 1`, to compare with the stream id diff choice.
- Run 3 again with the corrected order: specific warning only, no permission hint.

A stereo input device (layout `[2, 2]`, for example a USB stereo interface). In device stream mode
the stream id diff names the tap buffer when exactly one input stream appears with the tap and the
old streams keep their order. The unit tests cover this with fakes: `[2, 2]` with a diff index
works, a changed stream list fails the diff, and the route is then refused with the device name and
the layout unless `--tap-buffer` names the buffer. The stereo mixdown mode does not use the diff and
needs `--tap-buffer` on such a device. Not proven: that the IO buffers of a real `[2, 2]` device
follow the stream list order, no such device was run.

Runs still to measure. Use the exact commands below, release build, QuickTime Player at full app
volume, the system volume unchanged. Expected on a unity tap: `tap peak` -20.0 dBFS (within 0.2 dB)
for the -20 dBFS file and -6.0 for the -6 dBFS file. Do not fill a cell that was not measured.

```sh
swift build -c release
.build/release/audio-router-proto devices
.build/release/audio-router-proto apps
```

1. The -20 dBFS run on the X-USB. Set the macOS default output to the X-USB, play
   `sine-1khz-minus20dbfs.wav`.

   ```sh
   .build/release/audio-router-proto route --bundle-id <id> \
     --device <x-usb uid> --channels 1,2 --meter
   ```

2. The MacBook speakers, a stereo output device. Set the speakers as the macOS default output and
   use the speakers' uid from `devices`. Run once with the -6 dBFS file and once with the -20 dBFS
   file, each in `--tap-mode device-stream` and once in `--tap-mode stereo-mixdown`.

   ```sh
   .build/release/audio-router-proto route --bundle-id <id> \
     --device <speakers uid> --channels 1,2 --meter
   .build/release/audio-router-proto route --bundle-id <id> \
     --device <speakers uid> --channels 1,2 --meter --tap-mode stereo-mixdown
   ```

3. A long run for drift on the X-USB, device stream mode, at least 60 minutes with the -6 dBFS
   file in a loop. Look for dropouts or crackle, a `tap peak` that moves away from -6.0, and the
   `frames` average at the start and at the end.

   ```sh
   .build/release/audio-router-proto route --bundle-id <id> \
     --device <x-usb uid> --channels 1,2 --meter 2>&1 | tee drift.log
   ```

| Run | Signal line | Warning printed (yes or no, text) | `tap peak` | `tap rms` | Notes |
| --- | ----------- | --------------------------------- | ---------- | --------- | ----- |
| X-USB, -20 dBFS, device-stream | | | | | |
| MacBook speakers, -6 dBFS, device-stream | | | | | |
| MacBook speakers, -20 dBFS, device-stream | | | | | |
| MacBook speakers, -6 dBFS, stereo-mixdown | | | | | |
| MacBook speakers, -20 dBFS, stereo-mixdown | | | | | |
| X-USB, 60 minutes, start | | | | | `frames` average: |
| X-USB, 60 minutes, end | | | | | `frames` average, dropouts: |
| Stereo input device (`[2, 2]`), device-stream | | | | | device name, buffers, stream ids A and B: |

Results to fill in, one row per run. Use release builds, QuickTime Player at full app volume, the
system volume unchanged, and the sine files from the earlier steps. Expected on a unity tap: `tap
peak` -6.0 and -20.0 dBFS (within 0.2 dB). Expected on the old mixdown on the X-USB: about -30.1
and -44.1 dBFS.

For the MacBook speaker rows, set the speakers as the macOS default output and use the speakers'
uid from `devices` as `--device`. The app must already play to that device, see the limit above.

| Default output of macOS | `--tap-mode` | Sine | `tap format` line | Tap buffer line | Signal line | `tap peak` | `tap rms` | Unity within 0.2 dB |
| ----------------------- | ------------ | ---- | ----------------- | --------------- | ----------- | ---------- | --------- | ------------------- |
| X-USB (32 channels) | stereo-mixdown | -6 dBFS | 2 channels (first run, buffers `[32, 2]`) | the only buffer of the tap shape | | -30.1 | -33.1 | no (-24.1 dB) |
| X-USB (32 channels) | stereo-mixdown | -20 dBFS | | | | | | |
| X-USB (32 channels) | device-stream, `--tap-buffer 1` | -6 dBFS | 48000 Hz, 32 channels, interleaved | named by `--tap-buffer`, buffers `[32, 32]`, tap in buffer 1 | tap `1,2`, device `1,2,3,31,32` (noise), preferred pair `1,2` | -6.0 | -9.0 | yes |
| X-USB (32 channels) | device-stream, `--tap-buffer 1` | -20 dBFS | | | | | | |
| X-USB (32 channels) | device-stream, no `--tap-buffer` | -6 dBFS | 48000 Hz, 32 channels, interleaved (tap list set OSStatus 0, sub tap class not available) | `by stream id diff`, tap in buffer 1, A `[239]`, B `[239, 241]` | tap `1,2`, device `1,2,3,31,32` (noise), preferred pair `1,2` | -6.0 | -9.0 | yes |
| MacBook speakers (2 channels) | stereo-mixdown | -6 dBFS | | | | | | |
| MacBook speakers (2 channels) | stereo-mixdown | -20 dBFS | | | | | | |
| MacBook speakers (2 channels) | device-stream | -6 dBFS | | | | | | |
| MacBook speakers (2 channels) | device-stream | -20 dBFS | | | | | | |

- Does Spotify's stereo land on tap channels 1,2 in `device-stream` mode (signal line):
- Does the tap side of the signal line show exactly 1,2 (device side is noise and may show anything):
- The `probe:` lines (stream owners, tap owned objects, tap list settable):
- Which mode is unity on the X-USB: `device-stream` (measured, -6.0 dBFS). Does it hold on the
  MacBook speakers, and at -20 dBFS: not measured yet.
- Still unmeasured: the -20 dBFS file on both modes, the MacBook speaker rows, a long run for
  drift, a device with several input streams.

How to run the table. QuickTime Player cannot read from `/private/tmp`, so copy the sine files to
the Desktop first:

```sh
cp <tones dir>/sine-1khz-minus6dbfs.wav <tones dir>/sine-1khz-minus20dbfs.wav ~/Desktop/
```

Calibration procedure:

1. `.build/release/audio-router-proto apps` with QuickTime Player playing, to get its bundle id.
2. Set the macOS default output to the X-USB. Play `sine-1khz-minus6dbfs.wav`, then
   `sine-1khz-minus20dbfs.wav`, each at full app volume and unchanged system volume.
3. `.build/release/audio-router-proto route --bundle-id <id> --device <uid> --channels 1,2 --meter`
   for each file. Expected on a unity tap: `tap peak` -6 and -20 dBFS. Expected if the mixdown
   divides by 16: about -30 and -44 dBFS.
4. Repeat with the macOS default output on a stereo device (MacBook speakers) and the same
   `route` command. Expected: -6 and -20 dBFS.

How to read the meter lines. Use release builds. The meter prints to stdout once a second, the
reading covers the interval before the last one.

- `out` is read back from the output buffer after the copy, with the same guards as the copy. It
  equals `tap` by construction. It shows that the copy ran and wrote what it read. It is not an
  independent measuring point, and `out` equal to `tap` does not say anything about the gain
  before the IO proc.
- `tap` merges the left and right channel. A tap with audio on one side only reads about 3 dB
  lower in RMS. The peak hides that, so compare the peak with the X32 meter.
- The RMS of a full scale sine prints -3.0 dBFS. Compare peak with peak.
- `frames` counts the IO callbacks of the aggregate device on the X32 clock. It is not the sample
  rate of the tap and it jitters with the one second timer. Average several lines.
- The `aggregate input streams` line lists the tap stream. The owner's run printed two streams
  for the layout `[32, 2]`, one per buffer. The headers do not say that the list on the aggregate
  includes the tap, the run shows it does.

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

- Printed sample rates (tap, aggregate, device): reported 48000 Hz for all three.
- Average of `frames` over several lines (the aggregate IO rate, not the tap rate):
- Does `tap` equal `out` in every line (it does by construction, see above): reported yes.

Candidate causes. None is excluded without a measurement. The table says which measurement
separates them.

| Candidate | Measurement that separates it |
| --------- | ----------------------------- |
| The stereo mixdown of the tap changes the level (the leading hypothesis, see the prediction above) | Play the sine file of known level. If `tap peak` differs from the file level at app volume 100 percent and no normalization, the tap changes it. Repeat with a stereo default output to see whether the 32 channels matter. If it matches, the tap is not the cause. |
| The app applies its volume before the tap | Move the app volume slider. If `tap` follows it, the volume is applied before the tap, which is expected. Then compare with the unrouted run at the same slider position. |
| The system output volume is applied after the tap | Change the system output volume. If the unrouted X32 meter follows it and `tap` does not, the unrouted path had a gain that the routed path lacks. |
| Sample rate conversion or a rate mismatch | Compare the three printed rates and the effective rate. Equal rates do not exclude a converter inside the tap, but a level change from conversion alone is not expected. A mismatch would call for a run with the device set to the tap's rate. |
| Trim or meter reference on the X32 USB return | Compare `out` with the X32 return meter for the same signal. If `out` matches the file level and the X32 reads about -21 dB, the loss is on the X32 side and the unrouted path would read the same. |
| The two runs differ in Spotify settings | Spotify has its own volume and a normalization setting. Keep both fixed between the routed and the unrouted run. |

Reading the result:

- `tap` below the file level: the loss happens before the IO proc (mixdown, app volume or rate).
- `tap` at the file level, `out` equal to `tap`, X32 meter lower: the loss is after the IO proc, on the device side.
- `out` below `tap`: the copy would lose level. Since `out` is read back from what the copy wrote,
  this would point at a bug in `ChannelMapper`. `out` equal to `tap` proves nothing about the tap.
