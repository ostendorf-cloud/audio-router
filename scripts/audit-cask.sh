#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Usage: audit-cask.sh <cask file>
#
# Runs `brew audit --cask --strict` and `brew style --cask` on a rendered cask,
# the way gitcd's scripts/audit-formula.sh does for its formula: the cask is
# committed into a scratch git repository, that repository is tapped under its
# own name, the one cask is trusted, both commands run on it, and trust and tap
# are removed at the end, on every exit path. It refuses to run when the
# scratch tap name is already tapped, so it never touches a tap that was there
# before.
#
# No --online: the audit does not download the zip, so it checks neither the
# hash nor the signature. It says nothing about the ad hoc signature or about
# Gatekeeper.
#
# CI only: it needs Homebrew, which the macOS runner carries. It executes
# nothing of the cask, but brew loads it as Ruby on this machine. Run it
# locally only on a machine where a scratch tap is acceptable.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <cask file>" >&2
  exit 2
fi

cask="$1"
tap="${AUDIT_TAP:-audio-router-ci/audit}"
name="$(basename "${cask}" .rb)"
ref="${tap}/${name}"
work=""
tapped=""
trusted=""

cleanup() {
  # Trust is stored outside the tap, so untapping is not assumed to drop it.
  if [ -n "${trusted}" ]; then
    brew untrust --cask "${ref}" >/dev/null 2>&1 || true
  fi
  if [ -n "${tapped}" ]; then
    brew untap --force "${tap}" >/dev/null 2>&1 || true
  fi
  if [ -n "${work}" ]; then
    rm -rf "${work}"
  fi
}

die() {
  echo "audit-cask: $*" >&2
  exit 2
}

trap cleanup EXIT

[ -s "${cask}" ] || die "${cask} is missing or empty"
[[ ${name} =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] || die "unexpected cask name '${name}'"
command -v brew >/dev/null 2>&1 || die "brew not found: this check needs Homebrew on the runner"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1

# The list is read first and searched as a variable: a pipe into grep -q can
# end by SIGPIPE under pipefail and read as "not tapped".
taps="$(brew tap)"
if grep -Fxq "${tap}" <<<"${taps}"; then
  die "${tap} is already tapped: untap it first, this check needs its own scratch tap"
fi

# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/audit-cask.XXXXXXXX")"
mkdir "${work}/Casks"
cp "${cask}" "${work}/Casks/${name}.rb"
git -C "${work}" init --quiet
git -C "${work}" add Casks
git -C "${work}" -c user.name=ci -c user.email=ci@example.invalid commit --quiet -m "cask under audit"

brew tap "${tap}" "${work}"
tapped=1

# brew audit and brew style refuse to load a cask from an untrusted tap. The
# narrow form trusts this one cask only.
trusted=1
brew trust --cask "${ref}"

status=0
brew audit --cask --strict "${ref}" || status=1
brew style --cask "${ref}" || status=1
# The last command's status is the script's: 0 when both passed, 1 otherwise.
[ "${status}" -eq 0 ]
