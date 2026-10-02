#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for gemara-publish-action scripts.
# Sourced by publish.sh and finalize.sh.

# Normalize an OCI digest to lowercase sha256:<64hex>.
# Usage: DIGEST=$(normalize_oci_digest "$raw_digest")
normalize_oci_digest() {
  local d="${1//$'\r'/}"
  d="${d//$'\n'/}"
  d="${d,,}"
  if [[ "$d" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo "$d"
    return 0
  fi
  if [[ "$d" =~ ^[a-f0-9]{64}$ ]]; then
    echo "sha256:$d"
    return 0
  fi
  echo "::error::Expected sha256 manifest digest, got: $1" >&2
  return 1
}

# Validate that the working directory resolves inside GITHUB_WORKSPACE.
# Exits with error if the resolved path escapes the workspace.
# Usage: validate_working_directory
#   Expects: INPUT_WORKING_DIRECTORY and GITHUB_WORKSPACE to be set.
#   Side effect: changes directory to the validated path.
validate_working_directory() {
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKING_DIRECTORY}" || exit 1
  local resolved_dir
  resolved_dir="$(pwd -P)"
  if [[ "${resolved_dir}" != "${GITHUB_WORKSPACE}"* ]]; then
    echo "::error::working_directory resolves outside the workspace"
    exit 1
  fi
}
