#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for publish-homebrew-cask.sh. A fake gh first on the PATH stands in for
# the GitHub CLI and logs every call with the token it ran under, so these run
# offline in an empty temporary directory and never touch a real release or
# tap. The tokens are dummy strings, never real credentials.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${script_dir}/publish-homebrew-cask.sh"
render="${script_dir}/render-cask.sh"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/publish-homebrew-cask-test.XXXXXXXX")"
finished=no
trap 'rm -rf "${work}"; if [ "${finished}" != yes ]; then if [ "${failures:-0}" -eq 0 ]; then echo "test script stopped before its last line" >&2; fi; exit 1; fi' EXIT
cd "${work}"

fake_bin="${work}/fake-bin"
mkdir -p "${fake_bin}"

# The fake gh is steered by environment variables, one per behaviour:
#   FAKE_DRAFT          false (default) or true
#   FAKE_PRERELEASE     the isPrerelease answer (default false)
#   FAKE_VIEW_FAILS     set: "release view" fails
#   FAKE_DOWNLOAD_FAILS set: "release download" fails
#   FAKE_ZIP            the bytes of the release zip
#   FAKE_SUMS           the content of the release's .sha256 file
#   FAKE_TAP_STATE      missing (404), present, error (HTTP 502)
#   FAKE_TAP_FILE       the content the tap holds when present
#   FAKE_PUT_FAILS      set: the contents PUT fails
# Every call is logged as "<token> gh <args>", the content of a PUT is written
# to put-content instead of the log.
cat <<'FAKE_GH' >"${fake_bin}/gh"
#!/usr/bin/env bash
args=()
for a in "$@"; do
  case "${a}" in
  content=*)
    printf '%s' "${a#content=}" >"${CASE_DIR}/put-content"
    args+=("content=<base64>")
    ;;
  *) args+=("${a}") ;;
  esac
done
echo "${GH_TOKEN:-none} gh ${args[*]}" >>"${CALL_LOG}"

case "$1 $2" in
"release view")
  if [ -n "${FAKE_VIEW_FAILS:-}" ]; then
    echo "fake gh: release view failed" >&2
    exit 1
  fi
  echo "${FAKE_DRAFT:-false} ${FAKE_PRERELEASE:-false}"
  exit 0
  ;;
"release download")
  if [ -n "${FAKE_DOWNLOAD_FAILS:-}" ]; then
    echo "fake gh: download failed" >&2
    exit 1
  fi
  dir=""
  pattern=""
  for ((i = 1; i <= $#; i++)); do
    j=$((i + 1))
    case "${!i}" in
    --dir) dir="${!j}" ;;
    --pattern) pattern="${!j}" ;;
    esac
  done
  case "${pattern}" in
  *.zip) printf '%s' "${FAKE_ZIP}" >"${dir}/${pattern}" ;;
  *.zip.sha256) printf '%s\n' "${FAKE_SUMS}" >"${dir}/${pattern}" ;;
  *)
    echo "fake gh: unknown pattern ${pattern}" >&2
    exit 1
    ;;
  esac
  exit 0
  ;;
esac

if [ "$1" = "api" ]; then
  case " $* " in
  *" PUT "*)
    if [ -n "${FAKE_PUT_FAILS:-}" ]; then
      echo "fake gh: put failed (HTTP 403)" >&2
      exit 1
    fi
    exit 0
    ;;
  *"Accept: application/vnd.github.raw+json"*)
    printf '%s\n' "${FAKE_TAP_FILE}"
    exit 0
    ;;
  *)
    case "${FAKE_TAP_STATE}" in
    missing)
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
      ;;
    error)
      echo "gh: Bad Gateway (HTTP 502)" >&2
      exit 1
      ;;
    *)
      echo "abc123"
      exit 0
      ;;
    esac
    ;;
  esac
fi

echo "fake gh: unexpected call: $*" >&2
exit 1
FAKE_GH
chmod +x "${fake_bin}/gh"

export PATH="${fake_bin}:${PATH}"
export GH_TOKEN="release-token"
export TAP_TOKEN="tap-token"

failures=0

sha_of() {
  printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
}

# cask_for version hash prints the cask render-cask.sh writes for them.
cask_for() {
  "${render}" "$1" "$2" "${work}/cask-for.rb"
  cat "${work}/cask-for.rb"
}

reset_fakes() {
  export FAKE_DRAFT=false FAKE_PRERELEASE=false FAKE_TAP_STATE=missing
  export FAKE_ZIP="zip bytes of 1.0.0"
  ZIP_SHA256="$(sha_of "${FAKE_ZIP}")"
  FAKE_SUMS="${ZIP_SHA256}  audio-router-1.0.0-arm64.zip"
  FAKE_TAP_FILE="$(cask_for 0.1.0 "$(sha_of old)")"
  export ZIP_SHA256 FAKE_SUMS FAKE_TAP_FILE
  unset FAKE_VIEW_FAILS FAKE_DOWNLOAD_FAILS FAKE_PUT_FAILS ALLOW_DOWNGRADE VERIFY_MODE
}

# run_case name tag want_status want_stderr_substring want_calls
run_case() {
  local case_name="$1" tag="$2" want_status="$3" want_stderr="$4" want_calls="$5"

  CASE_DIR="${work}/case"
  CALL_LOG="${CASE_DIR}/calls.log"
  export CASE_DIR CALL_LOG
  rm -rf "${CASE_DIR}"
  mkdir -p "${CASE_DIR}"
  : >"${CALL_LOG}"

  local status=0
  TAG="${tag}" "${script}" >"${CASE_DIR}/stdout" 2>"${CASE_DIR}/stderr" || status=$?

  if [ "${want_status}" = "0" ] && [ "${status}" -ne 0 ]; then
    echo "FAIL ${case_name}: exit status = ${status}, want 0: $(cat "${CASE_DIR}/stderr")"
    failures=$((failures + 1))
    return
  fi
  if [ "${want_status}" != "0" ] && [ "${status}" -eq 0 ]; then
    echo "FAIL ${case_name}: exit status = 0, want non-zero"
    failures=$((failures + 1))
    return
  fi
  if [ -n "${want_stderr}" ] && ! grep -qF -- "${want_stderr}" "${CASE_DIR}/stderr"; then
    echo "FAIL ${case_name}: stderr = $(cat "${CASE_DIR}/stderr"), want it to contain: ${want_stderr}"
    failures=$((failures + 1))
    return
  fi
  local got_calls
  got_calls="$(sed -E 's#--dir [^ ]+#--dir <dir>#' "${CALL_LOG}")"
  if [ "${got_calls}" != "${want_calls}" ]; then
    echo "FAIL ${case_name}: calls:"
    echo "${got_calls}"
    echo "want:"
    echo "${want_calls}"
    failures=$((failures + 1))
    return
  fi
  if grep -qF "tap-token" "${CASE_DIR}/stdout" "${CASE_DIR}/stderr"; then
    echo "FAIL ${case_name}: the tap token reached the output"
    failures=$((failures + 1))
    return
  fi
  echo "PASS ${case_name}"
}

endpoint="repos/ostendorf-cloud/homebrew-tap/contents/Casks/audio-router.rb"
view_jq='"\(.isDraft) \(.isPrerelease)"'
view="release-token gh release view v1.0.0 --json isDraft,isPrerelease --jq ${view_jq}"
download="release-token gh release download v1.0.0 --pattern audio-router-1.0.0-arm64.zip --dir <dir> --clobber
release-token gh release download v1.0.0 --pattern audio-router-1.0.0-arm64.zip.sha256 --dir <dir> --clobber"
get_sha="tap-token gh api ${endpoint}?ref=main --jq .sha"
get_raw="tap-token gh api -H Accept: application/vnd.github.raw+json ${endpoint}?ref=main"
put="tap-token gh api -X PUT ${endpoint} -f message=audio-router 1.0.0 -f branch=main -f content=<base64>"

reset_fakes
run_case "a missing cask is created without a sha" v1.0.0 0 "" \
  "${view}
${download}
${get_sha}
${put} --silent"
want_content="$(cask_for 1.0.0 "${ZIP_SHA256}" | base64 | tr -d '\n')"
if [ "$(cat "${work}/case/put-content")" = "${want_content}" ]; then
  echo "PASS the pushed content is the cask rendered from the zip's hash"
else
  echo "FAIL the pushed content is not the cask rendered from the zip's hash"
  failures=$((failures + 1))
fi

reset_fakes
FAKE_TAP_STATE=present
run_case "an outdated cask is updated with the sha it replaces" v1.0.0 0 "" \
  "${view}
${download}
${get_sha}
${get_raw}
${put} -f sha=abc123 --silent"

reset_fakes
FAKE_TAP_STATE=present
FAKE_TAP_FILE="$(cask_for 1.0.0 "${ZIP_SHA256}")"
run_case "an identical cask is left alone, a rerun changes nothing" v1.0.0 0 "" \
  "${view}
${download}
${get_sha}
${get_raw}"

reset_fakes
FAKE_TAP_STATE=present
FAKE_TAP_FILE="$(cask_for 2.0.0 "$(sha_of newer)")"
run_case "a newer cask in the tap is not replaced" v1.0.0 1 "refusing to put an older cask back" \
  "${view}
${download}
${get_sha}
${get_raw}"

reset_fakes
FAKE_TAP_STATE=present
FAKE_TAP_FILE="$(cask_for 1.0.10 "$(sha_of newer)")"
run_case "versions compare by number, 1.0.10 is newer than 1.0.0" v1.0.0 1 "refusing to put an older cask back" \
  "${view}
${download}
${get_sha}
${get_raw}"

# Text order would rank 1.0.9 above 1.0.10 and refuse this push.
reset_fakes
FAKE_TAP_STATE=present
FAKE_TAP_FILE="$(cask_for 1.0.9 "$(sha_of older)")"
FAKE_ZIP="zip bytes of 1.0.10"
ZIP_SHA256="$(sha_of "${FAKE_ZIP}")"
FAKE_SUMS="${ZIP_SHA256}  audio-router-1.0.10-arm64.zip"
run_case "versions compare by number, 1.0.10 replaces 1.0.9" v1.0.10 0 "" \
  "release-token gh release view v1.0.10 --json isDraft,isPrerelease --jq ${view_jq}
release-token gh release download v1.0.10 --pattern audio-router-1.0.10-arm64.zip --dir <dir> --clobber
release-token gh release download v1.0.10 --pattern audio-router-1.0.10-arm64.zip.sha256 --dir <dir> --clobber
${get_sha}
${get_raw}
tap-token gh api -X PUT ${endpoint} -f message=audio-router 1.0.10 -f branch=main -f content=<base64> -f sha=abc123 --silent"

reset_fakes
FAKE_TAP_STATE=present
FAKE_TAP_FILE="$(cask_for 2.0.0 "$(sha_of newer)")"
export ALLOW_DOWNGRADE=true
run_case "the manual downgrade input replaces a newer cask" v1.0.0 0 "" \
  "${view}
${download}
${get_sha}
${get_raw}
${put} -f sha=abc123 --silent"

reset_fakes
FAKE_TAP_STATE=present
FAKE_TAP_FILE="cask without a version line"
run_case "a tap cask without a version stops the push" v1.0.0 1 "cannot read the version" \
  "${view}
${download}
${get_sha}
${get_raw}"

reset_fakes
FAKE_TAP_STATE=error
run_case "a failing tap read is not taken for a missing cask" v1.0.0 1 "cannot read Casks/audio-router.rb" \
  "${view}
${download}
${get_sha}"

reset_fakes
ZIP_SHA256="$(sha_of "another build")"
run_case "a zip that differs from the bundle job's hash is not pushed" v1.0.0 1 "differs from the zip the bundle job built" \
  "${view}
${download}"

reset_fakes
FAKE_SUMS="$(sha_of "another build")  audio-router-1.0.0-arm64.zip"
run_case "a zip that differs from the release's .sha256 is not pushed" v1.0.0 1 "does not match the release's" \
  "${view}
${download}"

reset_fakes
FAKE_SUMS="${ZIP_SHA256}  audio-router-9.9.9-arm64.zip"
run_case "a .sha256 file for another zip is not accepted" v1.0.0 1 "does not match the release's" \
  "${view}
${download}"

reset_fakes
unset ZIP_SHA256
run_case "the hash mode without a recorded hash stops" v1.0.0 1 "no zip hash recorded" \
  "${view}
${download}"

reset_fakes
unset ZIP_SHA256
export VERIFY_MODE=checksums
run_case "the checksums mode verifies against the release's .sha256 alone" v1.0.0 0 "" \
  "${view}
${download}
${get_sha}
${put} --silent"

reset_fakes
export VERIFY_MODE=checksums
FAKE_SUMS="$(sha_of "another build")  audio-router-1.0.0-arm64.zip"
run_case "the checksums mode refuses a wrong .sha256" v1.0.0 1 "does not match the release's" \
  "${view}
${download}"

reset_fakes
export VERIFY_MODE=other
run_case "an unknown verify mode stops before any call" v1.0.0 1 "unknown VERIFY_MODE" ""

reset_fakes
FAKE_PRERELEASE=true
run_case "a pre-release is skipped by the release's own flag" v1.0.0 0 "" "${view}"

reset_fakes
FAKE_DRAFT=true
run_case "a draft is refused" v1.0.0 1 "is a draft" "${view}"

reset_fakes
export FAKE_VIEW_FAILS=1
run_case "a release that cannot be read is refused" v1.0.0 1 "cannot read the release" "${view}"

reset_fakes
run_case "a tag that is not a release tag stops before any call" main 1 "is not a release tag" ""

reset_fakes
run_case "a build tag the release does not flag as pre-release is refused" v1.0.0+build 1 "not a plain" \
  "release-token gh release view v1.0.0+build --json isDraft,isPrerelease --jq ${view_jq}"

reset_fakes
export FAKE_DOWNLOAD_FAILS=1
run_case "a failing download stops the push" v1.0.0 1 "cannot download" \
  "${view}
release-token gh release download v1.0.0 --pattern audio-router-1.0.0-arm64.zip --dir <dir> --clobber"

reset_fakes
export FAKE_PUT_FAILS=1
run_case "a failing push fails the run" v1.0.0 1 "cannot push" \
  "${view}
${download}
${get_sha}
${put} --silent"

leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'publish-homebrew-cask.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${leftover}" -ne 0 ]; then
  echo "FAIL ${leftover} scratch directories are left in ${TMPDIR:-/tmp}"
  failures=$((failures + 1))
else
  echo "PASS no scratch directory is left behind"
fi

if [ "${failures}" -ne 0 ]; then
  finished=yes
  echo "${failures} test(s) failed"
  exit 1
fi

finished=yes
echo "all tests passed"
