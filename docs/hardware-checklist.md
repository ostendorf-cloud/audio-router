# Hardware checklist

The owner runs this list on the X32 before each release and records the results.
CI cannot grant the capture permission, create a tap with audio, measure a level or test Gatekeeper.
The release pull request for v0.1.0 stays open and unmerged until every step passes.
Concept: `docs/concepts/audio-router.md`, decision D10.
This list serves issue 28.
Measurements so far: `docs/prototype-findings.md`. This list never edits that file.

## How to use it

- Copy this file for each run, fill it in, and paste the filled copy as a comment in the release
  pull request. Do not commit a filled copy to the repository.
- Fill the header first. Leave a field empty only when it does not apply and say why in Notes.
- Run the steps in order. Later steps assume the state the earlier ones leave.
  Step 15 needs the permission grant that step 2 created.
- Write the observed value in `Result:`. Tick Pass or Fail. Put anything unexpected in `Notes:`.
- The app features of issues 20 to 24 (menu, route editor, live meters, errors and actions, login
  item) are merged, so no step waits for an issue any more.
  If a feature is missing in the build under test, write `not testable yet` in `Result:`,
  leave both boxes empty and say why in Notes. The release does not pass with such a step open.
- Where the expected result says `to be recorded, no reference yet`, no measurement exists.
  Record the observed value. Pass or Fail is then the owner's judgement.
- Each step opens with an `Ownership:` line. It says what stays with the owner and why, or which part a CI job
  could run. The evidence is the step table in [`docs/runner-automation.md`](runner-automation.md) (issue 60).
  The ownership line changes no check of the step.
- Do not fill a field from memory or from the findings. Measure again in this run.

## Header

- macOS version and build (`sw_vers`):
- App version, the full release version such as `0.1.0-rc.2` (`ARFullVersion`, shown in the About view;
  Finder shows only the numeric `CFBundleShortVersionString`):
- Build, kind and identity (release asset name and SHA-256, or the commit of a local build):
- `audio-router-proto` commit (`git rev-parse --short HEAD`):
- Date:
- Tester:
- Device (name and uid from `audio-router-proto devices`):
- Sample rate (as set on the X32 and in Audio MIDI Setup):
- Mac model:

## Setup

The app under test is the release asset: the signed arm64 zip `audio-router-<version>-arm64.zip`
with its `.sha256` file. A local `task bundle` build is not the release asset.
The diagnostic tool is not in the zip. Build it from the same commit as the release:

```sh
swift build -c release
.build/release/audio-router-proto devices
.build/release/audio-router-proto apps
```

- The X32 is connected over USB. This list calls it the X-USB.
  The findings measured it with 32 channels at 48 kHz.
- Test app: QuickTime Player playing your 1 kHz sine files at -6 dBFS and -20 dBFS.
  Use full app volume and the system volume unchanged.
  Copy the files to the Desktop, QuickTime Player cannot read from `/private/tmp`.
- Spotify as the second playing app for the route steps.
  Bundle ids: `com.apple.QuickTimePlayerX` and `com.spotify.client`.
  Find the id of any other app with `.build/release/audio-router-proto apps`.
- A second output device for step 7: AirPods or a USB interface.
- Set the macOS default output to the X-USB. A device stream route only holds audio that goes to
  that device (concept, product constraint).

Findings measured so far, for reference only (macOS 27, X-USB, 32 channels, 48 kHz): the
`device-stream` tap reads unity at -6.0 and -20.0 dBFS (`docs/prototype-findings.md` section 9).
The unity criterion of the findings is `tap peak` within 0.2 dB of the file level.

## A. First open and permission

### 1. First open of the downloaded app

- Ownership: machine part in CI (checksum, `codesign`, `spctl`, `stapler` on the asset), the owner keeps the
  quarantine flag from a browser download, the Gatekeeper dialog and the menu bar look.
  See the step table in [`docs/runner-automation.md`](runner-automation.md).

- Do: download the zip and the `.sha256` file in a browser, so the quarantine flag is set.
  Put both in one folder and run:

  ```sh
  shasum -a 256 -c audio-router-<version>-arm64.zip.sha256
  ```

  Unzip with Finder. Before the first open run:

  ```sh
  spctl -a -vvv -t exec audio-router.app
  codesign -dvv audio-router.app
  xcrun stapler validate audio-router.app
  ```

  Open `audio-router.app` by double click.
- Expected: the checksum line reports `OK`. `spctl` prints `accepted` and `source=Notarized Developer ID`.
  `codesign` shows `flags=0x10000(runtime)`, `Authority=Developer ID Application: ...` and a `Timestamp=` line.
  `stapler` reports that the validate action worked.
- Expected: Gatekeeper shows no "Apple could not verify" warning. A plain notice that the app was downloaded
  from the internet, with an Open button, may still appear. That is not a defect.
- A release up to 0.1.0 is ad hoc signed and Gatekeeper blocks it. For such a build open it with one of the
  ways in the README, Development, and record which way you used.
- Expected: after that the app starts, the audio-router symbol appears in the menu bar and no Dock icon
  (`LSUIElement`). The menu has a Quit item.
  Switch System Settings, Appearance between Light and Dark: the symbol follows the menu bar colour and stays
  readable. Switch Routing off: the symbol gets a slash.
  Record the exact Gatekeeper text, if any.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 2. Permission prompt for the app

- Ownership: stays with the owner. The prompt is the test, and a written TCC row would skip it
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: start with no stored grant for the app. Create a route in the app and enable it.
  Step 4 covers the tool.
- Expected: the system audio capture permission prompt appears once. Record the name it shows and
  whether the text is the usage string `NSAudioCaptureUsageDescription` of the app bundle.
  Reference: to be recorded, no reference yet (concept, Unverified for the app).
- After Allow: the route reaches `running`.
  The app is silent on its normal output while it routes.
- Expected: the app is audible on the destination channel pair.
- Run this step on the release candidate asset of a notarized release before the release is announced.
  The release is signed with the hardened runtime and no `com.apple.security.device.audio-input`
  entitlement. Whether the tap path needs it is not verified (issue 67).
- If the notarized build reaches `running` but stays silent while the app plays: add the entitlement
  `com.apple.security.device.audio-input` (Hardened Runtime, Resource Access) to
  `Resources/AudioRouter.entitlements` in this repository, with this measurement as the reason in the comment of
  that file. Open a pull request for it and cut a new release candidate. Run this step again.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 3. Permission denial in the app

- Ownership: stays with the owner. It needs a denied state and a read of the error display
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: deny the prompt, or remove the grant in System Settings, Privacy & Security.
  Enable a route. Step 18 covers the texts and buttons of the error display in detail.
- Expected: record what the app shows. Either the start fails with an OSStatus (the engine ends in
  `retriesExhausted`) or audio arrives as silence (the engine shows the `noSignal` warning after
  10 seconds). Which one happens is not measured, no reference yet (`AGENTS.md`, known limits).
- Expected: the error text names the right place in System Settings. The app plays normally on its
  own output, and no tap or aggregate device is left behind.
- Then grant the permission again. Switch the route off
  and on. The route reaches `running`.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 4. Permission flow of the tool (findings section 1)

- Ownership: stays with the owner. It tests the prompt and the name of the terminal app
  ([`docs/runner-automation.md`](runner-automation.md), step table).

These are the open items of findings section 1. Record the answers here, not in the findings file.

- Do: check the embedded usage string first:

  ```sh
  otool -s __TEXT __info_plist -v .build/release/audio-router-proto | head -20
  ```

  Start without a grant for the terminal app. This list uses iTerm.
  Reset the grant in System Settings, Privacy & Security, Audio Recording: remove or switch off
  iTerm. Check the pane name on your macOS version. The repository docs name no other way
  to reset it. Run, with QuickTime Player playing the -6 dBFS sine:

  ```sh
  .build/release/audio-router-proto route --bundle-id com.apple.QuickTimePlayerX --device <uid> \
    --channels 3,4 --meter
  ```

- Expected, each to be recorded, no reference yet:
  - The prompt appears on the first `route`: yes or no.
  - The name it shows: the terminal app or `audio-router-proto`.
  - The usage string shown: the embedded one or the terminal app's own.
  - After denial: error text, exit code, or silence. Denied tap as OSStatus or zeroed audio.
  - The error text points to the right place in System Settings.
  - The app that System Settings lists under audio capture after the first run.
  - With the permission missing, the silence warning after 10 seconds
    (`no audio arrived in 10 seconds`) appears.
  - A paused app triggers the same warning (expected yes).
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## B. Routes and level

### 5. Unity with the -20 dBFS sine

- Ownership: stays with the owner. No tap worked on the runner and the app half is visual
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: play your -20 dBFS 1 kHz sine in QuickTime Player, default output on the X-USB. Run:

  ```sh
  .build/release/audio-router-proto route --bundle-id com.apple.QuickTimePlayerX --device <uid> \
    --channels 1,2 --meter
  ```

- Expected: `tap format: 48000 Hz, 32 channels`. `tap peak` -20.0 dBFS and `tap rms` -23.0 dBFS,
  `out` equal to `tap`, unity within 0.2 dB (the findings criterion). No `warning:` line.
  The signal line shows exactly `1,2` on the tap side.
- Do (app): repeat with the same route and read the Settings window bar and number. Step 17 has
  the details of the app meter.
  Expected: the meter reads -20 dBFS peak, unity within 0.2 dB.
  The X32 USB return meter matches an unrouted run at the same volumes.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 6. Two routes on the X-USB at once (findings section 5, item 2)

- Ownership: stays with the owner. One route already fails on the runner, and its virtual devices have 2
  channels, not 32 ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: route two apps, QuickTime Player and Spotify, to different channel pairs of the X-USB.
  Both play. With the tool, in two terminals:

  ```sh
  .build/release/audio-router-proto route --bundle-id com.apple.QuickTimePlayerX --device <uid> \
    --channels 1,2 --meter
  .build/release/audio-router-proto route --bundle-id com.spotify.client --device <uid> \
    --channels 3,4 --meter
  ```

  With the app: two enabled routes.
- Expected: both routes start and stay up. Each X32 pair carries only its own app. Both apps are
  silent on their normal output while routed. Not measured so far, no reference yet.
  Record any refusal, error text, glitch or dropout.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 7. Two routes on two different devices (findings section 5, item 1)

- Ownership: stays with the owner. One route fails on the runner, so two are untested
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: use AirPods or a USB interface as the second device. Each app plays to its own
  device. Run two `route` commands, one per device uid.
- Expected: both run together, no glitch. Not measured, no reference yet.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## C. Device and app events

### 8. Unplug and replug

- Ownership: stays with the owner. It is a physical cable, and removing a virtual driver is a different event
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: with one route running, unplug the X32 USB cable. Wait 10 seconds. Plug it in again.
  Findings section 5 item 4 asks the same for the tool: run `route`, then unplug.
- Expected: the tool tears down cleanly and exits, no hang. In the app the route goes to
  `waitingForDevice` and the app plays normally. The loss stops the route within about 50 ms,
  because a removal is confirmed by a second read. The return still waits about 1.5 s (the quiet
  period of the device watcher). After the replug the route returns to `running` without a click.
  Record both times. The app is silent on its normal output again.
  No tap or aggregate device is left behind.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8a. Unplug while Spotify plays on channels 3 and 4

- Ownership: stays with the owner. It is physical and needs Spotify
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: route QuickTime Player to 1,2 and Spotify to 3,4. Both play. Unplug the X32 USB cable.
- Expected: the route stops within about 50 ms and goes to `waitingForDevice`. Spotify plays
  on the default output, because the released tap no longer mutes it.
  Gap until the app plays on the new default: to be recorded, no reference yet.
  Record the route state and the warning text in the menu or the tool output.
  Record a left over tap or aggregate device (step 12 says how to check).
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8b. Replug after 8a

- Ownership: stays with the owner. It follows 8a
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: plug the cable in again.
- Expected: the route returns to `running` without a click after about 1.5 s plus the start.
  The app is silent on its normal output again. Time until audio on channels 3 and 4:
  to be recorded, no reference yet. Record any left over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8c. Flap within one second

- Ownership: stays with the owner. It is physical timing
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: unplug the cable and plug it in again within 1 second.
- Expected: the app is audible on the default output during the gap and the route starts once
  after the return. Gap and start time: to be recorded, no reference yet.
  Record the route state, the warning text and any left over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8d. The default output moves to AirPods while an X32 route runs

- Ownership: stays with the owner. A script can switch the default, but whether the app is audible on the
  AirPods needs audio from an app and a listener, and the real X32 and AirPods
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: with the X32 route running, connect the AirPods so macOS makes them the default output.
- Expected: the route pauses and goes to `waitingForDevice`. The app is audible on the AirPods.
  Verify it is NOT muted. A failure here is a release blocker.
  Gap until the app plays on the AirPods: to be recorded, no reference yet.
  Record the route state and the warning text. Record any left over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8e. The default output returns to the X32

- Ownership: stays with the owner. The X32 does not exist on the runner, and listening to the result needs a
  person ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: set the default output back to the X-USB.
- Expected: the route resumes without a click after about 1.5 s plus the start. The app is silent
  on its normal output again. Time until audio on the routed channels: to be recorded, no
  reference yet. Record any left over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8f. The default output moves to the speakers

- Ownership: stays with the owner. The runner has no speakers, its `Speakers` output is virtual
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: with the X32 route running, set the MacBook speakers as the default output.
- Expected: the same as 8d with the speakers. The route pauses, the app is audible on the
  speakers and not muted. A muted app is a release blocker.
  Gap: to be recorded, no reference yet. Record the route state, the warning text and any left
  over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 9. Sample rate change on the X32

- Ownership: stays with the owner. The X32 changes its own rate
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Precondition: no live mix on the desk.
- Do: with a route running at 48 kHz, change the rate of the X32 (for example to 44.1 kHz in
  Audio MIDI Setup or on the X32). Change it back afterwards.
- Expected: to be recorded, no reference yet. The documents differ. The concept lists a runtime
  failure on a sample rate change, `AGENTS.md` says a persisting rate mismatch is a warning on
  `running`, never a stop. Record which one happens, the text shown, and whether audio recovers
  at the original rate without restarting the app.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 10. App quit and start

- Ownership: stays with the owner. It needs a playing app and a working route
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: with a route running for QuickTime Player, quit QuickTime Player. Wait 10 seconds. Start it
  again and play the sine.
- Expected: the route goes to `waitingForApp` on quit and to `running` after the restart, without a
  click. The restarted app is silent on its normal output while routed.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 11. Global off

- Ownership: stays with the owner. It is a menu click, and UI scripting on the runner is unverified
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: with two routes running, switch global off in the menu, then on again.
- Expected: after off, every route is down and both apps play normally on their own output at once.
  No tap or aggregate device is left behind. After on, both routes return to `running`.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## D. Quit, login and long run

### 12. Quit restores normal output

- Ownership: stays with the owner. It is a listening test and a check by eye
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: with a route running, quit the app from the menu. Also stop the tool with Ctrl-C in a
  second run.
  This is the listening test the findings mark as not reported (section 9, Not measured).
- Expected: the routed app plays on its normal output again right after quit. Quit returns after the
  teardown, which runs in the order IO proc, aggregate device, tap. The tool also tears down on
  `kill -TERM` and `kill -HUP`. No tap or aggregate device is left behind. Record how you checked
  that, for example `audio-router-proto devices` before and after, or Audio MIDI Setup.
  The repository does not say that either one shows a private aggregate. Not verified.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 13. Login restore after reboot

- Ownership: stays with the owner. It needs a reboot and a login
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: enable the login item in the app. Reboot the Mac. Log in. Do not open the app yourself.
  Step 16 covers the login item with a log out and in, without a reboot.
- Expected: the app starts at login, shows its menu bar icon, loads the stored routes and the routes
  reach `running` once their device and app are present. `SMAppService` with the release app is
  not measured, no reference yet. Record whether macOS shows a login item approval notice.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 14. Thirty minute run for drift

- Ownership: stays with the owner. It needs the X-USB, because drift is the question
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: two routes on the X-USB (step 6), the -6 dBFS sine in a loop in both apps, `--meter` running
  for the tool. Run 30 minutes with no other change. Findings section 9 asks for 60 minutes
  with the tool. This list asks for 30. Run longer if you can and note it.
  Note the `frames` average at the start and at the end.

  ```sh
  .build/release/audio-router-proto route --bundle-id com.apple.QuickTimePlayerX --device <uid> \
    --channels 1,2 --meter 2>&1 | tee drift-a.log
  .build/release/audio-router-proto route --bundle-id com.spotify.client --device <uid> \
    --channels 3,4 --meter 2>&1 | tee drift-b.log
  ```

- Expected: no dropout or crackle, `tap peak` stays at -6.0 dBFS within 0.2 dB, no new warning.
  Drift compensation is skipped in `device-stream` mode. Drift over time is not excluded
  (findings section 9), no reference yet. Findings section 5 item 3 (glitch or drift after
  30 minutes with two routes) is answered here.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## E. Second build

### 15. A second build gets a new permission prompt, or not

- Ownership: stays with the owner. It needs two release assets and the permission store
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: after step 2 granted the permission, install a second build over the first.
  Use the next release asset. Open it as in step 1. Enable a route.
- Expected: to be recorded, no reference yet. Both release assets carry the same Developer ID, so the
  README expects the grant to persist. That is not verified. Record: prompt yes or no, and whether
  the old entry stays in System Settings. Write in Notes whether both builds were notarized releases
  or ad hoc builds: an ad hoc build may prompt again, decision D11 accepted that for 0.1.0.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## F. App shell items

These steps come from the merged app pull requests. They need the app from the release asset,
installed in `/Applications`, with at least one stored route. Where no measurement exists the
expected result says `to be recorded, no reference yet`.

### 16. Login item, restore and status

- Ownership: stays with the owner. It needs a login, System Settings and an approval state
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Precondition: the app is in `/Applications` and the Startup toggle in Settings is on.
- Do: log out and log in again, without a reboot. Do not open the app yourself.
  Open Settings and close it. Switch the app off in System Settings, Login Items, then open
  Settings again without restarting the app. Switch it on there again and reopen Settings once more.
  If macOS shows the approval state (status requires approval), look at the Startup section.
  The approval state may not be reachable on demand. If macOS does not show it, write
  `not reproduced` in Notes for that part.
- Expected: after the login the app starts, the menu bar icon shows and the stored routes come back
  and reach `running` once their device and app are present. This is not measured for the release
  app, to be recorded, no reference yet.
- Expected: after each change in System Settings the toggle shows the real status when Settings is
  opened again. The toggle also follows the status when the app becomes active. Record the toggle
  state for each case.
- Expected: with status requires approval the Startup section shows the hint
  `Approval is likely needed. Allow audio-router in Login Items in System Settings.` and the
  button `Open Login Items`. The button opens System Settings. Record which pane opens.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 17. Live meters in the menu and in Settings

- Ownership: stays with the owner. It is visual, with Activity Monitor numbers
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Precondition: a route runs with QuickTime Player playing the -20 dBFS sine (step 5).
- Do: open the menu. Read the text line of the route. Close the menu. Open Settings and read the bar
  and the number. Close the window.
- Expected: the menu shows a line `name  -xx.x dBFS` per running route, only while the menu is open.
  The Settings window shows a bar from -60 to 0 dBFS and the peak number.
- Expected, unity: peak about -20.0 dBFS and RMS about -23 dBFS. A sine with a peak of -20 dBFS
  has an RMS of -23.01 dBFS. That is arithmetic. The measured value is what the owner records.
  Unity within 0.2 dB is the criterion of the findings (step 5).
  In the window the light bar is the peak, the solid bar in front is the RMS, and the number is
  the peak (`MeterViews.swift`). Read the RMS from the solid bar.
- Do (polling stops): with the menu and the window closed, watch the app in Activity Monitor:
  the columns CPU % and Idle Wake Ups, on the CPU tab. Do the same with the menu open and
  with the Settings window open.
  As a shell check the pid shows with `pgrep -x audio-router`. This line is not verified:
  default `top` has no wakeups column, `top -pid <pid> -stats pid,command,cpu,idlew` is a
  candidate for it.
- Expected: near 0 percent CPU when everything is closed. About 15 wakeups per second while the menu
  or the window is open, because the poller interval is 1/15 s (`MeterPoller.defaultInterval`).
  That is the configured interval, not a measurement. Record the real numbers,
  to be recorded, no reference yet.
- Not verified, record what you see:
  - Whether the tracking notification filter picks the right menu.
  - Whether open menu items redraw their text while the menu is open.
  - Whether the window notifications fire for the Settings scene, so polling stops when it closes.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 17a. Does the tap see the app volume

- Ownership: stays with the owner. It needs a tap and a moving app volume, and neither worked on the runner
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Precondition: this is the volume sub question of issue 5. QuickTime Player plays the -20 dBFS
  sine through the tool route of step 5. System volume unchanged.
- Do: run the tool with `--meter`. Move the volume slider of QuickTime Player itself to two
  positions, for example full and about half. Note `tap peak` and `tap rms` at each position, and
  the slider positions. Repeat the same with an unrouted run if you want a comparison.
- Expected: to be recorded, no reference yet. The question is whether the tap level follows the
  slider, so whether the tap sees the app before or after its own volume. The findings hold the
  hypothesis that the app applies its volume before the tap. This step measures it.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 18. Errors and actions

- Ownership: stays with the owner. It needs a denied permission and a read of texts and buttons
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Precondition: a route that normally runs. Open the menu for each case and read the text under the
  route toggle.
- Do (a, permission denied): remove or deny the capture permission for the app, as in step 3.
  Enable the route.
  Which failure follows is not measured (step 3). Expected is one of two, each with the button
  `Open System Settings` and not `Retry now`:
  - Silence: after 10 seconds the text `No audio from <app> for 10 s although it plays. Likely
    the audio capture permission is missing or denied, ...`.
  - A failed start whose error text names `(create tap)` or `(create aggregate)`: the text
    `The route could not start. The audio capture permission may be missing or denied.` with the
    attempt or retries stopped note.
  Any other failed start shows `The route could not start.` with `Retry now`. Record the exact
  text and button you get. The button opens the generic privacy pane. The anchor of the audio
  capture list is not verified. Record what opens, to be recorded, no reference yet.
  To recover, grant the permission, then switch the route off and on as in step 3.
- Do (b, device gone): unplug the X32. Expected: a text that the device is likely unplugged or
  switched off, and that the route waits for it, with the button `Choose device`.
  Record the text.
- Do (c, default moved): with the X32 plugged in, move the default output to the speakers (step 8f).
  Expected: a different text, that the device is likely no longer the default output and that the
  app plays on the current default output meanwhile, without a button.
  Record both texts. They must differ.
- Do (d, retry): `Retry now` shows for a failed start that is not about the permission, the device
  or the channels, for example an app without an audio process that was refused, and for a failed
  engine start. Such a failure is hard to cause on purpose. If one shows, press `Retry now`.
  Expected: the route starts again and reaches `running` once the cause is gone. If you cannot
  cause it, write `not reproduced` in Notes and leave the boxes empty. Do not fake it.
- Do (e, failed teardown): this is hard to cause on purpose. If a teardown step fails, expected is
  a warning `<n> teardown step(s) failed.` with the hint that a tap or aggregate device likely
  stays until the app quits, and a warning on the menu bar icon. If you cannot cause it, write
  `not reproduced` in Notes and leave the boxes empty. Do not fake it.
- Do (f, paused app): with the permission granted, pause the app, then switch its route on and wait
  15 seconds. The note shows only while no audio arrived since the route started.
  Expected: the menu bar icon stays the speaker, not the triangle. The route line reads `Running`,
  not `Running with warning`. Under it the plain text `<app> plays nothing, likely paused.`
  shows without a button. Play the app and the note goes away. Record the text.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 19. Route editor

- Ownership: stays with the owner. It is UI interaction
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Do: in Settings, create a route (app, device, source pair, destination pair) and save it.
  Edit it and save. Delete it.
  Edit a route that you switched off in the menu and save. Edit a route that is on and save.
  Save a route and toggle another route in the menu right after, within a second or two.
  Open the source picker for the X-USB.
- Expected: create, edit and delete take effect at once. The menu rows follow. A deleted route is
  torn down and the app plays on its normal output.
- Expected: a route that the menu switched off stays off after the edit. The menu switch is not
  stored, an edit never changes the state of the edited route.
- Expected: after a save followed quickly by a toggle in the menu, no route is lost and no toggle
  is undone. Record the final state of every route.
- Expected: the source picker offers the pairs of output stream 0 of the device. That is inferred
  from the first device buffer and not measured, to be recorded, no reference yet. Record the
  pairs it offers for the X-USB. If you have a device with several output streams, record what it
  offers too.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 20. Settings opens in front

- Ownership: stays with the owner. It is window focus, visual
  ([`docs/runner-automation.md`](runner-automation.md), step table).

- Precondition: another app has the focus and its window covers the screen centre.
- Do: open the menu and choose `Settings…` (with an ellipsis). Do it again with the window already
  open behind another app. While the menu is open, change a route state from another place, for
  example quit its app (the route waits for the app), and watch the rows.
- Expected: Settings opens in front of the other windows. The app is an accessory app, so the menu
  action calls `NSApp.activate()` before `openSettings()`. Record whether it works each time.
- Expected: the menu rows update while the menu is open, to be recorded, no reference yet.
  Whether an open menu redraws its items is not verified.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## Not covered by this list

- The MacBook speaker rows, a stereo input device and a device with several input streams
  (open in `docs/prototype-findings.md`, not part of the X32 release check).
- macOS versions below the one in the header (findings section 6).
- The notarization itself. The release workflow checks it with `spctl` and `stapler validate`, step 1
  checks the downloaded asset once more.

## Sign-off

- All steps passed, or the exceptions are named in Notes:
- Tester and date:
