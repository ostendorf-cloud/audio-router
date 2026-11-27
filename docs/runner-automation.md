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
- Every quote below is a line of the log of run 45968366431, read with `gh run view --log`.
  A claim without a quote is marked as unverified.
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
| Q3 play a tone and tap it | inconclusive | `SPIKE[q3] RESULT: no meter line, the tap delivered nothing or the route failed, see the route log`. The route start failed, and the tone had ended before it. |

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
- Unverified: the licence of BlackHole for use in CI. A later web research is recorded under "Open" of the second spike.
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

- Route error. The route start blocked for about 3 minutes and then failed with `OSStatus 268451843`.
  The error text names `AudioDeviceStart`. That the time was spent inside that call is not shown.
  Round 4 below puts a hang in `AudioDeviceCreateIOProcID`, an earlier call.
- It is not a denied permission that the log shows. The log has no permission error and no permission warning.
  The route never returned from the start, so the tool had no chance to print the signal or permission warnings.
- It is not shown as a silent tap either. The route never reached the point where samples would arrive.
- The source never played through QuickTime Player, which reported `0 playing` after the timed out Apple Event.
  The `afplay` tone was a 60 second sine started before 08:48:49, so it had ended before the route start at 08:50:57.
  So there was nothing to tap even if the route had started. This is why Q3 is inconclusive for the tap.
- Why `AudioDeviceStart` blocked and then failed is unverified. The log does not say.
  Open candidates, none tested:
  - The default output was `BlackHole 2ch` (Q4).
  - The TCC state (Q2).
  - A `coreaudiod` restarted shortly before (Q1).
  - A runner with no real audio clock.
- `268451843` is `0x10004003`. Its meaning is unverified. It is not in the SDK headers, see the second spike below.
- That the tap and the aggregate device were created is inferred from the error text `start IO`, not shown.

## Step table

`Runner can do it`: `yes` means a CI job could run the step and decide pass or fail.
`partly` means a part could run and the rest needs a person or a real device.
`no` means the step stays with the owner.
No step is `yes`. Rows that need a tap stay `no`, because the runner gave no tap result: Q3 is inconclusive.

| Step | Runner can do it | Why | Evidence |
| --- | --- | --- | --- |
| 1 First open of the downloaded app | partly | Checksum, `codesign`, `spctl` and `stapler` can run on the asset. The quarantine flag from a browser download, the Gatekeeper dialog and the menu bar look need a person. | Not probed. `scripts/verify-signature.sh` runs `spctl` and `stapler validate` in `notarized` mode (lines 82 and 85), but on the built app, not on the published asset. |
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
| 8e Default returns to the X32 | no | The X32 does not exist on the runner, so the rule of 8f applies. | Q4, Q5. |
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
- Tap an app and read a level. The route start blocked and failed, see the second spike and round 4.
- Anything with a real device: 32 channels, a USB cable, AirPods, speakers.
- Anything that needs a person: a prompt, a dialog, a menu click, a listening test.

## Recommended follow up

Filed as issues 84, 85 and 86. The owner triages them.

- Issue 84, automate in CI: the signature and notarization checks of the release asset, the machine part of step 1.
  `scripts/verify-signature.sh` already runs `spctl` and `stapler validate` on the built app, so the gap is the
  published asset.
- Issue 85, keep as hardware checklist: every step marked `no`, and the user facing half of steps 1, 8d and 8e:
  dialogs, listening, the real X32 and AirPods.
  Apart from the machine part of step 1, nothing moves to CI on the evidence of this spike.
- Issue 86, second spike on the `AudioDeviceStart` block: the route start blocked about 3 minutes, then failed with
  `OSStatus 268451843`, whose meaning is unverified. Only worth it if the owner wants a tap in CI. Details below.

## Second spike, issue 86: the route start hangs in all four variants

Result so far is negative. A route with a tap does not start on the hosted runner, in every variant tried.
The cause is not found. Round 4 below narrows the hang to one call.

### Second spike method and limits

- Run: GitHub Actions run 46010697518, 2026-11-27, workflow `spike-audiodevicestart.yaml` on the branch
  `test/86-runner-spike-2` (commits `3d94697` and `0512cb7`). The workflow is not part of `main`.
  The spike ended with a removal commit, so the files are only in those commits of the branch history.
- The run ran on head `096ce78`. The hashes named in this document are the ones after the rebase onto `main`.
- Runner: `macos-latest`, image `macos-26-arm64`, macOS 26.7.2 (build 25G332), SIP disabled, console user `runner`.
- Four jobs, one runner each. Every quote below is a line of the saved job log of that run. Log times are UTC.
- Source: a small ad hoc signed app, bundle id `cloud.ostendorf.spike-tone`, plays a 1 kHz sine at half scale
  with `AVAudioEngine` on the default output. No Apple Event is involved.
- Route: `audio-router-proto route --bundle-id cloud.ostendorf.spike-tone --channels 1,2 --meter` under a
  watchdog. After 45 s without a meter line the script sends `TERM`, and `KILL` 5 s later.
- One run only. A second run could differ.

| Variant | Driver and `coreaudiod` restart | Default output at the route | Destination | Result |
| --- | --- | --- | --- | --- |
| `baseline` | yes | `BlackHole 2ch` | `BlackHole 2ch` | no meter line in 45 s, `KILL` needed |
| `default-avsd` | yes | `Apple Virtual Sound Device` | `BlackHole 2ch` | no meter line in 45 s, `KILL` needed |
| `null-device` | yes | `BlackHole 2ch` | `Null Audio Device` | no meter line in 45 s, `KILL` needed |
| `clean-null` | no | `Apple Virtual Sound Device` | `Null Audio Device` | no meter line in 45 s, `KILL` needed |

`clean-null` changes three things against `baseline`: no driver, no `coreaudiod` restart, default output untouched.
The other two change one thing each.

### Shown by the log

- The source plays in all four jobs. The tool lists `cloud.ostendorf.spike-tone  pid <n>  playing`
  and the source prints `tone: playing at 48000.0 Hz for 600.0 s`.
- The audio engine delivers the tone to the default output. `coreaudiod` reports in `default-avsd`,
  `null-device` and `clean-null`:
  `RTAID [ ... clientID=HAL node=-Output ... ] -- [ rms:[-9.03...], peaks:[-6.020600] ]`.
  That is the level of a half scale sine. The sample time advances by about 480000 every 10 s, which is 48 kHz in real time.
  The `baseline` excerpt is too short to hold such a line.
- The route prints nothing before the `TERM`. Then the tool prints
  `stop requested while the route starts. The start cannot be cancelled ...`. That line is printed only while the
  tool is inside `RouteSession.start`. So the tool was in its start in all four jobs at the time of the `TERM`.
  The start is a sequence of Core Audio calls. This log does not say which one blocks. Round 4 below does.
- The `TERM` does not end the tool, as the notice says. Each job needs `KILL`: `Killed: 9`, after
  `SPIKE[route] still alive after TERM, sending KILL`.
- No `OSStatus` came back within 45 s. The first spike's `268451843` came after about 3 minutes.
  Whether this run would end in the same error without the `KILL` is not known.
- `SwitchAudioSource -s "BlackHole 2ch" -t output` returns in about 1 s (`baseline`, 13:53:17 to 13:53:18).
  The switch itself does not hang.
- The tool lists `BlackHole 2ch` after the `coreaudiod` restart (`null-device`), as in the first spike.
- The query for audio rows in the system TCC database printed nothing in all four jobs. This spike wrote no row.
  The user database was not read.
- `kTCCServiceAudioCapture` appears in none of the four logs.
  The `kTCCServiceMicrophone` and `kTCCServiceScreenCapture` requests for `SwitchAudioSource`
  (`authValue=2`, `authReason=4`) come from the evidence step after the route. They are not about the route.

### Checks on a Mac, no runner

- `268451843` is `0x10004003`. It is not in the macOS SDK. A search of `CoreAudio.framework/Headers`
  and `AudioToolbox.framework` for the decimal and the hex value found nothing.
  `AudioHardwareBase.h` lines 154 to 166 list the four character `OSStatus` values, and none matches.
  The meaning is unknown.
- The service name `kTCCServiceAudioCapture` is real on macOS 27. `strings` on
  `/System/Library/PrivateFrameworks/TCC.framework/Support/tccd` lists it.
  The SDK file `System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC.tbd` exports `_kTCCServiceAudioCapture`.
- Not verified: which client the tap check reads, a bundle id or a path.
- Not verified: that `tccd` reads a written row without a restart.

### What the four timeouts answer

- The hang does not depend on the default output being `BlackHole 2ch`. `default-avsd` hangs too.
- The hang does not depend on the destination being `BlackHole 2ch`. `null-device` and `clean-null` hang too.
- The hang does not depend on a `coreaudiod` restart or on an installed driver. `clean-null` has neither.
- A missing source is not the cause. The source plays in all four jobs.
- The default output has a running real time clock. That does not show it for the `Null Audio Device` aggregate.
- The watchdog works. A hung start costs about 50 s, not 3 minutes.

### What they do not answer

- Which call blocks. The log has no stack and no step markers inside the tool.
  The first spike named `AudioDeviceStart` from the error text. For this run that was inferred from the order in
  `CoreAudioRoutingBackend.swift`. It was not shown. Round 4 below shows the blocking call in a probe:
  `AudioDeviceCreateIOProcID`, not `AudioDeviceStart`.
- Inference, not shown: the tap and the aggregate device exist while the start hangs.
  In every job `coreaudiod` logs `HALS_MultiTap::unregister_meta_device`,
  `HALS_Device::_Deactivate: deactivating device <id>: <uuid>` and `HALS_MultiTap_Engine::UnregisterIOContext`
  within about 0.1 s of the `KILL`. The runner log and the system log use different clocks, so the order is not shown.
  A multi tap device that disappears with the process fits a tap aggregate. The log does not name it.
- Whether a permission decision is pending. `clean-null` is the only job whose log excerpt covers the whole 45 s.
  Between 13:51:59 and 13:52:48 it holds only `RTAID` lines of the tone and two LaunchServices notifications.
  `tccd` and `coreaudiod` log no request for the tool.
  The excerpt is `log show` at the default level, so info and debug lines are not in it.
  Absence of a line is not proof.
- Why the first spike ended with an error after 3 minutes and this one was cut at 45 s.
- Whether any tap works on a hosted runner. Nothing here shows a working tap.
- The excerpt of `baseline`, `default-avsd` and `null-device` is the last 300 lines of `log show`. It covers
  only the last 3 to 17 s of the 45 s window.

### Open

- BlackHole and `switchaudio-osx` licences, from a later web research of 2026-11-27 (not part of the run):
  - BlackHole source: GPL-3.0. The `LICENSE` file says so.
  - BlackHole README: "BlackHole can be integrated into your CI/CD." The README sentences on GPL-3.0 and on a
    licence for non-GPLv3 projects sit in the FAQ on integrating BlackHole into an app.
  - BlackHole official binaries and installers: "All rights reserved" by Existential Audio Inc.
    No terms for the binary were found. No statement on use in CI was found for the binary.
  - `switchaudio-osx`: MIT, from the Homebrew formula and the `license.txt` of the upstream repository.
  - Sources read: the BlackHole `LICENSE` and `README.md`, the Homebrew cask `blackhole-2ch`, the BlackHole project
    page, the BlackHole releases page, the Homebrew formula `switchaudio-osx` and the upstream `license.txt`.
    The web fetch returns summarised text, so the quotes are not checked byte for byte.
  - Not read: any terms or EULA page of Existential Audio (none was found) and the contents of the pkg.
    Not verified: that the pkg on the project page is the one built from the source.
    Not verified: how the README sentences apply to a CI test that integrates nothing into a distributed app.
    This is not legal advice.
  - No driver is needed for `clean-null`.
- Candidates left: a pending permission decision with nobody to answer a prompt, a tap start that needs a real
  audio clock on the destination or a session the runner lacks, and a defect in the tool.
  None of them is tested.
- Two probes were written after this run and ran in round 4 below. They are the throwaway workflow
  `spike-tap-steps.yaml` and the files under `.github/spike/`, in commit `dea8880` of the branch history.
  They never went to `main`, like the first workflow, and a later commit of the branch removed them.
  - `tap-steps.swift` makes the Core Audio calls of the route start one by one in the default device stream mode,
    with a time stamp before and after each call. A watchdog ends the process when one call runs for 55 s.
    The mode `control` starts a plain IO proc on the `Null Audio Device`, with no tap and no aggregate.
    `tap-steps-Info.plist` carries the `NSAudioCaptureUsageDescription`.
  - Job `probe A steps` runs the program as a plain binary with the plist embedded, as the tool has it.
    It runs the control first, then the tap on the tone app.
  - Job `probe B app bundle` runs the program as an ad hoc signed app bundle.
    Pass 1 runs with no row for its bundle id.
    Pass 2 runs after the row `kTCCServiceAudioCapture` is written to the system database and `tccd` is restarted.
    The row write is tried once. SIP is not changed. When the write fails, the job says so and skips pass 2.
  - Both jobs write `log stream --info --debug` of `coreaudiod`, `tccd` and the TCC subsystem to a file for the
    whole job. They print the lines of each run window, capped at 1.5 MB per window.
    The log times are local time, the same as the time stamps of the program.
  - `tap-steps-lib.sh` holds the shell helpers. `tone-Info.plist` is the plist of the tone bundle.
  - The launch path is not tested: both programs start from the runner shell, not through Launch Services.
    Which process the permission check attributes the request to is not verified.

## Round 4, issue 86: the hang sits in AudioDeviceCreateIOProcID

Result is negative. The probes make the route start calls one by one. The call that does not return is
`AudioDeviceCreateIOProcID` on the aggregate device that holds the tap.

### Round 4 method and limits

- Run: GitHub Actions run 46016546432, 2026-11-27, workflow `spike-tap-steps.yaml` on the branch
  `test/86-runner-spike-2`, commit `dea8880` (it was `cad0ec9` before the rebase onto `main`).
  The workflow is not part of `main`. Its files are in commit `dea8880`, `.github/spike/tap-steps.swift` is the
  program.
- Runner: image `macos-26-arm64` version `20261117.0516.1`, macOS 26.7.2.
- Source: the tone app of the second spike. The destination of the aggregate device is `Null Audio Device`.
- Two jobs, one runner each. Both write a time stamp before and after every Core Audio call.
  A watchdog ends the process when one call runs for 55 s.
- One run only. A second run could differ.

| Probe | What ran | Result |
| --- | --- | --- |
| A, control | A plain IO proc on `Null Audio Device`, no tap, no aggregate | Started, 438 IO callbacks in 5 s, stop and destroy returned |
| A, tap | The route start calls one by one, tap on the tone process, destination `Null Audio Device` | `AudioDeviceCreateIOProcID` did not return within 55 s, the watchdog ended the process |
| B, pass 1 | The same steps from an app bundle with its own bundle id, no TCC row | The same hang at `AudioDeviceCreateIOProcID` |
| B, pass 2 | The same, after a `kTCCServiceAudioCapture` row for the bundle id was written and read back | The same hang at `AudioDeviceCreateIOProcID` |

### Round 4 shown by the log

Steps that returned before the hang, in both probes:

- `AudioHardwareCreateProcessTap` ok after 5 to 24 ms.
- `AudioHardwareCreateAggregateDevice` ok after 26 to 29 ms.
- `AudioObjectSetPropertyData` of the tap list ok. The sub tap is readable.
- The input streams of the aggregate device appear. Probe B lists `[112, 114]`.

### What round 4 changes

- Earlier notes put the hang in `RouteSession.start`, and the first spike named `AudioDeviceStart`.
  The blocking call is `AudioDeviceCreateIOProcID` on the aggregate device that holds the tap.
  The tap and the aggregate device are created. The IO proc is not.
- The row `kTCCServiceAudioCapture` for the bundle id of the probe changed nothing. Pass 2 hangs like pass 1.
  This does not rule out a pending permission prompt. The log shows one that nobody can answer:
  - In probe B pass 1, `coreaudiod` sends a `TCCAccessRequest` for `kTCCServiceAudioCapture` at 14:31:03.798.
    That is 6 ms after `AudioDeviceCreateIOProcID begin`.
  - `tccd` logs `AUTHREQ_PROMPTING` at 14:31:03.805 and `display_prompt` at 14:31:03.813.
    The prior result is `Auth Right: Unknown (None)`.
  - Probe A, tap, shows the same sequence from 14:33:08.405 to 14:33:08.419.
  - `tccd` attributes the request to the subject `/opt/hca/hosted-compute-agent`.
    It does not attribute it to the bundle id `cloud.ostendorf.spike-tap-steps`, which the row was written for.
  - Untested: that this pending prompt causes the hang.
- A plain IO proc on a device without a tap works on the same runner.

### Round 4 not verified

- Whether the call blocks in `coreaudiod` or in the client library.
- Whether the microphone request that `tccd` logged for the tap-steps process (`kTCCServiceMicrophone`, preflight)
  is related. The log was not analysed further.
- The `kTCCServiceAudioCapture` prompt lines listed above were read from the log, but not analysed further.
  Whether answering the prompt would let the call return is not tested.
- Why pass 2 shows no `kTCCServiceAudioCapture` request in its log window.
  Candidates are the window cap and the `tccd` restart. Neither is checked.
- Whether the same hang happens when the tool starts through Launch Services, see the open items of the second spike.

### Conclusion

A hosted runner did not start a process tap IO proc in any round.
The spike closes with a negative result.
The hardware checklist, `docs/hardware-checklist.md`, stays a manual step of the owner.
Issue 85 keeps every step marked `no` above.
