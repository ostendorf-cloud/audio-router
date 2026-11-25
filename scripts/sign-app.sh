#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Signs an app bundle with the hardened runtime and Resources/AudioRouter.entitlements.
#   scripts/sign-app.sh <path to .app>
# Environment:
#   SIGNING_IDENTITY   a "Developer ID Application: <name> (<team id>)" identity. Signs with it and a
#                      secure timestamp. Empty or unset signs ad hoc, for local builds and pull requests.
#   SIGNING_KEYCHAIN   optional keychain file that holds the identity (codesign --keychain).
#   SIGNING_REQUIRED   true refuses the ad hoc fallback: an empty SIGNING_IDENTITY fails. The release
#                      workflow sets it. Default false.
# Nested code (frameworks, libraries, plug-ins, helper apps) is signed first, deepest first, then the
# app itself. Apple advises against `codesign --sign --deep`, so this script does not use it.
set -euo pipefail
set +x

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <path to .app>" >&2
  exit 2
fi
app="${1%/}"
if [ ! -d "${app}/Contents" ]; then
  echo "not an app bundle: ${app}" >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
entitlements="${root}/Resources/AudioRouter.entitlements"
if [ ! -f "${entitlements}" ]; then
  echo "missing ${entitlements}" >&2
  exit 1
fi

identity="${SIGNING_IDENTITY:-}"
required="${SIGNING_REQUIRED:-false}"
case "${required}" in
  true | false) ;;
  *)
    echo "SIGNING_REQUIRED must be true or false, got '${required}'" >&2
    exit 1
    ;;
esac

if [ -z "${identity}" ]; then
  if [ "${required}" = true ]; then
    echo "SIGNING_REQUIRED is true and SIGNING_IDENTITY is empty: refusing to sign ad hoc" >&2
    exit 1
  fi
  echo "signing ad hoc (SIGNING_IDENTITY is empty)"
  sign_args=(--sign - --timestamp=none)
else
  case "${identity}" in
    "Developer ID Application: "*) ;;
    *)
      echo "SIGNING_IDENTITY must name a Developer ID Application identity, got '${identity}'" >&2
      exit 1
      ;;
  esac
  echo "signing with ${identity}"
  sign_args=(--sign "${identity}" --timestamp)
  if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
    sign_args+=(--keychain "${SIGNING_KEYCHAIN}")
  fi
fi

# find -depth lists the contents of a directory before the directory, so nested code comes first.
# Entitlements belong to the main executable only. Nested code inherits nothing from this list.
while IFS= read -r nested; do
  codesign --force --options runtime "${sign_args[@]}" "${nested}"
done < <(find "${app}/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \
  -o -name '*.appex' -o -name '*.xpc' -o -name '*.app' -o -name '*.so' \) -print)

codesign --force --options runtime --entitlements "${entitlements}" "${sign_args[@]}" "${app}"
codesign --verify --deep --strict --verbose=2 "${app}"
