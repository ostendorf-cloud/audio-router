#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for verify-signature.sh with fake codesign, spctl and xcrun first on the PATH. They print canned
# outputs, shaped after `codesign -dvv` of an ad hoc build (measured) and of a Developer ID build (not
# measured here, taken from Apple's documented format). Runs in an empty temporary directory. That the
# real tools print what the fakes print is what the release run proves.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify="${script_dir}/verify-signature.sh"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/verify-signature-test.XXXXXXXX")"
finished=no
trap 'rm -rf "${work}"; if [ "${finished}" != yes ]; then if [ "${failures:-0}" -eq 0 ]; then echo "test script stopped before its last line" >&2; fi; exit 1; fi' EXIT
cd "${work}"

failures=0
fake_bin="${work}/bin"
mkdir -p "${fake_bin}"
export CALL_LOG="${work}/calls"
export FAKE_INFO="${work}/info" FAKE_ENTS="${work}/ents" FAKE_SPCTL="${work}/spctl"

cat <<'FAKE_CODESIGN' >"${fake_bin}/codesign"
#!/usr/bin/env bash
echo "codesign $*" >>"${CALL_LOG}"
case "$1" in
  --verify) exit "${FAKE_VERIFY_STATUS:-0}" ;;
  -dvv) cat "${FAKE_INFO}" >&2 ;;
  -d) cat "${FAKE_ENTS}" ;;
  *) exit 64 ;;
esac
FAKE_CODESIGN
cat <<'FAKE_SPCTL' >"${fake_bin}/spctl"
#!/usr/bin/env bash
echo "spctl $*" >>"${CALL_LOG}"
cat "${FAKE_SPCTL}" >&2
exit "${FAKE_SPCTL_STATUS:-0}"
FAKE_SPCTL
cat <<'FAKE_XCRUN' >"${fake_bin}/xcrun"
#!/usr/bin/env bash
echo "xcrun $*" >>"${CALL_LOG}"
[ "$1 $2" = "stapler validate" ] || exit 64
exit "${FAKE_STAPLER_STATUS:-0}"
FAKE_XCRUN
chmod +x "${fake_bin}/codesign" "${fake_bin}/spctl" "${fake_bin}/xcrun"

app="${work}/audio-router.app"
mkdir -p "${app}/Contents/MacOS"
identity="Developer ID Application: Test Person (TEAM123456)"

adhoc_info="Executable=${app}/Contents/MacOS/audio-router
Identifier=cloud.ostendorf.audio-router
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=1234 flags=0x10002(adhoc,runtime) hashes=30+7 location=embedded
Signature=adhoc
Info.plist entries=12
TeamIdentifier=not set
Runtime Version=27.0.0
Sealed Resources version=2 rules=13 files=10
Internal requirements count=0 size=12"

devid_info="Executable=${app}/Contents/MacOS/audio-router
Identifier=cloud.ostendorf.audio-router
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=30+7 location=embedded
Signature size=9000
Authority=${identity}
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=25 Nov 2026 at 12:00:00
Info.plist entries=12
TeamIdentifier=TEAM123456
Runtime Version=27.0.0
Sealed Resources version=2 rules=13 files=10
Internal requirements count=1 size=200"

empty_ents='<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict></dict></plist>'
sandbox_ents='<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>'
audio_ents='<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>'

notarized_spctl="${app}: accepted
source=Notarized Developer ID
origin=${identity}"

# run_case name want_status info ents spctl [env assignments...]
run_case() {
  local name="$1" want_status="$2" status=0
  printf '%s\n' "$3" >"${FAKE_INFO}"
  printf '%s' "$4" >"${FAKE_ENTS}"
  printf '%s\n' "$5" >"${FAKE_SPCTL}"
  shift 5
  : >"${CALL_LOG}"
  env -u VERIFY_SIGNATURE -u SIGNING_IDENTITY PATH="${fake_bin}:${PATH}" "$@" \
    "${verify}" "${app}" >"${work}/stdout" 2>"${work}/stderr" || status=$?
  if [ "${status}" -ne "${want_status}" ]; then
    echo "FAIL ${name}: exit status = ${status}, want ${want_status}: $(cat "${work}/stderr")"
    failures=$((failures + 1))
    return
  fi
  echo "PASS ${name}"
}

# expect_call name line: the last run called the tool with exactly this line.
expect_call() {
  if grep -qxF "$2" "${CALL_LOG}"; then
    echo "PASS $1"
  else
    echo "FAIL $1: no call '$2' in $(cat "${CALL_LOG}")"
    failures=$((failures + 1))
  fi
}

run_case "ad hoc passes the default level" 0 "${adhoc_info}" "${empty_ents}" ""
expect_call "strict deep verify" "codesign --verify --deep --strict --verbose=2 ${app}"
run_case "no entitlements at all pass" 0 "${adhoc_info}" "" ""
run_case "developer id passes the default level" 0 "${devid_info}" "${empty_ents}" ""
run_case "a failing codesign verify" 1 "${adhoc_info}" "${empty_ents}" "" FAKE_VERIFY_STATUS=1
run_case "no hardened runtime" 1 "${adhoc_info/(adhoc,runtime)/(adhoc)}" "${empty_ents}" ""
run_case "no hardened runtime on developer id" 1 "${devid_info/0x10000(runtime)/0x0(none)}" "${empty_ents}" "" \
  VERIFY_SIGNATURE=developer-id
run_case "sandbox entitlement" 1 "${adhoc_info}" "${sandbox_ents}" ""
run_case "entitlement not in the file" 1 "${adhoc_info}" "${audio_ents}" ""
run_case "unknown level" 2 "${adhoc_info}" "${empty_ents}" "" VERIFY_SIGNATURE=release

run_case "developer id level" 0 "${devid_info}" "${empty_ents}" "" VERIFY_SIGNATURE=developer-id
run_case "developer id level with the identity" 0 "${devid_info}" "${empty_ents}" "" \
  VERIFY_SIGNATURE=developer-id SIGNING_IDENTITY="${identity}"
run_case "developer id level, other identity" 1 "${devid_info}" "${empty_ents}" "" \
  VERIFY_SIGNATURE=developer-id SIGNING_IDENTITY="Developer ID Application: Someone Else (OTHER12345)"
run_case "developer id level rejects ad hoc" 1 "${adhoc_info}" "${empty_ents}" "" VERIFY_SIGNATURE=developer-id
run_case "developer id level, no timestamp" 1 "${devid_info/Timestamp=/Signed Time=}" "${empty_ents}" "" \
  VERIFY_SIGNATURE=developer-id
run_case "developer id level, apple development leaf" 1 \
  "${devid_info/Authority=Developer ID Application:/Authority=Apple Development:}" "${empty_ents}" "" \
  VERIFY_SIGNATURE=developer-id
run_case "developer id level, no intermediate" 1 \
  "${devid_info/Authority=Developer ID Certification Authority/Authority=Apple Worldwide Developer Relations}" \
  "${empty_ents}" "" VERIFY_SIGNATURE=developer-id
run_case "developer id level skips Gatekeeper" 0 "${devid_info}" "${empty_ents}" "" VERIFY_SIGNATURE=developer-id
if grep -qE '^(spctl|xcrun) ' "${CALL_LOG}"; then
  echo "FAIL developer id level called spctl or stapler: $(cat "${CALL_LOG}")"
  failures=$((failures + 1))
fi

run_case "notarized level" 0 "${devid_info}" "${empty_ents}" "${notarized_spctl}" VERIFY_SIGNATURE=notarized
expect_call "spctl assesses for execution" "spctl -a -vvv -t exec ${app}"
expect_call "stapler validates" "xcrun stapler validate ${app}"
run_case "notarized level, not notarized" 1 "${devid_info}" "${empty_ents}" \
  "${notarized_spctl/Notarized Developer ID/Developer ID}" VERIFY_SIGNATURE=notarized
run_case "notarized level, Gatekeeper rejects" 1 "${devid_info}" "${empty_ents}" \
  "${app}: rejected" VERIFY_SIGNATURE=notarized FAKE_SPCTL_STATUS=3
run_case "notarized level, Gatekeeper disabled" 1 "${devid_info}" "${empty_ents}" \
  "${app}: accepted
override=security disabled" VERIFY_SIGNATURE=notarized
run_case "notarized level, no stapled ticket" 1 "${devid_info}" "${empty_ents}" "${notarized_spctl}" \
  VERIFY_SIGNATURE=notarized FAKE_STAPLER_STATUS=65
run_case "notarized level rejects ad hoc" 1 "${adhoc_info}" "${empty_ents}" "${notarized_spctl}" \
  VERIFY_SIGNATURE=notarized

finished=yes
if [ "${failures}" -ne 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all verify-signature cases passed"
