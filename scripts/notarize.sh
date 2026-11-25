#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Submits a zip of the signed app to Apple's notary service, waits for the result and staples the
# ticket to the app. Run by `task bundle:notarize`. Zip the app again afterwards: the zip that was
# submitted does not carry the ticket.
#   scripts/notarize.sh <zip> <path to .app>
# Environment, an App Store Connect team API key:
#   APPLE_NOTARY_KEY_ID          key id.
#   APPLE_NOTARY_ISSUER_ID       issuer id.
#   APPLE_NOTARY_KEY_P8_BASE64   base64 of the .p8 private key file.
#   NOTARY_TIMEOUT               optional limit of the wait, default 30m (notarytool --timeout syntax).
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
[ -f "${zip}" ] || fail "no zip at ${zip}"
[ -d "${app}/Contents" ] || fail "not an app bundle: ${app}"

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

echo "submitting ${zip}"
status=0
result="$(xcrun notarytool submit "${zip}" "${auth[@]}" --wait --timeout "${NOTARY_TIMEOUT:-30m}" \
  --output-format json)" || status=$?
printf '%s\n' "${result}"
id="$(field id "${result}")"
state="$(field status "${result}")"
if [ "${status}" -ne 0 ] || [ "${state}" != Accepted ]; then
  echo "notarization failed: status '${state:-unknown}', notarytool exit ${status}" >&2
  if [ -n "${id}" ]; then
    xcrun notarytool log "${id}" "${auth[@]}" || echo "could not fetch the notary log of ${id}" >&2
  fi
  exit 1
fi

xcrun stapler staple "${app}"
xcrun stapler validate "${app}"
echo "notarized and stapled ${app} (submission ${id})"
