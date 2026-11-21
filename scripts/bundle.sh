#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Builds dist/audio-router.app: arm64 release build, Info.plist, icon, ad hoc signature.
# Needs the Swift toolchain and the macOS tools codesign, iconutil and plutil. No Xcode.
#   scripts/bundle.sh             build and sign
#   scripts/bundle.sh --dry-run   print the rendered Info.plist and stop
# The version comes from $VERSION, else from `git describe --tags --always`, else 0.0.0-dev.
set -euo pipefail

dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *)
    echo "usage: $0 [--dry-run]" >&2
    exit 2
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

pattern='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'

version="${VERSION:-}"
if [ -z "${version}" ]; then
  version="$(git describe --tags --always 2>/dev/null || true)"
  version="${version#v}"
  if [ -z "${version}" ]; then
    version="0.0.0-dev"
  elif [[ ! "${version}" =~ ${pattern} ]]; then
    # No tag reachable: git describe printed only a commit hash.
    version="0.0.0-dev-${version}"
  fi
else
  version="${version#v}"
fi
if [[ ! "${version}" =~ ${pattern} ]]; then
  echo "invalid version '${version}', expected MAJOR.MINOR.PATCH[-suffix]" >&2
  exit 1
fi

template="${root}/Resources/Info.plist.template"
plist="$(<"${template}")"
plist="${plist//@VERSION@/${version}}"

if [ "${dry_run}" = true ]; then
  printf '%s\n' "${plist}"
  exit 0
fi

app="${root}/dist/audio-router.app"
rm -rf "${app}"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"

# Only the app product is built, so audio-router-proto never enters the bundle.
swift build -c release --arch arm64 --product AudioRouterApp
bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"
cp "${bin_dir}/AudioRouterApp" "${app}/Contents/MacOS/audio-router"

printf '%s\n' "${plist}" >"${app}/Contents/Info.plist"
plutil -lint "${app}/Contents/Info.plist"

iconutil -c icns "${root}/Resources/AppIcon.iconset" -o "${app}/Contents/Resources/AppIcon.icns"

# Ad hoc signature, hardened runtime, no entitlements file and so no sandbox entitlement.
codesign --force --sign - --options runtime "${app}"
codesign --verify --deep --strict "${app}"

echo "built ${app} (version ${version})"
