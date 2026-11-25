#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for signing-keychain.sh with a fake security first on the PATH that logs its calls. The secrets
# are fake sentinel values. The tests check the order of the calls, that a missing secret fails before
# any keychain exists, that no secret value reaches stdout or stderr, that the decoded .p12 is gone
# after every run, and the cleanup. Runs in an empty temporary directory. The real security tool and a
# real certificate are never involved: that the import works is what the release run proves.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
keychain_script="${script_dir}/signing-keychain.sh"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/signing-keychain-test.XXXXXXXX")"
finished=no
trap 'rm -rf "${work}"; if [ "${finished}" != yes ]; then if [ "${failures:-0}" -eq 0 ]; then echo "test script stopped before its last line" >&2; fi; exit 1; fi' EXIT
cd "${work}"

failures=0
fake_bin="${work}/bin"
runner_temp="${work}/runner-temp"
mkdir -p "${fake_bin}" "${runner_temp}"
export CALL_LOG="${work}/calls"

p12_content="FAKE-P12-SENTINEL-c0ffee"
p12_base64="$(printf '%s' "${p12_content}" | base64)"
cert_password="FAKE-PASSWORD-SENTINEL-beef"
identity="Developer ID Application: Test Person (TEAM123456)"
export FAKE_P12_CONTENT="${p12_content}"

# FAKE_FAIL names the subcommand that fails. FAKE_IDENTITY is what find-identity lists.
# import checks that it got the decoded .p12, readable by this user only.
cat <<'FAKE_SECURITY' >"${fake_bin}/security"
#!/usr/bin/env bash
echo "security $*" >>"${CALL_LOG}"
if [ "${FAKE_FAIL:-}" = "$1" ]; then
  echo "security: $1 failed" >&2
  exit 1
fi
case "$1" in
  create-keychain) touch "${!#}" ;;
  delete-keychain) rm -f "$2" ;;
  import)
    [ "$(cat "$2")" = "${FAKE_P12_CONTENT}" ] || { echo "import: wrong .p12 content" >&2; exit 3; }
    [ "$(ls -l "$2" | cut -c1-10)" = "-rw-------" ] || { echo "import: .p12 is not 0600" >&2; exit 3; }
    [ "$(ls -ld "$(dirname "$2")" | cut -c1-10)" = "drwx------" ] || { echo "import: folder is not 0700" >&2; exit 3; }
    ;;
  list-keychains)
    if [ "$#" -eq 3 ]; then
      echo '    "/Users/runner/Library/Keychains/login.keychain-db"'
      echo '    "/Library/Keychains/System.keychain"'
    fi
    ;;
  find-identity)
    if [ -n "${FAKE_IDENTITY:-}" ]; then
      echo "  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"${FAKE_IDENTITY}\""
      echo "     1 valid identities found"
    else
      echo "     0 valid identities found"
    fi
    ;;
esac
exit 0
FAKE_SECURITY
chmod +x "${fake_bin}/security"

kc="${work}/signing.keychain-db"

# run name want_status command [env assignments...]: runs the script with the secrets set, then the
# assignments, with stdout and stderr in ${work}/out.
run() {
  local name="$1" want_status="$2" cmd="$3" status=0
  shift 3
  : >"${CALL_LOG}"
  env -u GITHUB_ACTIONS PATH="${fake_bin}:${PATH}" RUNNER_TEMP="${runner_temp}" SIGNING_KEYCHAIN="${kc}" \
    APPLE_CERT_P12_BASE64="${p12_base64}" APPLE_CERT_PASSWORD="${cert_password}" \
    SIGNING_IDENTITY="${identity}" FAKE_IDENTITY="${identity}" "$@" \
    "${keychain_script}" "${cmd}" >"${work}/out" 2>&1 || status=$?
  if [ "${status}" -ne "${want_status}" ]; then
    echo "FAIL ${name}: exit status = ${status}, want ${want_status}: $(cat "${work}/out")"
    failures=$((failures + 1))
    return 1
  fi
  return 0
}

# no_secret_in_output name: no secret value, encoded or decoded, in what the script printed.
no_secret_in_output() {
  local secret
  for secret in "${p12_content}" "${p12_base64}" "${cert_password}"; do
    if grep -qF -- "${secret}" "${work}/out"; then
      echo "FAIL $1: a secret value is in the output"
      failures=$((failures + 1))
      return
    fi
  done
  echo "PASS $1: no secret in the output"
}

no_leftovers() {
  if [ -n "$(ls -A "${runner_temp}")" ]; then
    echo "FAIL $1: files left in RUNNER_TEMP: $(ls -A "${runner_temp}")"
    failures=$((failures + 1))
  else
    echo "PASS $1: nothing left in RUNNER_TEMP"
  fi
}

expect_no_calls() {
  if [ -s "${CALL_LOG}" ]; then
    echo "FAIL $1: security ran: $(cat "${CALL_LOG}")"
    failures=$((failures + 1))
  else
    echo "PASS $1"
  fi
}

calls_without_password() {
  sed -E -e 's/-p [0-9a-f]{64} /-p <pw> /' -e 's/-k [0-9a-f]{64} /-k <pw> /' -e "s#${work}#<dir>#g" \
    -e 's#<dir>/runner-temp/audio-router-signing\.[A-Za-z0-9]+/#<tmp>/#' "${CALL_LOG}"
}

want_create="security create-keychain -p <pw> <dir>/signing.keychain-db
security set-keychain-settings -lut 21600 <dir>/signing.keychain-db
security unlock-keychain -p <pw> <dir>/signing.keychain-db
security import <tmp>/certificate.p12 -k <dir>/signing.keychain-db -f pkcs12 -P ${cert_password} -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k <pw> <dir>/signing.keychain-db
security list-keychains -d user
security list-keychains -d user -s <dir>/signing.keychain-db /Users/runner/Library/Keychains/login.keychain-db /Library/Keychains/System.keychain
security find-identity -v -p codesigning <dir>/signing.keychain-db"

if run "create" 0 create; then
  got="$(calls_without_password)"
  if [ "${got}" = "${want_create}" ]; then
    echo "PASS create: calls"
  else
    echo "FAIL create: calls = $(printf '%q' "${got}"), want $(printf '%q' "${want_create}")"
    failures=$((failures + 1))
  fi
  no_secret_in_output "create"
  no_leftovers "create"
  [ -f "${kc}" ] || { echo "FAIL create: no keychain"; failures=$((failures + 1)); }
  # One random password, used for create, unlock and the partition list.
  passwords="$(grep -oE '(-p|-k) [0-9a-f]{64} ' "${CALL_LOG}" | cut -d' ' -f2 | sort -u | wc -l | tr -d ' ')"
  if [ "${passwords}" = 1 ]; then
    echo "PASS create: one keychain password"
  else
    echo "FAIL create: ${passwords} keychain passwords"
    failures=$((failures + 1))
  fi
fi
rm -f "${kc}"

# On GitHub Actions the keychain password is masked, and appears in no other line.
if run "create on actions" 0 create GITHUB_ACTIONS=true; then
  pw="$(grep -oE 'create-keychain -p [0-9a-f]{64} ' "${CALL_LOG}" | cut -d' ' -f3)"
  if [ -n "${pw}" ] && grep -qxF "::add-mask::${pw}" "${work}/out" &&
    [ "$(grep -cF "${pw}" "${work}/out")" = 1 ]; then
    echo "PASS create on actions: the keychain password is masked"
  else
    echo "FAIL create on actions: the keychain password is not masked once: $(cat "${work}/out")"
    failures=$((failures + 1))
  fi
  no_secret_in_output "create on actions"
fi
rm -f "${kc}"

# A missing secret or identity fails before any keychain exists: a release never signs ad hoc.
for name in SIGNING_KEYCHAIN APPLE_CERT_P12_BASE64 APPLE_CERT_PASSWORD SIGNING_IDENTITY; do
  if run "missing ${name}" 1 create "${name}="; then
    if [ -s "${CALL_LOG}" ] || [ -e "${kc}" ]; then
      echo "FAIL missing ${name}: security ran: $(cat "${CALL_LOG}")"
      failures=$((failures + 1))
    elif ! grep -qF "${name} is empty" "${work}/out"; then
      echo "FAIL missing ${name}: the error does not name it: $(cat "${work}/out")"
      failures=$((failures + 1))
    else
      echo "PASS missing ${name}"
    fi
    no_secret_in_output "missing ${name}"
    no_leftovers "missing ${name}"
  fi
done

if run "not a developer id identity" 1 create SIGNING_IDENTITY="Apple Development: Test Person (ABC)"; then
  expect_no_calls "not a developer id identity"
fi

if run "identity not in the p12" 1 create FAKE_IDENTITY="Developer ID Application: Someone Else (OTHER12345)"; then
  echo "PASS identity not in the p12"
  no_secret_in_output "identity not in the p12"
  no_leftovers "identity not in the p12"
fi
rm -f "${kc}"

if run "import fails" 1 create FAKE_FAIL=import; then
  echo "PASS import fails"
  no_secret_in_output "import fails"
  no_leftovers "import fails"
  if grep -q '^security set-key-partition-list' "${CALL_LOG}"; then
    echo "FAIL import fails: went on after the import"
    failures=$((failures + 1))
  fi
fi
rm -f "${kc}"

touch "${kc}"
if run "keychain exists already" 1 create; then
  expect_no_calls "keychain exists already"
fi

# delete removes the keychain and folders a killed run left behind, and nothing else.
mkdir -p "${runner_temp}/audio-router-signing.AAAA1111" "${runner_temp}/other"
touch "${runner_temp}/audio-router-signing.AAAA1111/AuthKey.p8"
if run "delete" 0 delete; then
  if [ -e "${kc}" ] || [ -e "${runner_temp}/audio-router-signing.AAAA1111" ] || [ ! -d "${runner_temp}/other" ]; then
    echo "FAIL delete: left $(ls -A "${runner_temp}"), keychain $([ -e "${kc}" ] && echo kept || echo gone)"
    failures=$((failures + 1))
  elif [ "$(calls_without_password)" != "security delete-keychain <dir>/signing.keychain-db" ]; then
    echo "FAIL delete: calls $(cat "${CALL_LOG}")"
    failures=$((failures + 1))
  else
    echo "PASS delete"
  fi
fi
rmdir "${runner_temp}/other"

if run "delete without a keychain" 0 delete SIGNING_KEYCHAIN=; then
  expect_no_calls "delete without a keychain"
fi

touch "${kc}"
if run "delete fails" 1 delete FAKE_FAIL=delete-keychain; then
  echo "PASS delete fails"
fi
rm -f "${kc}"

run "unknown command" 2 rotate && echo "PASS unknown command"

finished=yes
if [ "${failures}" -ne 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all signing-keychain cases passed"
