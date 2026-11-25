#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Creates or removes the temporary keychain that holds the Developer ID Application certificate on a
# release runner. The release workflow calls it, see .github/workflows/app-release.yaml.
#   scripts/signing-keychain.sh create
#   scripts/signing-keychain.sh delete
# Environment:
#   SIGNING_KEYCHAIN        path of the keychain file to create or remove. delete does nothing without it.
#   APPLE_CERT_P12_BASE64   create: base64 of the .p12 with the certificate, its key and the intermediate.
#   APPLE_CERT_PASSWORD     create: password of the .p12.
#   SIGNING_IDENTITY        create: the identity the keychain must hold, "Developer ID Application: ...".
#   RUNNER_TEMP             base folder of the decoded .p12, else TMPDIR, else /tmp.
# The keychain password is random per run and never leaves this script. The decoded .p12 lives in a
# folder only this user can read and is removed on every exit. delete also removes such folders left by
# a killed run, from this script and from scripts/notarize.sh. No value of a secret is ever printed.
set -euo pipefail
set +x

if [ "$#" -ne 1 ]; then
  echo "usage: $0 create|delete" >&2
  exit 2
fi
base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
base="${base%/}"
keychain="${SIGNING_KEYCHAIN:-}"

fail() {
  echo "$1" >&2
  exit 1
}

create() {
  local name
  for name in SIGNING_KEYCHAIN APPLE_CERT_P12_BASE64 APPLE_CERT_PASSWORD SIGNING_IDENTITY; do
    # Names only. The value is never printed.
    [ -n "${!name:-}" ] || fail "${name} is empty: a signed release needs it"
  done
  case "${SIGNING_IDENTITY}" in
    "Developer ID Application: "*) ;;
    *) fail "SIGNING_IDENTITY must name a Developer ID Application identity, got '${SIGNING_IDENTITY}'" ;;
  esac
  [ ! -e "${keychain}" ] || fail "${keychain} exists already"

  umask 077
  work="$(mktemp -d "${base}/audio-router-signing.XXXXXXXX")"
  trap 'rm -rf "${work}"' EXIT
  p12="${work}/certificate.p12"
  # base64 --decode works with the macOS base64 and with GNU coreutils.
  printf '%s' "${APPLE_CERT_P12_BASE64}" | base64 --decode >"${p12}" || fail "APPLE_CERT_P12_BASE64 is not valid base64"
  [ -s "${p12}" ] || fail "APPLE_CERT_P12_BASE64 decodes to an empty file"

  local password
  password="$(openssl rand -hex 32)"
  [ "${#password}" -eq 64 ] || fail "openssl rand returned no password"
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::add-mask::${password}"
  fi

  security create-keychain -p "${password}" "${keychain}"
  # Lock after six hours, longer than any job, and on sleep.
  security set-keychain-settings -lut 21600 "${keychain}"
  security unlock-keychain -p "${password}" "${keychain}"
  # -T lets codesign use the key without a prompt. No -A, so no other tool gets that.
  security import "${p12}" -k "${keychain}" -f pkcs12 -P "${APPLE_CERT_PASSWORD}" -T /usr/bin/codesign
  rm -f "${p12}"
  # Without the partition list codesign would wait for a dialog nobody answers. The output lists key
  # attributes only, it is dropped to keep the log short.
  security set-key-partition-list -S apple-tool:,apple: -s -k "${password}" "${keychain}" >/dev/null

  # Put the keychain first in the user search list and keep the others.
  local line
  local -a keychains=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [ -z "${line}" ] || keychains+=("${line}")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${keychain}" ${keychains[@]+"${keychains[@]}"}

  local identities
  identities="$(security find-identity -v -p codesigning "${keychain}")"
  printf '%s\n' "${identities}"
  grep -qF "\"${SIGNING_IDENTITY}\"" <<<"${identities}" ||
    fail "the keychain holds no valid code signing identity '${SIGNING_IDENTITY}'"
  echo "keychain ready: ${keychain}"
}

delete() {
  local status=0 dir
  if [ -n "${keychain}" ] && [ -e "${keychain}" ]; then
    security delete-keychain "${keychain}" || status=1
  fi
  for dir in "${base}"/audio-router-signing.*; do
    [ -e "${dir}" ] || continue
    rm -rf "${dir}" || status=1
  done
  if [ "${status}" -ne 0 ]; then
    fail "cleanup failed, see above"
  fi
  echo "signing keychain and key files removed"
}

case "$1" in
  create) create ;;
  delete) delete ;;
  *)
    echo "usage: $0 create|delete" >&2
    exit 2
    ;;
esac
