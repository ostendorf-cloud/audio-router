#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests scripts/lint-swiftui-macros.sh on temporary Sources trees. Needs bash, awk and find only.
#   scripts/lint-swiftui-macros_test.sh
set -euo pipefail

lint="$(cd "$(dirname "$0")" && pwd)/lint-swiftui-macros.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/lint-swiftui-macros.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
failures=0

header='// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0
'

# writes <tree> <file> <body>
write() {
  mkdir -p "$(dirname "${work}/$1/$2")"
  printf '%s\n%s\n' "${header}" "$3" >"${work}/$1/$2"
}

# expect <name> <tree> <wanted exit code> [text the output must contain]
expect() {
  local name="$1" tree="$2" want="$3" text="${4:-}" output code=0
  output="$("${lint}" "${work}/${tree}" 2>&1)" || code=$?
  if [ "${code}" -ne "${want}" ]; then
    echo "FAIL ${name}: exit ${code}, want ${want}: ${output}" >&2
    failures=$((failures + 1))
  elif [ -n "${text}" ] && [[ "${output}" != *"${text}"* ]]; then
    echo "FAIL ${name}: output lacks '${text}': ${output}" >&2
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

write clean View.swift 'import SwiftUI
import Observation

/// A comment may name @State, the check drops it.
struct Row: View {
    @Bindable var model: Model
    @Environment(\.dismiss) private var dismiss
    @StateObject var legacy = Legacy()
    var stateText = "State"
    var body: some View { Text("x") } // @State in a trailing comment
}'
expect "clean tree passes" clean 0

write state App/List.swift 'import SwiftUI

struct List: View {
    @State private var pending: Int?
    var body: some View { Text("x") }
}'
expect "@State fails with file, line and reason" state 1 \
  "App/List.swift:7: @State is a macro of the SwiftUIMacros plugin, which ships with Xcode only."

write qualified Q.swift 'struct Q { @SwiftUI.State var value = 0 }'
expect "@SwiftUI.State fails" qualified 1 "Q.swift:4: @State"

write entry E.swift 'extension EnvironmentValues { @Entry var level: Int = 0 }'
expect "@Entry fails" entry 1 "E.swift:4: @Entry"

write preview P.swift '#Preview { Text("x") }'
expect "#Preview fails" preview 1 "P.swift:4: #Preview is a macro of the PreviewsMacros plugin"

write mixed Clean.swift 'struct Clean {}'
write mixed Bad.swift 'struct Bad { @Previewable @State var on = false }'
expect "one bad file in a clean tree fails" mixed 1 "Bad.swift:4: @Previewable"

expect "missing directory is an error" does-not-exist 2 "is not a directory"
mkdir -p "${work}/empty"
expect "a tree without Swift files is an error" empty 2 "no Swift file"

if [ "${failures}" -ne 0 ]; then
  echo "${failures} lint-swiftui-macros test(s) failed" >&2
  exit 1
fi
echo "lint-swiftui-macros tests passed"
