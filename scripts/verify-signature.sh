#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Verifies the signature of an app bundle. Run by `task bundle:verify` and `task bundle:zip`.
#   scripts/verify-signature.sh <path to .app>
# Environment:
#   VERIFY_SIGNATURE   any (default): a valid strict signature, ad hoc or not, with the hardened runtime and
#                      exactly the entitlements of Resources/AudioRouter.entitlements. Local builds use it.
#                      developer-id: any, plus a Developer ID Application authority chain and a secure timestamp.
#                      notarized: developer-id, plus Gatekeeper (spctl) accepts it as notarized and the
#                      stapled ticket validates. The release workflow uses the last two.
#   SIGNING_IDENTITY   optional. With developer-id or notarized, the leaf authority must equal it.
set -euo pipefail
set +x

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <path to .app>" >&2
  exit 2
fi
app="${1%/}"
level="${VERIFY_SIGNATURE:-any}"
case "${level}" in
  any | developer-id | notarized) ;;
  *)
    echo "VERIFY_SIGNATURE must be any, developer-id or notarized, got '${level}'" >&2
    exit 2
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() {
  echo "$1" >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "${app}"

info="$(codesign -dvv "${app}" 2>&1)"
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<<"${info}" ||
  fail "the signature has no hardened runtime flag"

# The signed entitlements must equal the file, so no key slips in, the sandbox included.
signed="$(codesign -d --entitlements - --xml "${app}" 2>/dev/null || true)"
if grep -q 'com.apple.security.app-sandbox' <<<"${signed}"; then
  fail "the signature carries the sandbox entitlement"
fi
want="$(plutil -convert json -o - - <"${root}/Resources/AudioRouter.entitlements")"
if [ -z "${signed}" ]; then
  got="{}"
else
  got="$(plutil -convert json -o - - <<<"${signed}")" || fail "cannot read the signed entitlements"
fi
[ "${got}" = "${want}" ] || fail "the signed entitlements ${got} differ from Resources/AudioRouter.entitlements ${want}"

if [ "${level}" = any ]; then
  echo "signature ok (${level})"
  exit 0
fi

if grep -q '^Signature=adhoc' <<<"${info}"; then
  fail "the signature is ad hoc, expected Developer ID"
fi
leaf="$(awk '/^Authority=/ { print substr($0, 11); exit }' <<<"${info}")"
case "${leaf}" in
  "Developer ID Application: "*) ;;
  *) fail "the leaf authority is '${leaf}', expected Developer ID Application" ;;
esac
if [ -n "${SIGNING_IDENTITY:-}" ] && [ "${leaf}" != "${SIGNING_IDENTITY}" ]; then
  fail "the leaf authority is '${leaf}', expected '${SIGNING_IDENTITY}'"
fi
grep -qx 'Authority=Developer ID Certification Authority' <<<"${info}" ||
  fail "the chain has no Developer ID Certification Authority"
grep -qx 'Authority=Apple Root CA' <<<"${info}" || fail "the chain has no Apple Root CA"
grep -q '^Timestamp=' <<<"${info}" || fail "the signature has no secure timestamp"

if [ "${level}" = developer-id ]; then
  echo "signature ok (${level}: ${leaf})"
  exit 0
fi

assessment="$(spctl -a -vvv -t exec "${app}" 2>&1)" || fail "Gatekeeper rejects the app: ${assessment}"
printf '%s\n' "${assessment}"
grep -qx 'source=Notarized Developer ID' <<<"${assessment}" || fail "Gatekeeper does not see a notarized Developer ID app"
xcrun stapler validate "${app}" || fail "the stapled notarization ticket does not validate"
echo "signature ok (${level}: ${leaf})"
