# Hardware checklist on a macOS runner

Issue 60. This page says which steps of `docs/hardware-checklist.md` a GitHub Actions macOS runner can run.
The evidence is one run of a throwaway workflow, `spike-runner.yaml`, which is not part of the repository.
The workflow never went to `main`. Its last version is in commit `602335b` on the branch `test/60-runner-spike`.
The run log of run 45968366431 is the only source of the results below.

## Method and limits

- Run: GitHub Actions run 45968366431, one job `probe`, 2026-11-27, result success.
  Every probe step has `continue-on-error`, so a green run says nothing about the probes.
- Runner: workflow label `macos-latest` (as in `app-release.yaml`). Log: image `macos-26-arm64`,
  version `20261117.0516.1`, macOS 26.7.2 (build 25G332), arm64.
- Every quote below is a line of the run log. A claim without a quote is marked as unverified.
- One run only. A second run could differ, for example in the image version.
- The checklist targets macOS 27 and the X32. The runner is macOS 26 with virtual audio devices only.
  A pass on the runner would not replace the owner's run on the X32.
- Not read for this page: the GitHub runner documentation and the runner image readme.
  Statements about the image beyond the log are unverified.
- Log times are UTC.

## Probe results

| Probe | Answer | Evidence |
| --- | --- | --- |
| Q0 runner facts | SIP is off, `sudo` needs no password, user `runner` is in group `admin` | `csrutil: System Integrity Protection status: disabled.`, `sudo without password: yes` |
| Q5 devices before any install | Only virtual devices, 2 channels each. No real device | see below |
| Q1 install a virtual device | yes | `SPIKE[q1] RESULT: yes, the virtual device is listed` |
| Q4 switch the default output | yes | `SPIKE[q4] RESULT: yes, the default output was switched by a script` |
| Q2 grant the capture permission | inconclusive | a row was written, Q3 got no samples |
| Q3 play a tone and tap it | no | `SPIKE[q3] RESULT: no meter line, the tap delivered nothing or the route failed, see the route log` |

### Q5 Devices before any install

- `system_profiler SPAudioDataType` lists `Apple Virtual Sound Device` (output, 2 channels, 48000 Hz,
  `Output Source: Speakers`, default output), the same name as input (2 channels, `Input Source: Microphone`,
  default input) and `Null Audio Device` (2 in, 2 out, 44100 Hz, `Transport: Virtual`).
- `audio-router-proto devices` lists two devices:

  ```text
  UID                  NAME                        CHANNELS
  AVIODevice           Apple Virtual Sound Device  2
  NullAudioDevice_UID  Null Audio Device           2
  ```

- No 32 channel device, no USB device, no real speakers. Nobody can listen.
- The `Speakers` label belongs to a virtual device.
- `AGENTS.md` says Core Audio lists no devices. That statement is about the agent sandbox, not about a runner.

### Q1 Install a virtual device

- Command: `brew install --cask blackhole-2ch`, then `sudo killall coreaudiod`, then `audio-router-proto devices`.
- Log: `installer: The install was successful.` and `installer: The install requires restarting now.`
  The cask caveat says `You must reboot for the installation of blackhole-2ch to take effect.`
- The step ran from 08:48:12 to 08:48:38. No password prompt, no reboot.
- After the `coreaudiod` restart the tool lists `BlackHole2ch_UID     BlackHole 2ch               2`.
- Unverified: the licence of BlackHole for use in CI.
- Unverified: whether the device survives a runner restart. The log has no restart.

### Q4 Switch the default output

- Command: `brew install switchaudio-osx`, then `SwitchAudioSource -s "BlackHole 2ch" -t output`.
- Log: `default before: Apple Virtual Sound Device`, `default after: BlackHole 2ch`.
- Unverified: whether an app that follows the default moves to the new device. No audio played at that point.

### Q2 Permission grant

- Both TCC databases exist and are readable (the system one with `sudo`).
- The provisioning already grants other services to `/bin/bash` in the system database,
  for example `kTCCServiceAccessibility|/bin/bash|2` and `kTCCServiceScreenCapture|/bin/bash|2`.
- No audio capture row existed before the write.
- Write attempt with `sudo sqlite3`. The service name `kTCCServiceAudioCapture` is a guess:

  ```text
  write ok
  kTCCServiceAudioCapture|/bin/bash|2
  ```

- Result: the database is writable. A grant is not shown, because Q3 got no samples.
- Unverified: that `kTCCServiceAudioCapture` is the service the tap checks.
- Unverified: that the check looks at `/bin/bash` and not at the tool or its parent process.
- Unverified: whether `tccd` reads the row without a restart.

### Q3 Tone and tap

- Setup: a 60 second 1 kHz sine `sine.wav`, `afplay sine.wav &`, `open -a "QuickTime Player" sine.wav`,
  then `osascript -e 'tell application "QuickTime Player" to play document 1'`.
- The Apple Event timed out after about 2 minutes (08:48:49 to 08:50:51):

  ```text
  39:54: execution error: QuickTime Player got an error: AppleEvent timed out. (-1712)
  osascript play failed
  ```

- `audio-router-proto apps` then shows `com.apple.QuickTimePlayerX  (1 processes, 0 playing)` and
  `com.apple.QuickTimePlayerX  pid 3743  idle`. Every listed process shows `0 playing`.
  `afplay` is not in the list.
- The tool found the device: `device uid: BlackHole2ch_UID`.
- The route started at about 08:50:57. The script sent `kill -TERM` after 20 seconds, then waited.
  The route log was printed at 08:53:58, about 3 minutes after the start:

  ```text
  stop requested while the route starts. The start cannot be cancelled, the route stops when it returns. If it hangs, kill the process: kill -KILL 7498. ...
  stopped
  error: AudioDeviceStart (start IO) failed with OSStatus 268451843 (no four character code).
  ```

- The log has no `tap peak` line, so no sample level was measured.

Cause of the missing meter line, as far as the log shows it:

- Route error. The route start blocked inside `AudioDeviceStart` for about 3 minutes
  and then failed with `OSStatus 268451843`.
- It is not a denied permission that the log shows. The log has no permission error and no permission warning.
  The route never returned from the start, so the tool had no chance to print the signal or permission warnings.
- It is not shown as a silent tap either. The route never reached the point where samples would arrive.
- The source never played. QuickTime Player reported `0 playing` after the timed out Apple Event.
  So there was nothing to tap even if the route had started.
- Why `AudioDeviceStart` blocked and then failed is unverified. The log does not say.
  Open candidates, none tested:
  - The default output was `BlackHole 2ch` (Q4).
  - The TCC state (Q2).
  - A `coreaudiod` restarted shortly before (Q1).
  - A runner with no real audio clock.
- `268451843` is `0x10004003`. Its meaning is unverified. Check it against the SDK headers.
- That the tap and the aggregate device were created is inferred from the error text `start IO`, not shown.

## Step table

`Runner can do it`: `yes` means a CI job could run the step and decide pass or fail.
`partly` means a part could run and the rest needs a person or a real device.
`no` means the step stays with the owner.
No step is `yes`. Rows that need a tap stay `no`, because no tap worked on the runner.

| Step | Runner can do it | Why | Evidence |
| --- | --- | --- | --- |
| 1 First open of the downloaded app | partly | Checksum, `codesign`, `spctl` and `stapler` can run on the asset. The quarantine flag from a browser download, the Gatekeeper dialog and the menu bar look need a person. | Not probed. `app-release.yaml` already runs `task bundle:verify`. Unverified that it covers the same checks. |
| 2 Permission prompt for the app | no | The prompt is the test. A written TCC row would skip it. | Q2: `write ok`. No prompt was seen either way. |
| 3 Permission denial in the app | no | Needs a denied state and a read of the error display. | Q2 shows a writable database, not what a denial looks like. |
| 4 Permission flow of the tool | no | Tests the prompt and the name of the terminal app. | Q2: the client the check uses is unverified. |
| 5 Unity with the -20 dBFS sine | no | Needs a working tap and a meter line. The app half is visual. | Q3: `no meter line`, `AudioDeviceStart ... 268451843`. |
| 6 Two routes on the X-USB at once | no | One route already fails. Virtual devices have 2 channels, not 32. | Q3, Q5. |
| 7 Two routes on two devices | no | Two virtual devices exist, but one route fails, so two are untested. | Q5, Q1, Q3. |
| 8 Unplug and replug | no | A physical cable. Removing a virtual driver is a different event. | Not probed. |
| 8a Unplug while Spotify plays | no | Physical, and needs Spotify. | Not probed. |
| 8b Replug after 8a | no | Follows 8a. | Not probed. |
| 8c Flap within one second | no | Physical timing. | Not probed. |
| 8d Default moves to AirPods | partly | The switch works from a script. Whether the app is audible on the new default needs audio from an app and a listener. | Q4: `default after: BlackHole 2ch`. Q3: no app played. |
| 8e Default returns to the X32 | partly | Same as 8d. The X32 does not exist on the runner. | Q4, Q5. |
| 8f Default moves to the speakers | no | The runner has no speakers. Its `Speakers` output is virtual. | Q5: `Output Source: Speakers` on `Apple Virtual Sound Device`. |
| 9 Sample rate change on the X32 | no | The X32 changes its own rate. | Not probed. |
| 10 App quit and start | no | Needs a playing app and a working route. | Q3: `0 playing`, route start failed. |
| 11 Global off | no | A menu click. UI scripting needs the accessibility permission and the menu bar app. | Not probed. Unverified that UI scripting works on the runner. |
| 12 Quit restores normal output | no | A listening test and a check by eye. | Not probed. |
| 13 Login restore after reboot | no | A reboot and a login. | Not probed. |
| 14 Thirty minute run for drift | no | Needs the X-USB, because drift is the question. | Not probed. |
| 15 Second build, new permission prompt | no | Needs two release assets and the permission store. | Not probed. |
| 16 Login item, restore and status | no | Login, System Settings and an approval state. | Not probed. |
| 17 Live meters in the menu and Settings | no | Visual, and Activity Monitor numbers. | Not probed. |
| 17a Does the tap see the app volume | no | Needs a tap and a moving app volume. Neither worked. | Q3. |
| 18 Errors and actions | no | Needs a denied permission and a read of texts and buttons. | Not probed. |
| 19 Route editor | no | UI interaction. | Not probed. |
| 20 Settings opens in front | no | Window focus, visual. | Not probed. |

## What the runner can and cannot do

Shown by the log:

- Build the package and the tool.
- List audio devices, including two virtual 2 channel devices that exist from the start.
- Install a virtual driver with `brew` and `sudo` and see it after a `coreaudiod` restart, without a reboot.
- Switch the default output by script.
- Write a row into the system TCC database.

Not shown or failed:

- Play audio from QuickTime Player. The Apple Event to play timed out (`-1712`).
- Tap an app and read a level. The route start blocked and failed in `AudioDeviceStart`.
- Anything with a real device: 32 channels, a USB cable, AirPods, speakers.
- Anything that needs a person: a prompt, a dialog, a menu click, a listening test.

## Recommended follow up

Not filed. The owner decides. Each bullet is ready to become an issue.

- Automate in CI: the signature and notarization checks of the release asset (machine part of step 1),
  if `task bundle:verify` does not already cover `spctl` and `stapler`.
  Optionally a device list and default output smoke check, after the BlackHole licence is cleared.
- Keep as hardware checklist: every step marked `no`, and the user facing half of steps 1, 8d and 8e.
  Nothing else moves to CI on the evidence of this spike.
- Second spike on the `AudioDeviceStart` block: the route start blocked about 3 minutes, then failed with
  `OSStatus 268451843`, a route error. Only worth it if the owner wants a tap in CI. Details below.

### Automate in CI

- Nothing from the checklist moves into CI on the evidence of this spike.
- Signature and notarization checks of the release asset, the machine part of step 1.
  `app-release.yaml` runs `task bundle:verify`. Check first whether it already covers `spctl` and `stapler`.
  Unverified.
- Device list and default output switch as a smoke check of the tooling only.
  It proves that the scripts run, not that routing works.
  Only worth it after BlackHole is cleared for use in CI.

### Keep as hardware checklist

- All steps marked `no` in the table.
- The user facing half of steps 1, 8d and 8e: dialogs, listening, the real X32 and AirPods.
- Everything with a real device, a cable, a reboot, a login or a long run.

### Second spike, only if the owner wants a tap in CI

Vary one thing per run:

- Keep the default output on `Apple Virtual Sound Device` and route to `BlackHole 2ch`.
- Route to the `Null Audio Device`.
- Run the route without the `coreaudiod` restart in the same step.
- Put a timeout around the route, so a hung start does not take 3 minutes.
- Use a source with a bundle id that plays without an Apple Event, for example a small signed test app.
  `afplay` was not listed as a process.
- Find the real service name of the audio capture permission in the SDK or a TCC log on a real Mac,
  then write that row for the client the check uses.
- Check the BlackHole licence before any use in CI.
