#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Pushes the Homebrew cask for the release TAG to the organisation's tap.
# Modelled on gitcd's scripts/publish-homebrew-formula.sh.
#
# Order, and why it is safe to run again:
#   1. the release must be published, so the cask's URL resolves, and must not
#      be a pre-release, by the release's own flags;
#   2. the zip and its .sha256 file are downloaded from the release;
#   3. the hash of the downloaded zip is verified, see VERIFY_MODE;
#   4. the cask is rendered from the version and that hash by render-cask.sh,
#      and its version and sha256 lines are checked against both;
#   5. the tap's current file is compared: an identical one is left alone, a
#      newer version in the tap is refused, otherwise one commit is made
#      through the contents API.
# A rerun for the same tag finds the identical file and changes nothing.
#
# VERIFY_MODE selects what the downloaded zip is verified against:
#   hash      (default) ZIP_SHA256, a hash an earlier job of the same run
#             recorded, and the release's .sha256 file. On a release event it is
#             the hash the bundle job computed before it uploaded the zip. On a
#             manual cask-tag run it is the hash the verify-asset job computed
#             on the zip it verified. Rests on the integrity of the workflow
#             run's own outputs. The workflow uses this mode on both paths.
#   checksums the release's .sha256 file only. No workflow calls it. It proves
#             the cask agrees with the published assets, not that they are the
#             ones the build produced or the ones a check verified.
#
# TAG is the release tag, such as v0.1.0. ALLOW_DOWNGRADE=true lets a tag older
# than the tap's cask through. GH_TOKEN reads this repository's release,
# TAP_TOKEN writes the tap only. Neither is ever printed.
set -euo pipefail

: "${TAG:?TAG is required}"
: "${TAP_TOKEN:?TAP_TOKEN is required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tap_repository="${TAP_REPOSITORY:-ostendorf-cloud/homebrew-tap}"
tap_branch="${TAP_BRANCH:-main}"
cask_path="${CASK_PATH:-Casks/audio-router.rb}"
verify_mode="${VERIFY_MODE:-hash}"
allow_downgrade="${ALLOW_DOWNGRADE:-false}"

case "${verify_mode}" in
hash | checksums) ;;
*)
  echo "unknown VERIFY_MODE ${verify_mode}, want hash or checksums" >&2
  exit 1
  ;;
esac

if ! [[ ${TAG} =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
  echo "${TAG} is not a release tag of the form vMAJOR.MINOR.PATCH" >&2
  exit 1
fi

work_dir=""
cleanup() {
  if [ -n "${work_dir}" ] && [ -d "${work_dir}" ]; then
    rm -rf "${work_dir}"
  fi
}
trap cleanup EXIT

# An explicit template, because macOS mktemp ignores TMPDIR without one.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/publish-homebrew-cask.XXXXXXXX")"

# tap_gh runs gh with the tap token only for the call that needs it.
tap_gh() {
  GH_TOKEN="${TAP_TOKEN}" gh "$@"
}

# cask_version <file> prints the version line of a cask, or nothing.
cask_version() {
  sed -n -E 's/^  version "([^"]*)"$/\1/p' "$1" | head -n 1
}

# The release's own flags decide, not the tag's spelling.
if ! flags="$(gh release view "${TAG}" --json isDraft,isPrerelease --jq '"\(.isDraft) \(.isPrerelease)"')"; then
  echo "cannot read the release for ${TAG}: it is missing, still a draft or not visible to the token" >&2
  exit 1
fi
read -r draft prerelease <<<"${flags}"
if [ "${draft}" != "false" ]; then
  echo "${TAG} is a draft, the cask's URL would not resolve" >&2
  exit 1
fi
if [ "${prerelease}" = "true" ]; then
  echo "${TAG} is a pre-release, no cask pushed"
  exit 0
fi
if ! [[ ${TAG} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "${TAG} is not a plain vMAJOR.MINOR.PATCH tag, nothing pushed" >&2
  exit 1
fi

version="${TAG#v}"
zip="audio-router-${version}-arm64.zip"
download_dir="${work_dir}/release"
mkdir -p "${download_dir}"
for asset in "${zip}" "${zip}.sha256"; do
  if ! gh release download "${TAG}" --pattern "${asset}" --dir "${download_dir}" --clobber; then
    echo "cannot download ${asset} from the release ${TAG}" >&2
    exit 1
  fi
done

got="$(shasum -a 256 "${download_dir}/${zip}" | cut -d' ' -f1)"

# The .sha256 file is one "<hash>  <name>" line, as app-release.yaml writes it.
read -r listed_hash listed_name <"${download_dir}/${zip}.sha256" || true
if [ "${listed_name:-}" != "${zip}" ] || [ "${listed_hash:-}" != "${got}" ]; then
  echo "${zip} of ${TAG} does not match the release's ${zip}.sha256, nothing pushed" >&2
  exit 1
fi

if [ "${verify_mode}" = "hash" ]; then
  if [ -z "${ZIP_SHA256:-}" ]; then
    echo "no zip hash recorded for ${TAG} by the bundle job or the verify-asset job of this run" >&2
    exit 1
  fi
  if [ "${got}" != "${ZIP_SHA256}" ]; then
    echo "${zip} of ${TAG} differs from the zip hash recorded by the bundle job or the verify-asset job, nothing pushed" >&2
    exit 1
  fi
fi

cask="${work_dir}/audio-router.rb"
"${script_dir}/render-cask.sh" "${version}" "${got}" "${cask}"
# States for the reader what the cask must carry before it leaves this job.
if ! grep -qxF "  version \"${version}\"" "${cask}" || ! grep -qxF "  sha256 \"${got}\"" "${cask}"; then
  echo "the rendered cask does not carry version ${version} and the hash of ${zip}, nothing pushed" >&2
  exit 1
fi

endpoint="repos/${tap_repository}/contents/${cask_path}"

# Read the current file first. Only a 404 means "no cask yet", any other
# failure (token, 5xx, rate limit) stops here instead of being mistaken for a
# missing file.
sha=""
if sha="$(tap_gh api "${endpoint}?ref=${tap_branch}" --jq .sha 2>"${work_dir}/api-error")"; then
  current="${work_dir}/current.rb"
  if ! tap_gh api -H "Accept: application/vnd.github.raw+json" "${endpoint}?ref=${tap_branch}" >"${current}"; then
    echo "cannot read ${cask_path} from ${tap_repository}" >&2
    exit 1
  fi
  if cmp -s "${current}" "${cask}"; then
    echo "${cask_path} in ${tap_repository} is already up to date for ${TAG}"
    exit 0
  fi
  # Never put an older cask over a newer one. Only the manual run can override
  # this, with its explicit input. sort -V is enough: only plain
  # MAJOR.MINOR.PATCH versions reach this point.
  tap_version="$(cask_version "${current}")"
  if [ -z "${tap_version}" ]; then
    echo "cannot read the version of ${cask_path} in ${tap_repository}" >&2
    exit 1
  fi
  newest="$(printf '%s\n%s\n' "${tap_version}" "${version}" | sort -V | tail -n 1)"
  if [ "${tap_version}" != "${version}" ] && [ "${newest}" = "${tap_version}" ] && [ "${allow_downgrade}" != "true" ]; then
    echo "the tap holds ${tap_version}, newer than ${version}: refusing to put an older cask back" >&2
    exit 1
  fi
elif grep -q "HTTP 404" "${work_dir}/api-error"; then
  sha=""
else
  echo "cannot read ${cask_path} from ${tap_repository}" >&2
  exit 1
fi

echo "pushing ${cask_path} for ${TAG} to ${tap_repository}"
put_args=(
  -X PUT "${endpoint}"
  -f "message=audio-router ${version}"
  -f "branch=${tap_branch}"
  -f "content=$(base64 <"${cask}" | tr -d '\n')"
)
if [ -n "${sha}" ]; then
  put_args+=(-f "sha=${sha}")
fi
if ! tap_gh api "${put_args[@]}" --silent; then
  echo "cannot push ${cask_path} for ${TAG} to ${tap_repository}: the release is public without a cask, use the manual run with the tag" >&2
  exit 1
fi
