#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for audit-cask.sh with a fake brew first on the PATH that logs its
# calls: the order of the calls, a failing audit or style, and the cleanup on
# every exit path. Runs in an empty temporary directory. The real brew is never
# involved, so this proves the control flow only. That brew accepts the cask is
# what the cask-audit CI job proves.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
audit="${script_dir}/audit-cask.sh"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/audit-cask-test.XXXXXXXX")"
finished=no
trap 'rm -rf "${work}"; if [ "${finished}" != yes ]; then if [ "${failures:-0}" -eq 0 ]; then echo "test script stopped before its last line" >&2; fi; exit 1; fi' EXIT
cd "${work}"

failures=0
fake_bin="${work}/bin"
mkdir -p "${fake_bin}"
export CALL_LOG="${work}/calls"

# FAKE_FAIL names the subcommand that fails: audit, style, trust or tap.
# FAKE_TAPPED=yes makes "brew tap" list the scratch tap already.
# FAKE_TAP_LIST_FAILS=yes makes the "brew tap" listing fail.
cat <<'FAKE_BREW' >"${fake_bin}/brew"
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "tap" ]; then
  if [ "${FAKE_TAP_LIST_FAILS:-no}" = yes ]; then
    exit 1
  fi
  if [ "${FAKE_TAPPED:-no}" = yes ]; then
    # The scratch tap first, then enough lines to fill a pipe buffer: a
    # "brew tap | grep -q" would end by SIGPIPE here.
    echo "audio-router-ci/audit"
    seq 1 40000
  fi
  exit 0
fi
echo "brew $*" >>"${CALL_LOG}"
if [ "${FAKE_FAIL:-}" = "$1" ]; then
  exit 1
fi
if [ "$1" = "tap" ]; then
  # The tapped checkout must hold the cask, committed.
  test -f "$3/Casks/audio-router.rb" && git -C "$3" log --oneline >/dev/null
fi
exit 0
FAKE_BREW
chmod +x "${fake_bin}/brew"

cask="${work}/audio-router.rb"
printf 'cask "audio-router" do\nend\n' >"${cask}"

# run_case name want_status want_calls [cask]: want_calls is the call log with
# the scratch directory replaced by <dir>.
run_case() {
  local name="$1" want_status="$2" want_calls="$3" file="${4:-${cask}}" status=0 got
  : >"${CALL_LOG}"
  PATH="${fake_bin}:${PATH}" "${audit}" "${file}" >/dev/null 2>"${work}/stderr" || status=$?
  got="$(sed -E 's#tap audio-router-ci/audit [^ ]+#tap audio-router-ci/audit <dir>#' "${CALL_LOG}")"
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

ref="audio-router-ci/audit/audio-router"
full="brew tap audio-router-ci/audit <dir>
brew trust --cask ${ref}
brew audit --cask --strict ${ref}
brew style --cask ${ref}
brew untrust --cask ${ref}
brew untap --force audio-router-ci/audit"

run_case "audit and style run on the trusted scratch tap and everything is removed" 0 "${full}"

FAKE_FAIL=audit run_case "a failing audit still runs style and fails the run" 1 "${full}"
FAKE_FAIL=style run_case "a failing style fails the run" 1 "${full}"
FAKE_FAIL=trust run_case "a failing trust stops before audit and still untaps" 1 "brew tap audio-router-ci/audit <dir>
brew trust --cask ${ref}
brew untrust --cask ${ref}
brew untap --force audio-router-ci/audit"
FAKE_FAIL=tap run_case "a failing tap removes nothing it did not create" 1 "brew tap audio-router-ci/audit <dir>"
FAKE_TAPPED=yes run_case "an already tapped scratch name is refused and left alone" 2 ""
FAKE_TAP_LIST_FAILS=yes run_case "a failing tap listing stops the run instead of reading as not tapped" 1 ""
run_case "a missing cask is refused" 2 "" "${work}/missing.rb"

leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'audit-cask.*' 2>/dev/null | wc -l | tr -d ' ')"
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
