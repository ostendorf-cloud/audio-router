#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# THROWAWAY for issue 86. Never merge to main. Delete it with .github/workflows/spike-tap-steps.yaml.
# Shell functions of that workflow, sourced by its steps. Loading it changes nothing.
# Environment: RUNNER_TEMP (set by GitHub), LOG_CAP (bytes printed per log window).
#
#   build_tone                  builds $RUNNER_TEMP/tone.app from .github/spike/tone.swift, ad hoc signed
#   start_tone                  plays the tone in the background for 10 minutes
#   start_stream                writes `log stream --info --debug` of coreaudiod, tccd and the TCC subsystem to a file
#   stop_stream                 ends that stream
#   window_begin <name>         records the local start time of a window
#   window_end <name>           records its end time
#   log_window <name>           prints the stream lines of a window, capped by LOG_CAP bytes
#   bounded <seconds> <cmd...>  runs a command, TERM at the limit, KILL 5 s later, returns its exit code

now_local() {
  date '+%Y-%m-%d %H:%M:%S'
}

build_tone() {
  local app="${RUNNER_TEMP}/tone.app"
  mkdir -p "${app}/Contents/MacOS"
  swiftc -swift-version 5 -O .github/spike/tone.swift -o "${app}/Contents/MacOS/tone"
  cp .github/spike/tone-Info.plist "${app}/Contents/Info.plist"
  codesign --force --sign - "${app}"
  codesign --verify --verbose=2 "${app}"
}

start_tone() {
  "${RUNNER_TEMP}/tone.app/Contents/MacOS/tone" 600 > "${RUNNER_TEMP}/tone.log" 2>&1 &
  sleep 5
  echo "-- tone log"
  cat "${RUNNER_TEMP}/tone.log"
}

start_stream() {
  # The file belongs to the runner user on purpose, only `log stream` needs root.
  # shellcheck disable=SC2024
  sudo log stream --info --debug --style compact \
    --predicate 'process == "coreaudiod" OR process == "tccd" OR subsystem == "com.apple.TCC"' \
    > "${RUNNER_TEMP}/stream.log" 2>&1 &
  sleep 3
  echo "SPIKE[stream] started at $(now_local), file ${RUNNER_TEMP}/stream.log"
}

stop_stream() {
  sleep 3
  sudo pkill -TERM -f 'log stream --info' || true
  sleep 2
  echo "SPIKE[stream] stopped at $(now_local), $(wc -c < "${RUNNER_TEMP}/stream.log" | tr -d ' ') bytes in the file"
}

window_begin() {
  now_local > "${RUNNER_TEMP}/win-$1.start"
  echo "SPIKE[window:$1] begin $(cat "${RUNNER_TEMP}/win-$1.start")"
}

window_end() {
  sleep 2
  now_local > "${RUNNER_TEMP}/win-$1.end"
  echo "SPIKE[window:$1] end $(cat "${RUNNER_TEMP}/win-$1.end")"
}

log_window() {
  local name="$1" start end out
  out="${RUNNER_TEMP}/win-${name}.log"
  if [ ! -f "${RUNNER_TEMP}/win-${name}.start" ]; then
    echo "SPIKE[log:${name}] window was not run"
    return 0
  fi
  start="$(cat "${RUNNER_TEMP}/win-${name}.start")"
  if [ -f "${RUNNER_TEMP}/win-${name}.end" ]; then
    end="$(cat "${RUNNER_TEMP}/win-${name}.end")"
  else
    end="$(now_local)"
  fi
  # The first 19 characters of a compact line are the local time to the second.
  awk -v s="${start}" -v e="${end}" '{ t = substr($1 " " $2, 1, 19); if (t >= s && t <= e) print }' \
    "${RUNNER_TEMP}/stream.log" > "${out}"
  echo "SPIKE[log:${name}] window ${start} to ${end}: $(wc -l < "${out}" | tr -d ' ') lines," \
    "$(wc -c < "${out}" | tr -d ' ') bytes, coreaudiod $(grep -c 'coreaudiod\[' "${out}" || true)," \
    "tccd $(grep -c 'tccd\[' "${out}" || true), the print stops at ${LOG_CAP} bytes"
  echo "-- begin log ${name}"
  head -c "${LOG_CAP}" "${out}"
  echo "-- end log ${name}"
}

bounded() {
  local limit="$1" pid began rc=0
  shift
  "$@" &
  pid=$!
  began=${SECONDS}
  while kill -0 "${pid}" 2>/dev/null; do
    if [ $((SECONDS - began)) -ge "${limit}" ]; then
      echo "SPIKE[bounded] ${limit} s reached, sending TERM to ${pid}"
      kill -TERM "${pid}" 2>/dev/null || true
      sleep 5
      if kill -0 "${pid}" 2>/dev/null; then
        echo "SPIKE[bounded] still alive after TERM, sending KILL"
        kill -KILL "${pid}" 2>/dev/null || true
      fi
      break
    fi
    sleep 1
  done
  wait "${pid}" || rc=$?
  return "${rc}"
}
