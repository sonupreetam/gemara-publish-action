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
# The working-directory guard does not cover the file path itself: an
# absolute path, ../, or a symlinked file can point outside the workspace.
assert_within_workspace "${FILE}" "file"

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
    # grc.store hubs refuse unsigned bundles at sync (catalog_unsigned):
    # the publish uploads but cannot complete. Intended for direct mode or
    # self-hosted hubs that accept unsigned material.
    echo "::warning::no_sign=true in hub mode: grc.store refuses unsigned bundles at sync; the publish will upload but fail to complete."
    PUBLISH_ARGS+=(--no-sign)
  fi

  echo "Publishing (hub mode): ${INPUT_FILE}"
  grcli publish "${PUBLISH_ARGS[@]}" 2>&1 | tee "${RUNNER_TEMP}/grcli-publish-out.txt"

  # Extract the manifest digest from grcli output. Anchored on the
  # "manifest digest:" label so a body or layer digest printed earlier
  # in the output cannot be grabbed by mistake.
  DIGEST=$(grep -oE 'manifest digest: sha256:[a-f0-9]{64}' "${RUNNER_TEMP}/grcli-publish-out.txt" | head -1 | grep -oE 'sha256:[a-f0-9]{64}' || true)
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
  # --version stamps metadata.version into the YAML before packing.
  # Precedence: the version input (explicit override), then the YAML's own
  # metadata.version (grcli reads it when no --version is passed), then the
  # tag input as a rescue for files that omit the version — grcli refuses
  # to pack those without one. The tag never stamps over a version the
  # file already carries.
  VERSION_ARG=""
  if [[ -n "${INPUT_VERSION}" ]]; then
    VERSION_ARG="${INPUT_VERSION}"
  elif [[ -n "${INPUT_TAG}" ]] && ! yaml_has_metadata_version "${FILE}"; then
    VERSION_ARG="${INPUT_TAG}"
  fi
  if [[ -n "${VERSION_ARG}" ]]; then
    PUBLISH_ARGS+=(--version "${VERSION_ARG}")
  fi
  echo "Packing bundle: ${INPUT_FILE}"
  grcli publish "${PUBLISH_ARGS[@]}" 2>&1 | tee "${RUNNER_TEMP}/grcli-publish-out.txt"

  # When a version was passed the layout tag matches it; otherwise extract
  # it from grcli output (metadata.version from the YAML).
  # Assumption: grcli --dry-run prints a line containing "oci:<path>:<tag>"
  # (e.g. "oci:/tmp/bundle:0.0.1"). If grcli changes its output format,
  # this regex will fail and hit the error branch below.
  if [[ -n "${VERSION_ARG}" ]]; then
    LAYOUT_TAG="${VERSION_ARG}"
  else
    LAYOUT_TAG=$(grep -oE 'oci:.*:([^ ]+)' "${RUNNER_TEMP}/grcli-publish-out.txt" | head -1 | sed 's/.*://' || true)
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
