#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Submits a zip of the signed app to Apple's notary service, polls for the result and staples the
# ticket to the app. Run by `task bundle:notarize`. Zip the app again afterwards: the zip that was
# submitted does not carry the ticket.
#   scripts/notarize.sh <zip> <path to .app>
# The zip is uploaded without --wait. The script then polls `notarytool info` every NOTARY_POLL_INTERVAL
# seconds until the status is no longer In Progress or NOTARY_TIMEOUT is used up. The limit counts the
# slept seconds, so the real time is a little longer. app-release.yaml sizes its job timeout from it:
# the default 45m plus the other steps of the job (about 30m) fit the 75 minutes of that job.
# A timeout prints the submission id, says it may still be processing and exits 1. The notary service
# keeps processing. A rerun continues that submission with NOTARY_SUBMISSION_ID instead of uploading again.
# Caveat: a stapled ticket belongs to the signed code of the submitted zip. A rerun that builds and signs
# the app again may produce other code, and the ticket of the old id then does not match it. The id only
# helps when the app is the same.
# Environment, an App Store Connect team API key:
#   APPLE_NOTARY_KEY_ID          key id.
#   APPLE_NOTARY_ISSUER_ID       issuer id.
#   APPLE_NOTARY_KEY_P8_BASE64   base64 of the .p8 private key file.
#   NOTARY_TIMEOUT               optional limit of the polling, default 45m. An integer with an optional
#                                suffix s, m or h (seconds without one).
#   NOTARY_POLL_INTERVAL         optional seconds between two polls, at least 1, default 30.
#   NOTARY_SUBMISSION_ID         optional id of an earlier submission (a UUID, not a secret). The zip is not
#                                uploaded, that submission is polled.
#   RUNNER_TEMP                  base folder of the decoded key, else TMPDIR, else /tmp.
# The key file is written with mode 0600 into a folder only this user can read and removed on every
# exit. No value of a secret is ever printed. On a rejection the notary log is printed: it holds the
# findings for the submitted files and no credential.
set -euo pipefail
set +x

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <zip> <path to .app>" >&2
  exit 2
fi
zip="$1"
app="${2%/}"

fail() {
  echo "$1" >&2
  exit 1
}

for name in APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID APPLE_NOTARY_KEY_P8_BASE64; do
  # Names only. The value is never printed.
  [ -n "${!name:-}" ] || fail "${name} is empty: notarization needs it"
done
resume="${NOTARY_SUBMISSION_ID:-}"
if [ -n "${resume}" ]; then
  [[ "${resume}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
    fail "NOTARY_SUBMISSION_ID is not a UUID"
else
  [ -f "${zip}" ] || fail "no zip at ${zip}"
fi
[ -d "${app}/Contents" ] || fail "not an app bundle: ${app}"

# Seconds of a duration such as 90, 90s, 45m or 1h. $2 names the variable for the error.
seconds() {
  [[ "$1" =~ ^([0-9]+)([smh]?)$ ]] || fail "$2 is not a duration like 90s, 45m or 1h"
  case "${BASH_REMATCH[2]}" in
    m) echo $((BASH_REMATCH[1] * 60)) ;;
    h) echo $((BASH_REMATCH[1] * 3600)) ;;
    *) echo "${BASH_REMATCH[1]}" ;;
  esac
}
limit="$(seconds "${NOTARY_TIMEOUT:-45m}" NOTARY_TIMEOUT)"
interval="$(seconds "${NOTARY_POLL_INTERVAL:-30}" NOTARY_POLL_INTERVAL)"
[ "${interval}" -ge 1 ] || fail "NOTARY_POLL_INTERVAL must be at least 1"

base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
umask 077
work="$(mktemp -d "${base%/}/audio-router-signing.XXXXXXXX")"
trap 'rm -rf "${work}"' EXIT
key="${work}/AuthKey.p8"
# base64 --decode works with the macOS base64 and with GNU coreutils.
printf '%s' "${APPLE_NOTARY_KEY_P8_BASE64}" | base64 --decode >"${key}" ||
  fail "APPLE_NOTARY_KEY_P8_BASE64 is not valid base64"
chmod 600 "${key}"
grep -q -- '-----BEGIN PRIVATE KEY-----' "${key}" ||
  fail "APPLE_NOTARY_KEY_P8_BASE64 does not decode to a .p8 private key"

auth=(--key "${key}" --key-id "${APPLE_NOTARY_KEY_ID}" --issuer "${APPLE_NOTARY_ISSUER_ID}")

# Reads one top level string of the JSON result, empty when it is missing or the text is no JSON.
field() {
  plutil -extract "$1" raw -o - - <<<"$2" 2>/dev/null || true
}

if [ -n "${resume}" ]; then
  id="${resume}"
  echo "continuing submission ${id}, nothing is uploaded"
else
  echo "submitting ${zip}"
  result="$(xcrun notarytool submit "${zip}" "${auth[@]}" --output-format json)" ||
    fail "the upload failed"
  printf '%s\n' "${result}"
  id="$(field id "${result}")"
  [ -n "${id}" ] || fail "the upload gave no submission id"
  echo "submission id ${id}"
fi

# A failed poll (network, service) is retried. Five in a row stop the run, so an auth error does not
# wait out the whole limit.
elapsed=0
errors=0
state=""
result=""
while :; do
  status=0
  result="$(xcrun notarytool info "${id}" "${auth[@]}" --output-format json)" || status=$?
  if [ "${status}" -eq 0 ]; then
    errors=0
    state="$(field status "${result}")"
    echo "submission ${id}: ${state:-no status}"
    if [ -n "${state}" ] && [ "${state}" != "In Progress" ]; then
      break
    fi
  else
    errors=$((errors + 1))
    echo "could not read the status of ${id} (notarytool exit ${status}, ${errors} in a row)" >&2
    [ "${errors}" -lt 5 ] ||
      fail "giving up on submission ${id}, it may still be processing: rerun with NOTARY_SUBMISSION_ID=${id}"
  fi
  if [ "${elapsed}" -ge "${limit}" ]; then
    echo "timed out after ${limit}s: submission ${id} may still be processing." >&2
    echo "Continue it with NOTARY_SUBMISSION_ID=${id}. The ticket only fits an app with the same signed code." >&2
    exit 1
  fi
  sleep "${interval}"
  elapsed=$((elapsed + interval))
done

printf '%s\n' "${result}"
if [ "${state}" != Accepted ]; then
  echo "notarization failed: status '${state}'" >&2
  xcrun notarytool log "${id}" "${auth[@]}" || echo "could not fetch the notary log of ${id}" >&2
  exit 1
fi

xcrun stapler staple "${app}"
xcrun stapler validate "${app}"
echo "notarized and stapled ${app} (submission ${id})"
