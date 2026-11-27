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
  It runs on release events and on the notary resume run on a tag.
- Its `homebrew` job pushes the cask to the tap with a token of the release app scoped to `homebrew-tap`.
  The job order is `bundle`, `verify-asset`, `homebrew`. On a release event `homebrew` starts only after
  `verify-asset` succeeded. A manual `cask-tag` run on the default branch skips the first two and still starts it.
  The notary resume run on a tag does not start `homebrew`.
- The cask strips no quarantine attribute. A notarized release should open without a Gatekeeper warning.
  Not verified until the first notarized release ran.
- `lint:license` in the Taskfile and `find-commands` in `checks.yaml` are kept in step by hand.
