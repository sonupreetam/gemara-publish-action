#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Publish step for gemara-publish-action.
# Called by action.yml with env vars set from action inputs.
#
# Env vars consumed (set by action.yml env: block):
#   INPUT_WORKING_DIRECTORY, INPUT_FILE, INPUT_LICENSE, INPUT_TAG,
#   INPUT_REGISTRY, INPUT_REPOSITORY, INPUT_USERNAME, INPUT_PASSWORD,
#   INPUT_VERSION, INPUT_NO_SIGN, GRCLI_URL,
#   GITHUB_WORKSPACE, GITHUB_ACTOR, GITHUB_OUTPUT, RUNNER_TEMP

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

validate_working_directory
FILE="$(realpath "${INPUT_FILE}")"

if [[ -n "${GRCLI_URL}" ]]; then
  # ── Hub mode ──────────────────────────────────────────────
  # grcli publish pushes through the hub: discovery, OIDC auth,
  # in-process sigstore-go signing, hub sync. No ORAS push needed.
  PUBLISH_ARGS=(-f "$FILE" --license "${INPUT_LICENSE}")

  if [[ -n "${INPUT_REPOSITORY}" ]]; then
    PUBLISH_ARGS+=(--repository "${INPUT_REPOSITORY}")
  fi
  if [[ -n "${INPUT_VERSION}" ]]; then
    PUBLISH_ARGS+=(--version "${INPUT_VERSION}")
  fi
  if [[ "${INPUT_NO_SIGN}" == "true" ]]; then
    PUBLISH_ARGS+=(--no-sign)
  fi

  echo "Publishing (hub mode): ${INPUT_FILE}"
  grcli publish "${PUBLISH_ARGS[@]}" 2>&1 | tee "${RUNNER_TEMP}/grcli-publish-out.txt"

  # Extract digest from grcli output (prints "manifest digest: sha256:...").
  DIGEST=$(grep -oE 'sha256:[a-f0-9]{64}' "${RUNNER_TEMP}/grcli-publish-out.txt" | head -1 || true)
  if [[ -z "${DIGEST}" ]]; then
    echo "::error::Could not extract digest from grcli publish output"
    cat "${RUNNER_TEMP}/grcli-publish-out.txt"
    exit 1
  fi
  echo "digest=${DIGEST}" >> "${GITHUB_OUTPUT}"
  echo "mode=hub" >> "${GITHUB_OUTPUT}"
  echo "Published via hub (digest: ${DIGEST})"
else
  # ── Direct mode ───────────────────────────────────────────
  # grcli dry-run packs locally, ORAS pushes to the caller's registry.
  LAYOUT_DIR="${RUNNER_TEMP}/grcli-bundle"
  rm -rf "${LAYOUT_DIR}"

  PUBLISH_ARGS=(-f "$FILE" --license "${INPUT_LICENSE}" --dry-run --no-sign --output "${LAYOUT_DIR}")
  if [[ -n "${INPUT_VERSION}" ]]; then
    PUBLISH_ARGS+=(--version "${INPUT_VERSION}")
  fi
  echo "Packing bundle: ${INPUT_FILE}"
  grcli publish "${PUBLISH_ARGS[@]}" 2>&1 | tee "${RUNNER_TEMP}/grcli-publish-out.txt"

  # When --version is set the layout tag is known; otherwise extract
  # it from grcli output (metadata.version).
  # Assumption: grcli --dry-run prints a line containing "oci:<path>:<tag>"
  # (e.g. "oci:/tmp/bundle:0.0.1"). If grcli changes its output format,
  # this regex will fail and hit the error branch below.
  if [[ -n "${INPUT_VERSION}" ]]; then
    LAYOUT_TAG="${INPUT_VERSION}"
  else
    LAYOUT_TAG=$(grep -oE 'oci:.*:([^ ]+)' "${RUNNER_TEMP}/grcli-publish-out.txt" | head -1 | sed 's/.*://')
    if [[ -z "${LAYOUT_TAG}" ]]; then
      echo "::error::Could not determine layout tag from grcli output"
      cat "${RUNNER_TEMP}/grcli-publish-out.txt"
      exit 1
    fi
  fi
  echo "Layout tag: ${LAYOUT_TAG}"

  # Push the OCI layout to the caller's registry via ORAS.
  DEST_REF="${INPUT_REGISTRY}/${INPUT_REPOSITORY}:${INPUT_TAG}"
  source_user="${INPUT_USERNAME:-${GITHUB_ACTOR:-oauth2}}"
  echo "${INPUT_PASSWORD}" | oras login "${INPUT_REGISTRY}" -u "${source_user}" --password-stdin

  echo "Pushing to ${DEST_REF}"
  oras copy --from-oci-layout "${LAYOUT_DIR}:${LAYOUT_TAG}" "${DEST_REF}" 2>&1

  # Resolve the pushed digest
  DIGEST="$(oras resolve "${DEST_REF}" | tr -d '\r\n')"
  if [[ -z "${DIGEST}" ]]; then
    echo "::error::Failed to resolve digest for ${DEST_REF}"
    exit 1
  fi
  echo "digest=${DIGEST}" >> "${GITHUB_OUTPUT}"
  echo "mode=direct" >> "${GITHUB_OUTPUT}"
  echo "Published ${DEST_REF} (digest: ${DIGEST})"
fi
