# Hardware checklist on a macOS runner

Issue 60. This page says which steps of `docs/hardware-checklist.md` a GitHub Actions macOS runner can run.
The evidence is one run of the throwaway workflow `.github/workflows/spike-runner.yaml`.
The workflow lives on the branch `test/60-runner-spike` and never goes to `main`.

## Method and limits

- Run: GitHub Actions run 45960974172, one job `probe`, 2026-11-27.
- Runner: `macos-latest` as in `app-release.yaml`. The log shows macOS 26.7.2 (build 25G332), arm64.
- Source of the steps: `docs/hardware-checklist.md` at the commit of this page.
- Every quote below is a line of the run log. A claim without a quote is marked as not verified.
- One run only. A second run could differ, for example in the image version.
- The checklist targets macOS 27 and the X32. The runner is macOS 26 with no real audio hardware.
  A pass on the runner would not replace the owner's run on the X32.
- Not read for this page: the GitHub runner documentation and the runner image readme.
  Statements about the image beyond the log are not verified.

## Probe results

### Q0 Runner facts

- `sw_vers`: `ProductVersion: 26.7.2`, `BuildVersion: 25G332`. `uname -m`: `arm64`.
- User: `uid=501(runner)`, member of group `admin`. Console user: `runner`.
- `csrutil status`: `System Integrity Protection status: disabled.`
- `sudo -n true`: `sudo without password: yes`.

### Q5 Audio devices before any install

- `system_profiler SPAudioDataType` lists three entries:
  - `Apple Virtual Sound Device` as input: 2 channels, 48000 Hz, transport `Built-in`, source `Microphone`,
    default input.
  - `Apple Virtual Sound Device` as output: 2 channels, 48000 Hz, transport `Built-in`, source `Speakers`,
    default output.
  - `Null Audio Device`: 2 input and 2 output channels, 44100 Hz, transport `Virtual`.
- `audio-router-proto devices` lists two devices:

  ```text
  UID                  NAME                        CHANNELS
  AVIODevice 2         Apple Virtual Sound Device  2
  NullAudioDevice_UID  Null Audio Device           2
  ```

- Result: the runner has audio devices, but only virtual ones with 2 channels.
  There is no 32 channel device, no USB device and no real speakers.
- This contradicts the claim in `AGENTS.md` that Core Audio lists no devices.
  That claim is about the agent sandbox, not about a runner.

### Q1 Install a virtual device

- Command: `brew install --cask blackhole-2ch`, then `sudo killall coreaudiod`, then `audio-router-proto devices`.
- Install: `installer: The install was successful.` and `installer: The install requires restarting now.`
  The cask caveat reads `You must reboot for the installation of blackhole-2ch to take effect.`
- The installer ran with `sudo` and asked for no password.
- After the `coreaudiod` restart, without a reboot, the tool lists a third device:

  ```text
  BlackHole2ch_UID     BlackHole 2ch               2
  ```

- Result: yes. A virtual device installs and shows up in about 15 seconds of install time.
- Not verified: the licence of BlackHole for use in CI. Check it before this goes into a workflow.
- Not verified: whether the device keeps working after the runner restarts. The log has no restart.

### Q4 Switch the default output by script

- Command: `brew install switchaudio-osx`, then `SwitchAudioSource -s "BlackHole 2ch" -t output`.
- Log: `default before: Apple Virtual Sound Device`, `output audio device set to "BlackHole 2ch"`,
  `default after: BlackHole 2ch`.
- Result: yes. The default output switches from a script, with no prompt.
- Not verified: whether an app that follows the default moves to the new device. No audio played in this probe.

### Q2 Grant the capture permission without a prompt

- State on the runner: SIP is disabled and `sudo` needs no password (Q0).
- Both TCC databases exist:

  ```text
  -rw-r--r--  1 runner  staff  86016 Nov 17 04:49 /Users/runner/Library/Application Support/com.apple.TCC/TCC.db
  -rw-r--r--  1 root  wheel  73728 Nov 17 04:42 /Library/Application Support/com.apple.TCC/TCC.db
  ```

- The user database is readable. The system database is readable with `sudo`.
- The provisioning already grants other services to `/bin/bash` in the system database,
  for example `kTCCServiceAccessibility|/bin/bash|2` and `kTCCServiceScreenCapture|/bin/bash|2`.
  No row for an audio capture service exists before the write.
- Write attempt, with `sudo sqlite3` on the system database. The service name `kTCCServiceAudioCapture` is a guess:

  ```text
  write ok
  kTCCServiceAudioCapture|/bin/bash|2
  ```

- Result: unclear. The write succeeded and the row reads back, so the database is writable on this runner.
  No grant is proven, because Q3 never got samples.
- Not verified: that `kTCCServiceAudioCapture` is the service name the tap uses.
- Not verified: that the permission check looks at `/bin/bash` and not at the tool or its parent.
  Checklist step 4 expects the terminal app to be the responsible client.
- Not verified: whether `tccd` reads the row without a restart.

### Q3 Play a tone and tap it

- Setup: a 60 second sine `sine.wav` was generated, `afplay sine.wav &` started,
  `open -a "QuickTime Player" sine.wav`, then `osascript -e 'tell application "QuickTime Player" to play document 1'`.
- The `osascript` call failed after about 2 minutes (07:49:43 to 07:51:45):

  ```text
  39:54: execution error: QuickTime Player got an error: AppleEvent timed out. (-1712)
  osascript play failed
  ```

- `audio-router-proto apps` after that shows QuickTime Player as `com.apple.QuickTimePlayerX  (1 processes, 0 playing)`
  and `pid 3186  idle`. Every listed process shows `0 playing`.
  `afplay` is not in the list, and no bundle id for it was found.
- The device uid was found: `device uid: BlackHole2ch_UID`.
- The route command ran from 07:51:51. The script sent `kill -TERM` after 20 seconds and then waited.
  The step ended at 07:54:52, so the wait took about 3 minutes. The whole step took about 5 minutes.
- The route log holds three lines and no meter line:

  ```text
  stop requested while the route starts. The start cannot be cancelled, the route stops when it returns. If it hangs, kill the process: kill -KILL 6536. ...
  stopped
  error: AudioDeviceStart (start IO) failed with OSStatus 268451843 (no four character code).
  ```

- Cause, as far as the log shows it:
  - The route start blocked inside `AudioDeviceStart`. It was still blocked 20 seconds in, when the stop request came.
    It ended with `OSStatus 268451843` after about 3 minutes.
  - The error names the start of the IO proc. The error texts for the earlier phases name `(create tap)` or
    `(create aggregate)` (`AGENTS.md`). So the tap and the aggregate device were most likely created.
    That is inferred from the text, not shown.
  - The target app never played. QuickTime Player reported `0 playing`, so there was nothing to tap.
  - Why `AudioDeviceStart` blocked and then failed is not known. The log does not say.
    Open candidates, none tested: the default output was `BlackHole 2ch` (Q4), the permission
    state (Q2), a `coreaudiod` that was restarted shortly before (Q1), or a runner with no real audio clock.
- Result: no. No sample was tapped and no level was measured.
- The status code 268451843 is `0x10004003` in hex. Its meaning is not verified.
  Check it against the SDK headers before relying on it.

## What the runner can and cannot do

Can, shown by the log:

- Build the package and the tool. `swift build -c release --product audio-router-proto` finished in 39.96 seconds.
- List audio devices, including two virtual 2 channel devices that exist from the start.
- Install a virtual driver with `brew` and `sudo`, and see the device after a `coreaudiod` restart.
- Switch the default output by script.
- Write a row into the system TCC database.

Cannot or not shown:

- Play audio from QuickTime Player. The Apple Event to play timed out.
- Tap an app and read a level. The route start hung and failed.
- Anything with a real device: 32 channels, a USB cable, AirPods, speakers.
- Anything that needs a person: a prompt, a dialog, a menu click, a listening test.

## Step table

`CI` means the step could run in CI, `local` means a script could run it on a Mac, `manual` means the owner.
The runner column is the class after the spike.
Rows that depend on a tap stay `manual` until a tap works on a runner. No tap worked in this run.

| Step | Runner class | Reason and evidence |
| --- | --- | --- |
| 1 First open | manual, part CI | `shasum`, `spctl`, `codesign` and `stapler` can run on the asset. `app-release.yaml` already runs the signature checks. The quarantine flag from a browser download, the Gatekeeper dialog and the menu bar look need a person. Not probed. |
| 2 Permission prompt (app) | manual | The prompt is the test. A written TCC row (Q2) would skip it, and no prompt was seen on the runner either way. |
| 3 Permission denial (app) | manual | Needs a denied state and a read of the error display. Q2 shows the database is writable, not what a denial looks like. |
| 4 Permission flow (tool) | manual | Tests the prompt and the name of the terminal app. Q2 did not show which client the check uses. |
| 5 Unity with -20 dBFS | manual | Q3 got no tap and no meter line. The app half (Settings meter) is visual. |
| 6 Two routes on one device | manual | Q3 blocked on one route. The virtual devices have 2 channels, not 32. |
| 7 Two routes on two devices | manual | Two virtual devices exist (Q5, Q1). Q3 blocked on one route, so two are untested. |
| 8 Unplug and replug | manual | A physical cable. Removing a virtual driver is a different event. |
| 8a Unplug while Spotify plays | manual | Physical, and needs Spotify. |
| 8b Replug after 8a | manual | Follows 8a. |
| 8c Flap within one second | manual | Physical timing. |
| 8d Default moves to AirPods | manual, switch part local | The default switch works from a script (Q4). Whether the app is audible on the new default needs audio from an app. Q3 got none. |
| 8e Default returns to the X32 | manual, switch part local | Same as 8d. |
| 8f Default moves to the speakers | manual | Q5: the runner has an output with source `Speakers`, but it is a virtual device, not speakers. Nobody can listen. |
| 9 Sample rate change | manual | The X32 changes its own rate. |
| 10 App quit and start | manual | Needs a playing app and a working route. Q3 had neither. |
| 11 Global off | manual | A menu click. UI scripting needs the accessibility permission. |
| 12 Quit restores output | manual | A listening test and a check by eye. |
| 13 Login restore after reboot | manual | A reboot and a login. |
| 14 Thirty minute run | manual | Needs the X-USB, because drift is the question. A virtual device has no clock of its own. |
| 15 Second build | manual | Needs two release assets and the permission store. |
| 16 Login item | manual | Login, System Settings and an approval state. |
| 17 Live meters | manual | Visual, and Activity Monitor numbers. |
| 17a App volume | manual | Needs a tap and a way to move the QuickTime Player volume. Neither was shown. |
| 18 Errors and actions | manual | Needs a denied permission and a read of texts and buttons. |
| 19 Route editor | manual | UI interaction. |
| 20 Settings opens in front | manual | Window focus, visual. |

## Reading the table

- No step is proven automatable on the runner. The spike did not move any row from `manual` to `CI` or `local`.
- The blockers that the spike found are two:
  - QuickTime Player does not play from `osascript` on the runner (Q3, `-1712`).
  - The route start hangs and fails in `AudioDeviceStart` (Q3).
- The blockers that the spike removed or lowered:
  - A virtual device installs without a reboot (Q1).
  - The default output switches from a script (Q4).
  - The TCC database is writable (Q2), so a grant may be possible. It is not shown to work.
- A virtual 2 channel device cannot answer the questions the X32 answers: channel count, clock and unplug events.
  Even a working tap on a runner would not replace the owner's run for those.

## Follow up candidates

Not filed. The owner decides.

- A second spike to find why `AudioDeviceStart` blocks. Vary one thing per run:
  - Keep the default output on `Apple Virtual Sound Device` and route to `BlackHole 2ch`.
  - Route to the `Null Audio Device`.
  - Run the route without the `coreaudiod` restart in the same step.
  - Add a timeout around the route, so a hung start does not take 5 minutes.
- A second spike for a sure source of audio. `afplay` was not listed as a process with a bundle id.
  Try a small signed test app or a Swift tool that plays the tone and has a bundle id.
- A second spike for the permission. Find the real service name of the audio capture permission in the SDK or in
  a TCC log on a real Mac, then write that row for the client that the check uses.
- Check the BlackHole licence before any use in CI.
- Move the signature part of step 1 into a check on the release asset, if `app-release.yaml` does not cover it.
  It does run `task bundle:verify`, so this may already be done.
