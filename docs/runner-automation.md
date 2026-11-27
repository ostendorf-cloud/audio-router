# Hardware checklist on a macOS runner

Issue 60. This page says which steps of `docs/hardware-checklist.md` could run without the owner.
Status: desk analysis only. No spike ran on a Mac or on a hosted runner.
Every class below is a hypothesis from reading the checklist and the code. Nothing here is measured.
The first column of the spike table is the work that is still open.

## Method and limits

- Source of the steps: `docs/hardware-checklist.md` at the commit of this page.
- Source of the classes: reading what each step needs (a prompt, a click, a physical action, a listening test).
- No GitHub documentation page was read for this page. Every statement about the hosted runner is an assumption.
- Pages to read before the spike counts as evidence:
  - `https://docs.github.com/en/actions/using-github-hosted-runners/using-github-hosted-runners/about-github-hosted-runners`
  - `https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md`
    (installed software of the macOS image, check the image that `macos-latest` points to)

## Spike questions

Each question needs the command and its output from a real Mac and from a throwaway workflow on a branch.
The throwaway workflow does not exist yet. It must not reach `main`.

| Question | Real Mac | Hosted runner | Candidate command |
| --- | --- | --- | --- |
| Can a virtual device be installed | not verified | not verified | `brew install --cask blackhole-2ch`, then `.build/release/audio-router-proto devices` |
| Can the capture permission be granted without a prompt | not verified | not verified | no command known, see below |
| Does a process tap deliver samples | not verified | not verified | `audio-router-proto route ... --meter` against a playing app |
| Can the default output be switched by a script | not verified | not verified | a tool that sets the default device, not chosen yet |
| Can an app play a known tone | not verified | not verified | `afplay` on a generated sine file |

- Licence of the virtual driver: not checked. Check it before any install in CI.
- Installing a driver needs `coreaudiod` to reload and may need an admin approval. Not verified on a runner.
- Granting the capture permission without a prompt means editing the TCC database or a configuration profile.
  The TCC database is protected by SIP. Whether a runner allows it is not verified.
  The repository names no way. Do not invent one.
- `afplay` as a known app is an idea. Whether the tap finds a bundle id for a command line tool is not verified.
  The checklist uses QuickTime Player (`com.apple.QuickTimePlayerX`).

## Step table

Classes use the three values of the issue.
`CI` means automatable in CI, `local` means automatable locally with a script, `manual` means the owner.
A `CI` or `local` class is provisional and holds only if the spike questions above come out positive.
If they do not, every row that depends on them is `manual`.

| Step | Class | Reason |
| --- | --- | --- |
| 1 First open | manual, part CI | `shasum`, `spctl`, `codesign` and `stapler` can run in CI on the asset. The quarantine flag from a browser download, the Gatekeeper dialog and the menu bar look need a person. `app-release.yaml` already runs the signature checks. |
| 2 Permission prompt (app) | manual | The prompt is the test. A grant without prompt would skip what the step checks. |
| 3 Permission denial (app) | manual | Needs a denied state and a read of the error display. What happens on denial is not measured. |
| 4 Permission flow (tool) | manual | Tests the prompt of the terminal app. |
| 5 Unity with -20 dBFS | local | A tone, a route and `--meter` output can be scripted. Needs the permission and a tap, so it depends on the spike. The app half (Settings meter) is visual. |
| 6 Two routes on one device | local | Scriptable with two tools and a 32 channel device. A virtual device has fewer channels, so the result is not the X32 result. |
| 7 Two routes on two devices | local | Same as step 6 with two virtual devices. Not the same as real hardware. |
| 8 Unplug and replug | manual | A physical cable. Removing a virtual device is not the same event. |
| 8a Unplug while Spotify plays | manual | Physical, and needs Spotify. |
| 8b Replug after 8a | manual | Follows 8a. |
| 8c Flap within one second | manual | Physical timing. |
| 8d Default moves to AirPods | local | The default switch can be scripted with a second device. Whether the app is audible on the new default needs a capture of that device. Not verified. |
| 8e Default returns to the X32 | local | Same as 8d. |
| 8f Default moves to the speakers | local | A runner has no speakers. Needs a Mac. |
| 9 Sample rate change | manual | The X32 changes its own rate. A live mix may be on the desk. |
| 10 App quit and start | local | Scriptable with a playing app. The route state is read in the app only, so the tool or a test hook must expose it. Not verified. |
| 11 Global off | manual | A menu click. UI scripting needs the accessibility permission. |
| 12 Quit restores output | manual | A listening test, and a check for a left over aggregate device by eye. |
| 13 Login restore after reboot | manual | A reboot and a login. |
| 14 Thirty minute run | local | The tool and its meter can run for 30 minutes. It needs the X-USB, because drift is the question. A virtual device has no clock of its own. |
| 15 Second build | manual | Needs two release assets and the permission store. |
| 16 Login item | manual | Login, System Settings and an approval state. |
| 17 Live meters | manual | Visual, and Activity Monitor numbers. |
| 17a App volume | local | The tool meter can be read while a script moves the volume. How to move the QuickTime Player volume by script is not verified. |
| 18 Errors and actions | manual | Needs a denied permission and a read of texts and buttons. |
| 19 Route editor | manual | UI interaction. |
| 20 Settings opens in front | manual | Window focus, visual. |

## Reading the table

- No step is proven automatable in CI.
  The only CI candidate is the signature part of step 1, and the release workflow runs it already.
- The `local` rows share one dependency: a permission grant without a prompt on the Mac that runs them.
  That is a spike question, not a fact.
- A virtual device cannot answer the questions the X32 answers: channel count, clock and unplug events.
  A passing scripted run would not replace the owner's run for those.
- Follow up issues are not filed.
  The issue asks for them only when at least one step is automatable, and the spike has not shown that.

## Next step

- Run the five spike questions on a real Mac, then on a throwaway workflow on a branch.
- Paste the commands and outputs into this page and change `not verified` where measured.
- Re-classify the rows. File one issue per step group that stays `CI` or `local`.
