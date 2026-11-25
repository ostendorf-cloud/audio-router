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
- A step marked `depends on issue N` needs that feature.
  Until it exists, write `not testable yet` in `Result:` and leave both boxes empty.
  Issues 20 to 24 are all in scope for v0.1.0, so the release does not pass with such a step open.
- Where the expected result says `to be recorded, no reference yet`, no measurement exists.
  Record the observed value. Pass or Fail is then the owner's judgement.
- Do not fill a field from memory or from the findings. Measure again in this run.

## Header

- macOS version and build (`sw_vers`):
- App version (`CFBundleShortVersionString`):
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

- Do: download the zip and the `.sha256` file in a browser, so the quarantine flag is set.
  Put both in one folder and run:

  ```sh
  shasum -a 256 -c audio-router-<version>-arm64.zip.sha256
  ```

  Unzip with Finder. Open `audio-router.app` by double click.
- Expected: the checksum line reports `OK`. Gatekeeper blocks the first open, because the app is
  ad hoc signed and not notarised (README, Install). The block is expected, not a defect.
- Then open it with one of the three documented ways.
  Right click, Open, or System Settings, Privacy & Security, Open Anyway, or
  `xattr -dr com.apple.quarantine <path to the app>`.
- Expected: after that the app starts, a speaker icon appears in the menu bar and no Dock icon
  (`LSUIElement`). The menu has a Quit item.
  Record the exact Gatekeeper text and which way you used.
- Depends on issue 20 for anything in the menu beyond Quit.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 2. Permission prompt for the app

- Do: start with no stored grant for the app. Create a route in the app and enable it.
  Depends on issues 21 (route editor) and 23 (permission and route errors).
  Until 21 exists, the prompt cannot be triggered from the app. Step 4 covers the tool.
- Expected: the system audio capture permission prompt appears once. Record the name it shows and
  whether the text is the usage string `NSAudioCaptureUsageDescription` of the app bundle.
  Reference: to be recorded, no reference yet (concept, Unverified for the app).
- After Allow: the route reaches `running`.
  The app is silent on its normal output while it routes.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 3. Permission denial in the app

- Do: deny the prompt, or remove the grant in System Settings, Privacy & Security.
  Enable a route. Depends on issue 23 for the error display.
- Expected: record what the app shows. Either the start fails with an OSStatus (the engine ends in
  `retriesExhausted`) or audio arrives as silence (the engine shows the `noSignal` warning after
  10 seconds). Which one happens is not measured, no reference yet (`AGENTS.md`, known limits).
- Expected: the error text names the right place in System Settings. The app plays normally on its
  own output, and no tap or aggregate device is left behind.
- Then grant the permission again. Use the retry action of the menu, or switch the route off
  and on. The retry action depends on issue 23. The route reaches `running`.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 4. Permission flow of the tool (findings section 1)

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

- Do: play your -20 dBFS 1 kHz sine in QuickTime Player, default output on the X-USB. Run:

  ```sh
  .build/release/audio-router-proto route --bundle-id com.apple.QuickTimePlayerX --device <uid> \
    --channels 1,2 --meter
  ```

- Expected: `tap format: 48000 Hz, 32 channels`. `tap peak` -20.0 dBFS and `tap rms` -23.0 dBFS,
  `out` equal to `tap`, unity within 0.2 dB (the findings criterion). No `warning:` line.
  The signal line shows exactly `1,2` on the tap side.
- Do (app): repeat with the app meter and the same route. Depends on issues 21 and 22.
  Expected: the meter reads -20 dBFS peak, unity within 0.2 dB.
  The X32 USB return meter matches an unrouted run at the same volumes.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 6. Two routes on the X-USB at once (findings section 5, item 2)

- Do: route two apps, QuickTime Player and Spotify, to different channel pairs of the X-USB.
  Both play. With the tool, in two terminals:

  ```sh
  .build/release/audio-router-proto route --bundle-id com.apple.QuickTimePlayerX --device <uid> \
    --channels 1,2 --meter
  .build/release/audio-router-proto route --bundle-id com.spotify.client --device <uid> \
    --channels 3,4 --meter
  ```

  With the app: two enabled routes. Depends on issue 21.
- Expected: both routes start and stay up. Each X32 pair carries only its own app. Both apps are
  silent on their normal output while routed. Not measured so far, no reference yet.
  Record any refusal, error text, glitch or dropout.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 7. Two routes on two different devices (findings section 5, item 1)

- Do: use AirPods or a USB interface as the second device. Each app plays to its own
  device. Run two `route` commands, one per device uid.
- Expected: both run together, no glitch. Not measured, no reference yet.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## C. Device and app events

### 8. Unplug and replug

- Do: with one route running, unplug the X32 USB cable. Wait 10 seconds. Plug it in again.
  Findings section 5 item 4 asks the same for the tool: run `route`, then unplug.
- Expected: the tool tears down cleanly and exits, no hang. In the app the route goes to
  `waitingForDevice` and the app plays normally. The loss stops the route within about 50 ms,
  because a removal is confirmed by a second read. The return still waits about 1.5 s (the quiet
  period of the device watcher). After the replug the route returns to `running` without a click.
  Record both times. The app is silent on its normal output again.
  No tap or aggregate device is left behind.
  Depends on issues 20 and 22 for status display.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8a. Unplug while Spotify plays on channels 3 and 4

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

- Do: plug the cable in again.
- Expected: the route returns to `running` without a click after about 1.5 s plus the start.
  The app is silent on its normal output again. Time until audio on channels 3 and 4:
  to be recorded, no reference yet. Record any left over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8c. Flap within one second

- Do: unplug the cable and plug it in again within 1 second.
- Expected: the app is audible on the default output during the gap and the route starts once
  after the return. Gap and start time: to be recorded, no reference yet.
  Record the route state, the warning text and any left over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8d. The default output moves to AirPods while an X32 route runs

- Do: with the X32 route running, connect the AirPods so macOS makes them the default output.
- Expected: the route pauses and goes to `waitingForDevice`. The app is audible on the AirPods.
  Verify it is NOT muted. A failure here is a release blocker.
  Gap until the app plays on the AirPods: to be recorded, no reference yet.
  Record the route state and the warning text. Record any left over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8e. The default output returns to the X32

- Do: set the default output back to the X-USB.
- Expected: the route resumes without a click after about 1.5 s plus the start. The app is silent
  on its normal output again. Time until audio on the routed channels: to be recorded, no
  reference yet. Record any left over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 8f. The default output moves to the speakers

- Do: with the X32 route running, set the MacBook speakers as the default output.
- Expected: the same as 8d with the speakers. The route pauses, the app is audible on the
  speakers and not muted. A muted app is a release blocker.
  Gap: to be recorded, no reference yet. Record the route state, the warning text and any left
  over tap or aggregate device.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 9. Sample rate change on the X32

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

- Do: with a route running for QuickTime Player, quit QuickTime Player. Wait 10 seconds. Start it
  again and play the sine.
- Expected: the route goes to `waitingForApp` on quit and to `running` after the restart, without a
  click. The restarted app is silent on its normal output while routed.
  Depends on issues 21 and 22 for the visible state.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 11. Global off

- Do: with two routes running, switch global off in the menu, then on again.
  Depends on issue 20.
- Expected: after off, every route is down and both apps play normally on their own output at once.
  No tap or aggregate device is left behind. After on, both routes return to `running`.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## D. Quit, login and long run

### 12. Quit restores normal output

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

- Do: enable the login item in the app. Reboot the Mac. Log in. Do not open the app yourself.
  Depends on issue 24 (login item) and issue 21 (stored routes).
- Expected: the app starts at login, shows its menu bar icon, loads the stored routes and the routes
  reach `running` once their device and app are present. `SMAppService` with an ad hoc signed app is
  not measured, no reference yet. Record whether macOS shows a login item approval notice.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

### 14. Thirty minute run for drift

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

- Do: after step 2 granted the permission, install a second ad hoc signed build over the first.
  Use the next release asset, or a second `task bundle` of the same commit with a new `VERSION`.
  Open it past Gatekeeper as in step 1. Enable a route.
- Expected: to be recorded, no reference yet. The README says each new release asks for the
  permission again, decision D11 accepts that, and TCC behaviour with ad hoc signatures is not
  verified. Record: prompt yes or no, and whether the old entry stays in System Settings.
- Result:
- Notes:
- [ ] Pass  [ ] Fail

## Not covered by this list

- The MacBook speaker rows, a stereo input device and a device with several input streams
  (open in `docs/prototype-findings.md`, not part of the X32 release check).
- macOS versions below the one in the header (findings section 6).
- Notarisation. The app is ad hoc signed.

## Sign-off

- All steps passed, or the exceptions are named in Notes:
- Tester and date:
