#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Fails when a Swift file uses a SwiftUI macro whose compiler plugin ships with Xcode only.
# The Command Line Tools have no SwiftUIMacros and no PreviewsMacros plugin, so such a file does not
# build there (issue 58). The Observation macros (@Observable, @Bindable) come with the Command Line Tools.
#   scripts/lint-swiftui-macros.sh [dir]   check every *.swift below dir, default Sources
# A simple line check: it drops `//` comments. It does not know block comments or string literals, so a
# macro spelled inside them is reported too. That fails closed.
set -euo pipefail

# The macros of the macOS 27 SDK that need a plugin missing from the Command Line Tools, as name|plugin.
# Found with: grep -rn 'externalMacro' in the SwiftUI and SwiftUICore swiftinterface files of the SDK.
# Names starting with an underscore are internal helpers the public macros expand to, and are not listed.
macros=(
  "@State|SwiftUIMacros"
  "@Entry|SwiftUIMacros"
  "@Animatable|SwiftUIMacros"
  "@AnimatableIgnored|SwiftUIMacros"
  "@Previewable|PreviewsMacros"
  "#Preview|PreviewsMacros"
)

root="${1:-Sources}"
if [ ! -d "${root}" ]; then
  echo "lint-swiftui-macros: ${root} is not a directory" >&2
  exit 2
fi
if ! find "${root}" -name '*.swift' -print | grep -q .; then
  echo "lint-swiftui-macros: no Swift file in ${root}" >&2
  exit 2
fi

find "${root}" -name '*.swift' -exec awk -v list="${macros[*]}" '
  BEGIN {
    n = split(list, entries, " ")
    for (i = 1; i <= n; i++) {
      split(entries[i], part, "|")
      name[i] = part[1]
      plugin[i] = part[2]
      # The sigil, an optional module prefix, the macro name, then no further identifier character.
      # So @StateObject passes and @SwiftUI.State fails.
      pattern[i] = "(^|[^A-Za-z0-9_])" substr(part[1], 1, 1) "((SwiftUI|SwiftUICore)[.])?" \
        substr(part[1], 2) "([^A-Za-z0-9_]|$)"
    }
    bad = 0
  }
  {
    line = $0
    sub(/\/\/.*/, "", line)
    for (i = 1; i <= n; i++) {
      if (line ~ pattern[i]) {
        print FILENAME ":" FNR ": " name[i] " is a macro of the " plugin[i] \
          " plugin, which ships with Xcode only. The Command Line Tools cannot build it."
        bad = 1
      }
    }
  }
  END { exit bad }
' {} + || {
  echo "SwiftUI macros are not allowed in ${root}: the app must build with the Command Line Tools." \
    "See AGENTS.md." >&2
  exit 1
}
