# Depends on the infrastructure repository

This repository was created by hand. Until the infrastructure repository covers it, these are set outside it.

## Still missing

- A ruleset on `main`: required checks, merge method, no direct push.
  The check names below come from the job ids in `checks.yaml` and the called workflows' job names.
  Copy the exact names from a pull request run before writing the ruleset.
  - `fmt`, `build`, `test`, `swiftui-macros`, `cask`, `cask-audit`, `signing`, `markdownlint`, `yamllint`,
    `actionlint`
  - `renovate-config / Renovate configuration is valid`
  - `license / License headers`
  - `signoff / Every commit carries a DCO sign-off`
  - the app check `DCO`
- Allow auto-merge is off. Turn it on for the repository.
- Private vulnerability reporting is off. `SECURITY.md` names it as the preferred channel.

## Already provided by the organisation

- The variables `GH_APP_RELEASE_CLIENT_ID` and `GH_APP_DEPENDENCIES_APP_ID`.
- The secrets `GH_APP_RELEASE_PRIVATE_KEY`, `GH_APP_DEPENDENCIES_PRIVATE_KEY` and `GH_APP_SECURITY_PRIVATE_KEY`.
- The signing secrets of `app-release.yaml`, visible to this repository only: `APPLE_CERT_P12_BASE64`,
  `APPLE_CERT_PASSWORD`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, `APPLE_NOTARY_KEY_P8_BASE64` and
  `APPLE_TEAM_ID`, and the variable `APPLE_SIGNING_IDENTITY`.
  The workflow reads `APPLE_TEAM_ID` nowhere: the identity carries the team id.
- The labels `dependencies` and `release: pending`, `release: tagged`, `release: alpha`, `release: beta`,
  `release: rc`.
- The security app is installed, its `DCO` check ran.

## Not verified

- That the release and dependencies GitHub Apps are installed on this repository.
- That the release app is installed on `ostendorf-cloud/homebrew-tap`.
  gitcd's `homebrew` job mints its tap token from the same app.
