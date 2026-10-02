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

# Initialize default outputs
echo "destination_ref=" >> "${GITHUB_OUTPUT}"
echo "destination_digest=" >> "${GITHUB_OUTPUT}"
echo "trust_mode=${TRUST_MODE}" >> "${GITHUB_OUTPUT}"
echo "verified_source=false" >> "${GITHUB_OUTPUT}"
echo "verified_destination=false" >> "${GITHUB_OUTPUT}"

if [[ -z "${SOURCE_DIGEST:-}" ]]; then
  echo "::error::No digest produced by publish step."
  exit 1
fi
if ! SOURCE_DIGEST=$(normalize_oci_digest "$SOURCE_DIGEST"); then
  exit 1
fi
echo "source_digest=${SOURCE_DIGEST}" >> "${GITHUB_OUTPUT}"

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
    echo "source_ref=${REPOSITORY}@${SOURCE_DIGEST}" >> "${GITHUB_OUTPUT}"
  else
    echo "::warning::Hub mode without repository input — source_ref is digest-only (@${SOURCE_DIGEST}) and not a pullable OCI reference."
    echo "source_ref=@${SOURCE_DIGEST}" >> "${GITHUB_OUTPUT}"
  fi
else
  # ── Direct mode finalize ──────────────────────────────────
  SOURCE_REF="${REGISTRY}/${REPOSITORY}@${SOURCE_DIGEST}"
  echo "source_ref=${SOURCE_REF}" >> "${GITHUB_OUTPUT}"

  source_user="${USERNAME:-${GITHUB_ACTOR:-oauth2}}"

  if [[ "${NO_SIGN}" != "true" ]]; then
    if [[ "${SIGN_SOURCE}" == "true" || "${VERIFY_SOURCE}" == "true" ]]; then
      if [[ -n "${PASSWORD:-}" ]]; then
        echo "${PASSWORD}" | docker login "${REGISTRY}" -u "${source_user}" --password-stdin
      fi
    fi

    if [[ "${SIGN_SOURCE}" == "true" ]]; then
      echo "Signing source digest: ${SOURCE_REF}"
      cosign sign -y "${SOURCE_REF}"
    fi

    if [[ "${VERIFY_SOURCE}" == "true" ]]; then
      echo "Verifying source digest: ${SOURCE_REF}"
      verify_ref "${SOURCE_REF}"
      echo "verified_source=true" >> "${GITHUB_OUTPUT}"
    fi
  fi
fi

# ── Promotion (both modes) ───────────────────────────────────
if [[ "${PROMOTE}" != "true" ]]; then
  exit 0
fi

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
  # In hub mode, the source is on the hub-managed registry.
  # Promotion requires the repository input to construct the source ref.
  if [[ -z "${REPOSITORY}" ]]; then
    echo "::error::repository input is required for promotion in hub mode (needed to construct source reference for ORAS copy)."
    exit 1
  fi
  SOURCE_COPY_REF="${REPOSITORY}@${SOURCE_DIGEST}"
else
  SOURCE_COPY_REF="${REGISTRY}/${REPOSITORY}:${TAG}"
  # In direct mode, password is needed to pull from source during promotion.
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
DEST_REF="${DEST_REGISTRY}/${DEST_REPOSITORY}@${DEST_DIGEST}"

if [[ "${TRUST_MODE}" == "resign" || "${SIGN_DESTINATION}" == "true" ]]; then
  echo "Signing destination digest: ${DEST_REF}"
  cosign sign -y "${DEST_REF}"
fi

if [[ "${VERIFY_DESTINATION}" == "true" ]]; then
  echo "Verifying destination digest: ${DEST_REF}"
  verify_ref "${DEST_REF}"
  echo "verified_destination=true" >> "${GITHUB_OUTPUT}"
fi

echo "destination_ref=${DEST_REF}" >> "${GITHUB_OUTPUT}"
echo "destination_digest=${DEST_DIGEST}" >> "${GITHUB_OUTPUT}"
