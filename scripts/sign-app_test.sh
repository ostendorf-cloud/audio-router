#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for sign-app.sh with a fake codesign first on the PATH that logs its calls: the ad hoc and the
# Developer ID arguments, the hardened runtime on every call, the order of nested code, and that a
# required signature never falls back to ad hoc. Runs in an empty temporary directory. The real
# codesign is never involved: that a Developer ID signature is valid is what the release run proves.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sign="${script_dir}/sign-app.sh"
entitlements="$(cd "${script_dir}/.." && pwd)/Resources/AudioRouter.entitlements"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/sign-app-test.XXXXXXXX")"
finished=no
trap 'rm -rf "${work}"; if [ "${finished}" != yes ]; then if [ "${failures:-0}" -eq 0 ]; then echo "test script stopped before its last line" >&2; fi; exit 1; fi' EXIT
cd "${work}"

failures=0
fake_bin="${work}/bin"
mkdir -p "${fake_bin}"
export CALL_LOG="${work}/calls"

cat <<'FAKE_CODESIGN' >"${fake_bin}/codesign"
#!/usr/bin/env bash
echo "codesign $*" >>"${CALL_LOG}"
exit 0
FAKE_CODESIGN
chmod +x "${fake_bin}/codesign"

app="${work}/audio-router.app"
mkdir -p "${app}/Contents/MacOS"
touch "${app}/Contents/MacOS/audio-router"

identity="Developer ID Application: Test Person (TEAM123456)"

# run_case name want_status want_calls [env assignments...]: want_calls is the call log with the
# scratch directory replaced by <dir>.
run_case() {
  local name="$1" want_status="$2" want_calls="$3" status=0 got
  shift 3
  : >"${CALL_LOG}"
  env -u SIGNING_IDENTITY -u SIGNING_KEYCHAIN -u SIGNING_REQUIRED PATH="${fake_bin}:${PATH}" "$@" \
    "${sign}" "${app}" >"${work}/stdout" 2>"${work}/stderr" || status=$?
  got="$(sed -e "s#${work}#<dir>#g" -e "s#${entitlements}#<ent>#g" "${CALL_LOG}")"
  if [ "${status}" -ne "${want_status}" ]; then
    echo "FAIL ${name}: exit status = ${status}, want ${want_status}: $(cat "${work}/stderr")"
    failures=$((failures + 1))
    return
  fi
  if [ "${got}" != "${want_calls}" ]; then
    echo "FAIL ${name}: calls = $(printf '%q' "${got}"), want $(printf '%q' "${want_calls}")"
    failures=$((failures + 1))
    return
  fi
  echo "PASS ${name}"
}

verify="codesign --verify --deep --strict --verbose=2 <dir>/audio-router.app"

run_case "ad hoc without an identity" 0 \
  "codesign --force --options runtime --entitlements <ent> --sign - --timestamp=none <dir>/audio-router.app
${verify}"

run_case "ad hoc when not required" 0 \
  "codesign --force --options runtime --entitlements <ent> --sign - --timestamp=none <dir>/audio-router.app
${verify}" SIGNING_REQUIRED=false SIGNING_IDENTITY=

run_case "developer id with timestamp" 0 \
  "codesign --force --options runtime --entitlements <ent> --sign ${identity} --timestamp <dir>/audio-router.app
${verify}" SIGNING_IDENTITY="${identity}" SIGNING_REQUIRED=true

run_case "developer id from a keychain" 0 \
  "codesign --force --options runtime --entitlements <ent> --sign ${identity} --timestamp --keychain <dir>/k.keychain-db <dir>/audio-router.app
${verify}" SIGNING_IDENTITY="${identity}" SIGNING_KEYCHAIN="${work}/k.keychain-db"

# A release sets SIGNING_REQUIRED=true. A missing identity must fail before any signature.
run_case "required without an identity never signs ad hoc" 1 "" SIGNING_REQUIRED=true
run_case "required with an empty identity never signs ad hoc" 1 "" SIGNING_REQUIRED=true SIGNING_IDENTITY=
run_case "an identity that is not Developer ID" 1 "" SIGNING_IDENTITY="Apple Development: Test Person (ABC)"
run_case "an invalid SIGNING_REQUIRED" 1 "" SIGNING_REQUIRED=yes

# Nested code is signed before what contains it, without entitlements, and the app last.
mkdir -p "${app}/Contents/Frameworks/Outer.framework/Versions/A/Frameworks/Inner.framework" \
  "${app}/Contents/PlugIns/Ext.appex/Contents/MacOS"
touch "${app}/Contents/Frameworks/libextra.dylib"
nested_calls="$(cd "${work}" && find audio-router.app/Contents -depth \( -name '*.framework' -o -name '*.dylib' \
  -o -name '*.appex' \) -print)"
case "${nested_calls}" in
  *Inner.framework*Outer.framework*) ;;
  *)
    echo "FAIL fixture: find -depth did not list Inner.framework before Outer.framework"
    failures=$((failures + 1))
    ;;
esac
want_nested=""
while IFS= read -r path; do
  want_nested="${want_nested}codesign --force --options runtime --sign ${identity} --timestamp <dir>/${path}
"
done <<<"${nested_calls}"
run_case "nested code first, deepest first" 0 \
  "${want_nested}codesign --force --options runtime --entitlements <ent> --sign ${identity} --timestamp <dir>/audio-router.app
${verify}" SIGNING_IDENTITY="${identity}"
rm -rf "${app}/Contents/Frameworks" "${app}/Contents/PlugIns"

# Every signing call carries the hardened runtime.
: >"${CALL_LOG}"
mkdir -p "${app}/Contents/Frameworks/A.framework"
SIGNING_IDENTITY="${identity}" PATH="${fake_bin}:${PATH}" "${sign}" "${app}" >/dev/null
if grep -E '^codesign --force' "${CALL_LOG}" | grep -vq -- '--options runtime'; then
  echo "FAIL a signing call without --options runtime"
  failures=$((failures + 1))
else
  echo "PASS every signing call has --options runtime"
fi
rm -rf "${app}/Contents/Frameworks"

: >"${CALL_LOG}"
status=0
PATH="${fake_bin}:${PATH}" "${sign}" "${work}/missing.app" >/dev/null 2>&1 || status=$?
if [ "${status}" -eq 1 ] && [ ! -s "${CALL_LOG}" ]; then
  echo "PASS a missing app fails"
else
  echo "FAIL a missing app: exit ${status}, calls $(cat "${CALL_LOG}")"
  failures=$((failures + 1))
fi

finished=yes
if [ "${failures}" -ne 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all sign-app cases passed"
