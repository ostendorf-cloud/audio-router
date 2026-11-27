# Workflows

- `codeql.yaml` scans the workflow files only (language `actions`).
  The shared reusable workflow runs on Linux and has no Swift build mode, so Swift code is not scanned yet.
- The workflows were copied from `ostendorf-cloud/burnlink/.github/workflows`. The pins now are
  `actions/checkout` v7.0.1, `jdx/mise-action` v5.3.0, `actions/upload-artifact` v7.0.2,
  `actions/create-github-app-token` v3.4.0, `ostendorf-cloud/release-me/action` v0.5.3 and the shared
  `ostendorf-cloud/workflows` calls at v0.8.0.
- `release-me.yaml` (repository root) has no `files` list, because a Swift package has no version file.
  The version lives in the git tag and `CHANGELOG.md`.
- `release.yaml` builds and publishes no binary.
- `renovate.json` extends `github>ostendorf-cloud/workflows#v0.8.0`.
  The `renovate.yaml` caller has no `workflow_run` trigger, workflows#74 is not merged.
- Local builds, the `bundle` CI job and a manual dry run of `app-release.yaml` are signed ad hoc,
  because only a release run gets the signing secrets. They are not notarized.
- `app-release.yaml` signs with the Developer ID, notarizes, staples and attaches the arm64 zip to a published
  release. It runs `task bundle`, `task bundle:verify`, `task bundle:zip`, `task bundle:notarize`, then
  `task bundle:verify` and `task bundle:zip` again on the stapled app. A missing secret fails the release.
- Its `verify-asset` job downloads the published zip and `.sha256`, checks the hash, compares it
  with the hash the `bundle` job recorded and runs
  `VERIFY_SIGNATURE=notarized scripts/verify-signature.sh` on the unzipped app.
- Its `homebrew` job pushes the cask to the tap with a token of the release app scoped to `homebrew-tap`.
- The job order is `bundle`, `verify-asset`, `homebrew`. The kinds of run:
  - A release event runs all three. `verify-asset` follows a successful `bundle`, `homebrew` follows a
    successful `verify-asset`.
  - The notary resume run (manual, on a tag, with `notary-submission-id`) runs `bundle` and `verify-asset`.
    It does not start `homebrew`.
  - A manual `cask-tag` run on the default branch skips `bundle`, runs `verify-asset` on the asset of that tag
    and starts `homebrew` only after it succeeded. A failed check pushes no cask.
  - A dry run (manual, empty `cask-tag`) runs `bundle` only and publishes nothing.
- A `cask-tag` run has no `bundle` job to compare with, so `verify-asset` leaves the recorded hash comparison out.
  The `.sha256` check, the signature and the notarization checks stay.
  A tag whose asset is not signed with a Developer ID, notarized and stapled fails the check and gets no cask.
  That is intended, it covers the ad hoc signed v0.1.0.
- A `cask-tag` run checks out the default branch, never the tag input. The check uses the current
  `scripts/verify-signature.sh` and `Resources/AudioRouter.entitlements`. An older release signed with other
  entitlements fails the check. The alternative, the scripts of the tag, would trust old code.
- The cask strips no quarantine attribute. A notarized release should open without a Gatekeeper warning.
  Not verified until the first notarized release ran.
- `lint:license` in the Taskfile and `find-commands` in `checks.yaml` are kept in step by hand.
