#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Builds dist/audio-router.app: arm64 release build, Info.plist, icon, ad hoc signature.
# Needs the Swift toolchain and the macOS tools codesign, iconutil and plutil. No Xcode.
#   scripts/bundle.sh             build and sign
#   scripts/bundle.sh --dry-run   print the rendered Info.plist and stop
# The version comes from $VERSION, else from `git describe --tags --always`, else 0.0.0-dev.
# It must be MAJOR.MINOR.PATCH with an optional -suffix or +build, at most 64 characters.
set -euo pipefail

dry_run=false
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [--dry-run]" >&2
  exit 2
elif [ "$#" -eq 1 ]; then
  if [ "$1" = "--dry-run" ]; then
    dry_run=true
  else
    echo "usage: $0 [--dry-run]" >&2
    exit 2
  fi
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

num='(0|[1-9][0-9]*)'
pattern="^${num}\\.${num}\\.${num}([-+][0-9A-Za-z][0-9A-Za-z.-]*)?\$"

version="${VERSION:-}"
if [ -z "${version}" ]; then
  version="$(git describe --tags --always 2>/dev/null || true)"
  version="${version#v}"
  if [ -z "${version}" ]; then
    version="0.0.0-dev"
  elif [[ ! "${version}" =~ ${pattern} ]]; then
    # git describe printed a commit hash or a tag that is not MAJOR.MINOR.PATCH.
    version="0.0.0-dev-${version}"
  fi
else
  version="${version#v}"
fi
if [ "${#version}" -gt 64 ] || [[ "${version}" == *--* ]] || [[ ! "${version}" =~ ${pattern} ]]; then
  echo "invalid version '${version}', expected MAJOR.MINOR.PATCH[-suffix], no '--', at most 64 characters" >&2
  exit 1
fi
# CFBundleVersion is period separated integers, so it gets the numeric part only.
bundle_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"

plist="$(<"${root}/Resources/Info.plist.template")"
plist="${plist//@VERSION@/${version}}"
plist="${plist//@BUNDLE_VERSION@/${bundle_version}}"

if [ "${dry_run}" = true ]; then
  printf '%s\n' "${plist}"
  exit 0
fi

# Build first. A failed build leaves the previous bundle alone.
# Only the app product is built, so audio-router-proto never enters the bundle.
swift build -c release --arch arm64 --product AudioRouterApp
bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"

app="${root}/dist/audio-router.app"
ok=false
trap '[ "${ok}" = true ] || rm -rf "${app}"' EXIT
rm -rf "${app}"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
cp "${bin_dir}/AudioRouterApp" "${app}/Contents/MacOS/audio-router"

printf '%s\n' "${plist}" >"${app}/Contents/Info.plist"
plutil -lint "${app}/Contents/Info.plist"

iconutil -c icns "${root}/Resources/AppIcon.iconset" -o "${app}/Contents/Resources/AppIcon.icns"

# Ad hoc signature, hardened runtime, no entitlements file and so no sandbox entitlement.
codesign --force --sign - --options runtime "${app}"
codesign --verify --deep --strict "${app}"

ok=true
echo "built ${app} (version ${version})"
