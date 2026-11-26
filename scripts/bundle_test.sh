#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the version mapping of bundle.sh, through --dry-run: both Apple keys get the numeric core,
# ARFullVersion gets the full version, a leading v is dropped and a bad version is refused. Builds nothing and calls no macOS tool.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle="${script_dir}/bundle.sh"

failures=0
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# The string value that follows a key in the rendered plist.
value_of() {
  grep -A1 "<key>$2</key>" <<<"$1" | sed -n 's|.*<string>\(.*\)</string>.*|\1|p'
}

check() {
  local name="$1" given="$2" want_core="$3" want_full="$4" plist short build full
  plist="$(VERSION="${given}" "${bundle}" --dry-run)"
  short="$(value_of "${plist}" CFBundleShortVersionString)"
  build="$(value_of "${plist}" CFBundleVersion)"
  full="$(value_of "${plist}" ARFullVersion)"
  if [ "${short}" = "${want_core}" ] && [ "${build}" = "${want_core}" ] && [ "${full}" = "${want_full}" ] &&
    [[ "${short}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "PASS ${name}"
  else
    fail "${name}: short '${short}', build '${build}', full '${full}', want '${want_core}' and '${want_full}'"
  fi
}

refuse() {
  local name="$1" given="$2"
  if VERSION="${given}" "${bundle}" --dry-run >/dev/null 2>&1; then
    fail "${name}: accepted '${given}'"
  else
    echo "PASS ${name}"
  fi
}

check "a stable version stays as it is" 1.2.3 1.2.3 1.2.3
check "a release candidate keeps its suffix only in the full version" 0.1.0-rc.2 0.1.0 0.1.0-rc.2
check "a leading v is dropped" v0.1.0-rc.2 0.1.0 0.1.0-rc.2
check "build metadata stays out of the Apple keys" 1.2.3+build.5 1.2.3 1.2.3+build.5
refuse "a version without a patch part is refused" 1.2
refuse "a version with a leading zero is refused" 01.2.3

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "all tests passed"
