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

# The Foundation types share names with the macros. Only the # spelling is a macro.
write words Words.swift 'import Foundation

#if DEBUG
let predicate: Predicate<Int>? = nil
let expression: Expression<Int, Bool>? = nil
#endif
let bundle = Bundle.main
let state: SwiftUI.State<Int>? = nil
func entry(_ animatable: Bool, previewable: Bool) {}
let mail = "user@Statehouse.example"'
expect "types and words named like the macros pass" words 0

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

write animatable A.swift '@Animatable struct Shape {}'
expect "@Animatable fails" animatable 1 "A.swift:4: @Animatable is a macro of the SwiftUIMacros plugin"

write ignored I.swift 'struct Shape { @AnimatableIgnored var id = 0 }'
expect "@AnimatableIgnored fails" ignored 1 "I.swift:4: @AnimatableIgnored is a macro"

write previewable V.swift '    @Previewable var on = false'
expect "@Previewable fails" previewable 1 "V.swift:4: @Previewable is a macro of the PreviewsMacros plugin"

write predicate R.swift 'let adults = #Predicate<Int> { age in age >= 18 }'
expect "#Predicate fails" predicate 1 "R.swift:4: #Predicate is a macro of the FoundationMacros plugin"

write expression X.swift 'let double = #Expression<Int, Int> { value in value * 2 }'
expect "#Expression fails" expression 1 "X.swift:4: #Expression is a macro of the FoundationMacros plugin"

write bundlemacro B.swift 'let resources = #bundle'
expect "#bundle fails" bundlemacro 1 "B.swift:4: #bundle is a macro of the FoundationMacros plugin"

write qualifiedfoundation F.swift 'let any = #Foundation.Predicate<Int> { _ in true }'
expect "#Foundation.Predicate fails" qualifiedfoundation 1 "F.swift:4: #Predicate"

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
