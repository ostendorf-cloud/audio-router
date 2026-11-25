#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Renders the SVG sources in Resources/Branding to PNGs and writes them into the repository:
#   Resources/AppIcon.iconset/icon_*.png             app icon, 16 to 512 pt at 1x and 2x
#   Resources/Branding/menubar-<state>.png, @2x.png  menu bar template images, 16 pt at 1x and 2x
#   Resources/Branding/preview.png                   contact sheet of both for review
# Needs swiftc and AppKit from the macOS SDK, nothing else. NSImage reads SVG through CoreSVG.
#   scripts/render-branding.sh
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: $0" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
branding="${root}/Resources/Branding"
iconset="${root}/Resources/AppIcon.iconset"

work="$(mktemp -d "${TMPDIR:-/tmp}/render-branding.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
export CLANG_MODULE_CACHE_PATH="${work}/module-cache"
swiftc -O -module-cache-path "${work}/module-cache" "${root}/scripts/render-branding.swift" -o "${work}/render"

for state in off running warning error; do
  "${work}/render" render "${branding}/menubar-${state}.svg" 16 "${branding}/menubar-${state}.png"
  "${work}/render" render "${branding}/menubar-${state}.svg" 32 "${branding}/menubar-${state}@2x.png"
done

for size in 16 32 128 256 512; do
  "${work}/render" render "${branding}/app-icon.svg" "${size}" "${iconset}/icon_${size}x${size}.png"
  "${work}/render" render "${branding}/app-icon.svg" "$((size * 2))" "${iconset}/icon_${size}x${size}@2x.png"
done

"${work}/render" sheet "${branding}" "${iconset}" "${branding}/preview.png"
echo "rendered ${branding} and ${iconset}"
