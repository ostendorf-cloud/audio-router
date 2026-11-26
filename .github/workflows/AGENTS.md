# Workflows

- `codeql.yaml` scans the workflow files only (language `actions`).
  The shared reusable workflow runs on Linux and has no Swift build mode, so Swift code is not scanned yet.
- The workflow pins (`actions/checkout`, `jdx/mise-action` and the shared `ostendorf-cloud/workflows` calls
  at `v0.2.2`) are copied from `ostendorf-cloud/burnlink/.github/workflows`.
  A newer tag of `ostendorf-cloud/workflows` exists locally (`v0.6.0`), its inputs were not checked against
  this repository.
- `release-me.yaml` (repository root) has no `files` list, because a Swift package has no version file.
  The version lives in the git tag and `CHANGELOG.md`.
- `release.yaml` and `renovate.yaml` are copied from burnlink at the same pins.
  `release.yaml` builds and publishes no binary.
- `renovate.json` extends `github>ostendorf-cloud/workflows#v0.3.0` like govue, gitcd and wishlist.
  The `renovate.yaml` caller has no `workflow_run` trigger, workflows#74 is not merged.
- Local builds, the `bundle` CI job and a manual dry run of `app-release.yaml` are signed ad hoc,
  because only a release run gets the signing secrets. They are not notarized.
- `app-release.yaml` signs with the Developer ID, notarizes, staples and attaches the arm64 zip to a published
  release. It runs `task bundle`, `task bundle:verify`, `task bundle:zip`, `task bundle:notarize`, then
  `task bundle:verify` and `task bundle:zip` again on the stapled app. A missing secret fails the release.
- Its `homebrew` job pushes the cask to the tap with a token of the release app scoped to `homebrew-tap`.
- The cask strips no quarantine attribute. A notarized release should open without a Gatekeeper warning.
  Not verified until the first notarized release ran.
- `lint:license` in the Taskfile and `find-commands` in `checks.yaml` are kept in step by hand.
