#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Finalize step for gemara-publish-action: sign, verify, promote.
# Called by action.yml with env vars set from action inputs.
#
# Env vars consumed (set by action.yml env: block):
#   PUBLISH_MODE, REGISTRY, REPOSITORY, TAG, PASSWORD, USERNAME,
#   SOURCE_DIGEST, SIGN_SOURCE, VERIFY_SOURCE, NO_SIGN,
#   PROMOTE, DEST_REGISTRY, DEST_REPOSITORY, DEST_TAG,
#   DEST_USERNAME, DEST_PASSWORD, TRUST_MODE,
#   SIGN_DESTINATION, VERIFY_DESTINATION,
#   ALLOWED_IDENTITY_REGEX, DEFAULT_ALLOWED_IDENTITY_REGEX,
#   COSIGN_CERTIFICATE_OIDC_ISSUER,
#   GITHUB_OUTPUT, GITHUB_ACTOR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${GITHUB_OUTPUT:?}"

# Output accumulators -- each key written exactly once at the end.
# Verification uses three states:
#   true    — verification ran and passed
#   false   — verification ran and failed (script exits non-zero before this)
#   skipped — verification was not attempted (hub mode, signing disabled, etc.)
OUT_SOURCE_REF=""
OUT_VERIFIED_SOURCE="skipped"
OUT_VERIFIED_DESTINATION="skipped"
OUT_DESTINATION_REF=""
OUT_DESTINATION_DIGEST=""

if [[ -z "${SOURCE_DIGEST:-}" ]]; then
  echo "::error::No digest produced by publish step."
  exit 1
fi
if ! SOURCE_DIGEST=$(normalize_oci_digest "$SOURCE_DIGEST"); then
  exit 1
fi

if [[ -z "${ALLOWED_IDENTITY_REGEX:-}" ]]; then
  ALLOWED_IDENTITY_REGEX="${DEFAULT_ALLOWED_IDENTITY_REGEX}"
fi

verify_ref() {
  local ref="$1"
  cosign verify "$ref" \
    --certificate-oidc-issuer "${COSIGN_CERTIFICATE_OIDC_ISSUER}" \
    --certificate-identity-regexp "${ALLOWED_IDENTITY_REGEX}" >/dev/null
}

if [[ "${PUBLISH_MODE}" == "hub" ]]; then
  # ── Hub mode finalize ─────────────────────────────────────
  # grcli handled signing in-process. The source ref is
  # hub-managed; we record what we know (repository + digest).
  if [[ -n "${REPOSITORY}" ]]; then
    OUT_SOURCE_REF="${REPOSITORY}@${SOURCE_DIGEST}"
  else
    echo "::warning::Hub mode without repository input — source_ref is digest-only (@${SOURCE_DIGEST}) and not a pullable OCI reference."
    OUT_SOURCE_REF="@${SOURCE_DIGEST}"
  fi
else
  # ── Direct mode finalize ──────────────────────────────────
  SOURCE_REF="${REGISTRY}/${REPOSITORY}@${SOURCE_DIGEST}"
  OUT_SOURCE_REF="${SOURCE_REF}"

  source_user="${USERNAME:-${GITHUB_ACTOR:-oauth2}}"

  if [[ "${SIGN_SOURCE}" == "true" || "${VERIFY_SOURCE}" == "true" ]]; then
    if [[ -n "${PASSWORD:-}" ]]; then
      echo "${PASSWORD}" | docker login "${REGISTRY}" -u "${source_user}" --password-stdin
    fi
  fi

  if [[ "${NO_SIGN}" != "true" && "${SIGN_SOURCE}" == "true" ]]; then
    echo "Signing source digest: ${SOURCE_REF}"
    cosign sign -y "${SOURCE_REF}"
  fi

  if [[ "${VERIFY_SOURCE}" == "true" ]]; then
    echo "Verifying source digest: ${SOURCE_REF}"
    verify_ref "${SOURCE_REF}"
    OUT_VERIFIED_SOURCE="true"
  fi
fi

# ── Write non-promotion outputs ──────────────────────────────
# Written here so they are emitted even when promotion is skipped.
{
  echo "source_ref=${OUT_SOURCE_REF}"
  echo "source_digest=${SOURCE_DIGEST}"
  echo "trust_mode=${TRUST_MODE}"
  echo "verified_source=${OUT_VERIFIED_SOURCE}"
} >> "${GITHUB_OUTPUT}"

if [[ "${PROMOTE}" != "true" ]]; then
  # Write promotion defaults and exit.
  {
    echo "destination_ref="
    echo "destination_digest="
    echo "verified_destination=skipped"
  } >> "${GITHUB_OUTPUT}"
  exit 0
fi

# ── Promotion (both modes) ───────────────────────────────────

if [[ -z "${DEST_REPOSITORY}" || -z "${DEST_USERNAME}" || -z "${DEST_PASSWORD}" ]]; then
  echo "::error::destination_repository, destination_username, and destination_password are required when promote_to_destination is true."
  exit 1
fi
if [[ -z "${DEST_REGISTRY}" ]]; then
  echo "::error::destination_registry is required when promote_to_destination is true."
  exit 1
fi

# Determine the source reference for ORAS copy.
if [[ "${PUBLISH_MODE}" == "hub" ]]; then
  if [[ -z "${REPOSITORY}" ]]; then
    echo "::error::repository input is required for promotion in hub mode (needed to construct source reference for ORAS copy)."
    exit 1
  fi
  # NOTE: REPOSITORY must include the registry host (e.g., ghcr.io/org/repo)
  # for oras copy to resolve the source. A bare path defaults to docker.io.
  SOURCE_COPY_REF="${REPOSITORY}@${SOURCE_DIGEST}"
else
  SOURCE_COPY_REF="${REGISTRY}/${REPOSITORY}@${SOURCE_DIGEST}"
  if [[ -z "${PASSWORD}" ]]; then
    echo "::error::password is required to pull source image from registry during promotion."
    exit 1
  fi
  source_user="${USERNAME:-${GITHUB_ACTOR:-oauth2}}"
  echo "${PASSWORD}" | oras login "${REGISTRY}" -u "${source_user}" --password-stdin
fi

DEST_TAG_RESOLVED="${DEST_TAG:-${TAG:-latest}}"
DEST_REF_TAGGED="${DEST_REGISTRY}/${DEST_REPOSITORY}:${DEST_TAG_RESOLVED}"

echo "${DEST_PASSWORD}" | oras login "${DEST_REGISTRY}" -u "${DEST_USERNAME}" --password-stdin
if [[ "${TRUST_MODE}" == "resign" || "${SIGN_DESTINATION}" == "true" || "${VERIFY_DESTINATION}" == "true" ]]; then
  echo "${DEST_PASSWORD}" | docker login "${DEST_REGISTRY}" -u "${DEST_USERNAME}" --password-stdin
fi

case "${TRUST_MODE}" in
  copy-only)
    oras copy "${SOURCE_COPY_REF}" "${DEST_REF_TAGGED}"
    ;;
  copy-referrers)
    oras copy --recursive "${SOURCE_COPY_REF}" "${DEST_REF_TAGGED}"
    ;;
  resign)
    oras copy "${SOURCE_COPY_REF}" "${DEST_REF_TAGGED}"
    ;;
  *)
    echo "::error::Unsupported trust_mode: ${TRUST_MODE} (copy-only, copy-referrers, resign)"
    exit 1
    ;;
esac

DEST_DIGEST="$(oras resolve "${DEST_REF_TAGGED}" | tr -d '\r\n')"
if [[ -z "${DEST_DIGEST}" ]]; then
  echo "::error::Failed to resolve destination digest for ${DEST_REF_TAGGED}"
  exit 1
fi
if ! DEST_DIGEST=$(normalize_oci_digest "$DEST_DIGEST"); then
  exit 1
fi
OUT_DESTINATION_REF="${DEST_REGISTRY}/${DEST_REPOSITORY}@${DEST_DIGEST}"
OUT_DESTINATION_DIGEST="${DEST_DIGEST}"

# Verify the promoted bundle matches the source by comparing digests.
# This proves the copy is the same bundle, not just independently valid.
if [[ "${SOURCE_DIGEST}" != "${DEST_DIGEST}" ]]; then
  echo "::error::Digest mismatch after promotion: source=${SOURCE_DIGEST} destination=${DEST_DIGEST}"
  exit 1
fi
echo "Digest match verified: source and destination are the same bundle"

if [[ "${NO_SIGN}" != "true" ]]; then
  if [[ "${TRUST_MODE}" == "resign" || "${SIGN_DESTINATION}" == "true" ]]; then
    echo "Signing destination digest: ${OUT_DESTINATION_REF}"
    cosign sign -y "${OUT_DESTINATION_REF}"
  fi
fi

if [[ "${VERIFY_DESTINATION}" == "true" ]]; then
  echo "Verifying destination digest: ${OUT_DESTINATION_REF}"
  verify_ref "${OUT_DESTINATION_REF}"
  OUT_VERIFIED_DESTINATION="true"
fi

# ── Write promotion outputs ──────────────────────────────────
{
  echo "destination_ref=${OUT_DESTINATION_REF}"
  echo "destination_digest=${OUT_DESTINATION_DIGEST}"
  echo "verified_destination=${OUT_VERIFIED_DESTINATION}"
} >> "${GITHUB_OUTPUT}"
