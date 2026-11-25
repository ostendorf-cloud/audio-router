#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for notarize.sh with a fake xcrun first on the PATH that logs its calls. The API key values are
# fake sentinels. The tests check the notarytool and stapler calls, that a rejection prints the notary
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

# FAKE_SUBMIT_STATUS is the notarytool status in the JSON, FAKE_SUBMIT_EXIT its exit code.
# FAKE_SUBMIT_OUTPUT=none prints no JSON at all. submit checks the key file it gets.
cat <<'FAKE_XCRUN' >"${fake_bin}/xcrun"
#!/usr/bin/env bash
echo "xcrun $*" >>"${CALL_LOG}"
key=""
prev=""
for arg in "$@"; do
  [ "${prev}" = "--key" ] && key="${arg}"
  prev="${arg}"
done
case "$1 $2" in
  "notarytool submit")
    [ "$(cat "${key}")" = "${FAKE_KEY_CONTENT}" ] || { echo "submit: wrong key content" >&2; exit 3; }
    [ "$(ls -l "${key}" | cut -c1-10)" = "-rw-------" ] || { echo "submit: key is not 0600" >&2; exit 3; }
    [ "$(ls -ld "$(dirname "${key}")" | cut -c1-10)" = "drwx------" ] || { echo "submit: folder is not 0700" >&2; exit 3; }
    if [ "${FAKE_SUBMIT_OUTPUT:-}" != none ]; then
      printf '{"id":"11111111-2222-3333-4444-555555555555","message":"Processing complete","status":"%s"}\n' \
        "${FAKE_SUBMIT_STATUS:-Accepted}"
    fi
    exit "${FAKE_SUBMIT_EXIT:-0}"
    ;;
  "notarytool log") echo '{"issues":[{"message":"The binary is not signed with a valid Developer ID certificate."}]}' ;;
  "stapler staple" | "stapler validate") exit "${FAKE_STAPLER_EXIT:-0}" ;;
  *) exit 64 ;;
esac
FAKE_XCRUN
chmod +x "${fake_bin}/xcrun"

app="${work}/audio-router.app"
zip="${work}/audio-router-1.2.3-arm64.zip"
mkdir -p "${app}/Contents/MacOS"
touch "${zip}"

# run name want_status want_calls [env assignments...]
run_case() {
  local name="$1" want_status="$2" want_calls="$3" status=0 got secret
  shift 3
  : >"${CALL_LOG}"
  env -u NOTARY_TIMEOUT PATH="${fake_bin}:${PATH}" RUNNER_TEMP="${runner_temp}" \
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
submit="xcrun notarytool submit <dir>/audio-router-1.2.3-arm64.zip ${auth} --wait --timeout 30m --output-format json"
staple="xcrun stapler staple <dir>/audio-router.app
xcrun stapler validate <dir>/audio-router.app"
log="xcrun notarytool log 11111111-2222-3333-4444-555555555555 ${auth}"

run_case "accepted" 0 "${submit}
${staple}"
run_case "custom timeout" 0 "${submit/--timeout 30m/--timeout 1h}
${staple}" NOTARY_TIMEOUT=1h
run_case "invalid prints the log and staples nothing" 1 "${submit}
${log}" FAKE_SUBMIT_STATUS=Invalid FAKE_SUBMIT_EXIT=1
run_case "invalid with exit 0 still fails" 1 "${submit}
${log}" FAKE_SUBMIT_STATUS=Invalid
run_case "in progress after the timeout fails" 1 "${submit}
${log}" FAKE_SUBMIT_STATUS="In Progress"
run_case "no result fails without a log" 1 "${submit}" FAKE_SUBMIT_OUTPUT=none FAKE_SUBMIT_EXIT=1
run_case "accepted but exit 1 fails" 1 "${submit}
${log}" FAKE_SUBMIT_EXIT=1
run_case "staple fails with its exit code" 65 "${submit}
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
