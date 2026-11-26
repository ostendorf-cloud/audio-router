#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for notarize.sh with a fake xcrun and a fake sleep first on the PATH that log their calls. The API
# key values are fake sentinels. The tests check the notarytool and stapler calls, polling until Accepted,
# the timeout that prints the id, resuming an id without an upload, that a rejection prints the notary
# log and staples nothing, that a missing secret fails before any call, that no secret value reaches
# stdout or stderr, and that the decoded key is 0600 while in use and gone after every run. Runs in an
# empty temporary directory. That Apple accepts the zip is what the release run proves.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
notarize="${script_dir}/notarize.sh"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/notarize-test.XXXXXXXX")"
finished=no
trap 'rm -rf "${work}"; if [ "${finished}" != yes ]; then if [ "${failures:-0}" -eq 0 ]; then echo "test script stopped before its last line" >&2; fi; exit 1; fi' EXIT
cd "${work}"

failures=0
fake_bin="${work}/bin"
runner_temp="${work}/runner-temp"
mkdir -p "${fake_bin}" "${runner_temp}"
export CALL_LOG="${work}/calls"

key_content="-----BEGIN PRIVATE KEY-----
FAKE-P8-SENTINEL-5ca1ab1e
-----END PRIVATE KEY-----"
key_base64="$(printf '%s' "${key_content}" | base64)"
key_id="FAKEKEYID-SENTINEL-77"
issuer_id="FAKE-ISSUER-SENTINEL-0000-1111"
export FAKE_KEY_CONTENT="${key_content}"

# submit prints the id and exits with FAKE_SUBMIT_EXIT. FAKE_SUBMIT_OUTPUT=none prints no JSON at all.
# info prints the next status of FAKE_INFO_SEQ (words, "_" stands for a space, the last one repeats)
# and exits with FAKE_INFO_EXIT. submit and info check the key file they get.
cat <<'FAKE_XCRUN' >"${fake_bin}/xcrun"
#!/usr/bin/env bash
echo "xcrun $*" >>"${CALL_LOG}"
key=""
prev=""
for arg in "$@"; do
  [ "${prev}" = "--key" ] && key="${arg}"
  prev="${arg}"
done
check_key() {
  [ "$(cat "${key}")" = "${FAKE_KEY_CONTENT}" ] || { echo "$1: wrong key content" >&2; exit 3; }
  [ "$(ls -l "${key}" | cut -c1-10)" = "-rw-------" ] || { echo "$1: key is not 0600" >&2; exit 3; }
  [ "$(ls -ld "$(dirname "${key}")" | cut -c1-10)" = "drwx------" ] || { echo "$1: folder is not 0700" >&2; exit 3; }
}
case "$1 $2" in
  "notarytool submit")
    check_key submit
    if [ "${FAKE_SUBMIT_OUTPUT:-}" != none ]; then
      printf '{"id":"11111111-2222-3333-4444-555555555555","message":"Upload successful","path":"x.zip"}\n'
    fi
    exit "${FAKE_SUBMIT_EXIT:-0}"
    ;;
  "notarytool info")
    check_key info
    [ "${FAKE_INFO_EXIT:-0}" -eq 0 ] || exit "${FAKE_INFO_EXIT}"
    n=$(($(cat "${FAKE_COUNT}" 2>/dev/null || echo 0) + 1))
    echo "${n}" >"${FAKE_COUNT}"
    read -r -a seq <<<"${FAKE_INFO_SEQ:-Accepted}"
    [ "${n}" -le "${#seq[@]}" ] || n="${#seq[@]}"
    printf '{"createdDate":"2026-01-01T00:00:00Z","id":"%s","name":"x.zip","status":"%s"}\n' "$3" "${seq[$((n - 1))]//_/ }"
    ;;
  "notarytool log") echo '{"issues":[{"message":"The binary is not signed with a valid Developer ID certificate."}]}' ;;
  "stapler staple" | "stapler validate") exit "${FAKE_STAPLER_EXIT:-0}" ;;
  *) exit 64 ;;
esac
FAKE_XCRUN
chmod +x "${fake_bin}/xcrun"
# A fake sleep logs the wait and returns at once.
cat <<'FAKE_SLEEP' >"${fake_bin}/sleep"
#!/usr/bin/env bash
echo "sleep $*" >>"${CALL_LOG}"
FAKE_SLEEP
chmod +x "${fake_bin}/sleep"
export FAKE_COUNT="${work}/info-count"

app="${work}/audio-router.app"
zip="${work}/audio-router-1.2.3-arm64.zip"
mkdir -p "${app}/Contents/MacOS"
touch "${zip}"

# run name want_status want_calls [env assignments...]
run_case() {
  local name="$1" want_status="$2" want_calls="$3" status=0 got secret
  shift 3
  : >"${CALL_LOG}"
  rm -f "${FAKE_COUNT}"
  env -u NOTARY_TIMEOUT -u NOTARY_POLL_INTERVAL -u NOTARY_SUBMISSION_ID PATH="${fake_bin}:${PATH}" RUNNER_TEMP="${runner_temp}" \
    APPLE_NOTARY_KEY_ID="${key_id}" APPLE_NOTARY_ISSUER_ID="${issuer_id}" \
    APPLE_NOTARY_KEY_P8_BASE64="${key_base64}" "$@" \
    "${notarize}" "${zip}" "${app}" >"${work}/out" 2>&1 || status=$?
  got="$(sed -E -e "s#${work}#<dir>#g" -e 's#<dir>/runner-temp/audio-router-signing\.[A-Za-z0-9]+/#<tmp>/#' "${CALL_LOG}")"
  if [ "${status}" -ne "${want_status}" ]; then
    echo "FAIL ${name}: exit status = ${status}, want ${want_status}: $(cat "${work}/out")"
    failures=$((failures + 1))
    return
  fi
  if [ "${got}" != "${want_calls}" ]; then
    echo "FAIL ${name}: calls = $(printf '%q' "${got}"), want $(printf '%q' "${want_calls}")"
    failures=$((failures + 1))
    return
  fi
  for secret in "FAKE-P8-SENTINEL-5ca1ab1e" "${key_base64}" "${key_id}" "${issuer_id}"; do
    if grep -qF -- "${secret}" "${work}/out"; then
      echo "FAIL ${name}: a secret value is in the output"
      failures=$((failures + 1))
      return
    fi
  done
  if [ -n "$(ls -A "${runner_temp}")" ]; then
    echo "FAIL ${name}: files left in RUNNER_TEMP: $(ls -A "${runner_temp}")"
    failures=$((failures + 1))
    return
  fi
  echo "PASS ${name}"
}

auth="--key <tmp>/AuthKey.p8 --key-id ${key_id} --issuer ${issuer_id}"
id="11111111-2222-3333-4444-555555555555"
submit="xcrun notarytool submit <dir>/audio-router-1.2.3-arm64.zip ${auth} --output-format json"
info="xcrun notarytool info ${id} ${auth} --output-format json"
nap="sleep 30"
staple="xcrun stapler staple <dir>/audio-router.app
xcrun stapler validate <dir>/audio-router.app"
log="xcrun notarytool log ${id} ${auth}"

# expect_out name text: the output of the last run_case holds the text.
expect_out() {
  if ! grep -qF -- "$2" "${work}/out"; then
    echo "FAIL $1: output lacks '$2'"
    failures=$((failures + 1))
  fi
}

run_case "accepted at the first poll" 0 "${submit}
${info}
${staple}"
run_case "accepted after two polls" 0 "${submit}
${info}
${nap}
${info}
${nap}
${info}
${staple}" FAKE_INFO_SEQ="In_Progress In_Progress Accepted"
run_case "invalid prints the log and staples nothing" 1 "${submit}
${info}
${log}" FAKE_INFO_SEQ=Invalid
expect_out "invalid prints the log and staples nothing" "The binary is not signed"
run_case "rejected after a wait prints the log" 1 "${submit}
${info}
${nap}
${info}
${log}" FAKE_INFO_SEQ="In_Progress Rejected"
run_case "timeout prints the id and keeps the submission" 1 "${submit}
${info}
${nap}
${info}
${nap}
${info}" FAKE_INFO_SEQ="In_Progress" NOTARY_TIMEOUT=60s
expect_out "timeout prints the id and keeps the submission" "submission ${id} may still be processing"
expect_out "timeout prints the id and keeps the submission" "NOTARY_SUBMISSION_ID=${id}"
run_case "timeout with a minute suffix and a custom interval" 1 "${submit}
${info}
sleep 600
${info}" FAKE_INFO_SEQ="In_Progress" NOTARY_TIMEOUT=10m NOTARY_POLL_INTERVAL=600
run_case "resume skips the upload and accepts by id" 0 "${info}
${nap}
${info}
${staple}" NOTARY_SUBMISSION_ID="${id}" FAKE_INFO_SEQ="In_Progress Accepted"
run_case "resume of a rejected id prints the log" 1 "${info}
${log}" NOTARY_SUBMISSION_ID="${id}" FAKE_INFO_SEQ=Invalid
run_case "resume needs no zip" 0 "${info}
${staple}" NOTARY_SUBMISSION_ID="${id}"
run_case "a submission id that is no UUID fails before any call" 1 "" NOTARY_SUBMISSION_ID="not-an-id"
run_case "five failed polls in a row give up" 1 "${submit}
${info}
${nap}
${info}
${nap}
${info}
${nap}
${info}
${nap}
${info}" FAKE_INFO_EXIT=1
expect_out "five failed polls in a row give up" "NOTARY_SUBMISSION_ID=${id}"
run_case "upload failure stops before polling" 1 "${submit}" FAKE_SUBMIT_OUTPUT=none FAKE_SUBMIT_EXIT=1
run_case "upload without an id stops before polling" 1 "${submit}" FAKE_SUBMIT_OUTPUT=none
run_case "invalid timeout fails before any call" 1 "" NOTARY_TIMEOUT=soon
run_case "zero poll interval fails before any call" 1 "" NOTARY_POLL_INTERVAL=0
run_case "staple fails with its exit code" 65 "${submit}
${info}
xcrun stapler staple <dir>/audio-router.app" FAKE_STAPLER_EXIT=65

for name in APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID APPLE_NOTARY_KEY_P8_BASE64; do
  run_case "missing ${name}" 1 "" "${name}="
done
run_case "not a p8 key" 1 "" APPLE_NOTARY_KEY_P8_BASE64="$(printf 'not a key' | base64)"

if grep -q 'notarization failed' "${work}/out"; then
  echo "FAIL not a p8 key: reached the submission"
  failures=$((failures + 1))
fi

finished=yes
if [ "${failures}" -ne 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all notarize cases passed"
