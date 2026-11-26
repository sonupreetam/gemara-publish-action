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

# Exit 0 when the Gemara YAML at $1 carries a non-empty metadata.version.
# Usage: yaml_has_metadata_version <file>
#   Degrades to "no version" (exit 1) on any parse failure, which makes the
#   caller fall back to the tag — the pre-existing behavior.
yaml_has_metadata_version() {
  python3 - "$1" << 'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        doc = yaml.safe_load(f)
    version = (doc or {}).get("metadata", {}).get("version")
    sys.exit(0 if version else 1)
except Exception:
    sys.exit(1)
PYEOF
}

# Validate that a resolved path stays inside GITHUB_WORKSPACE.
# Usage: assert_within_workspace "$resolved_path" ["label"]
#   Expects: GITHUB_WORKSPACE to be set.
assert_within_workspace() {
  local path="$1" label="${2:-path}"
  local workspace_dir
  workspace_dir="$(cd -- "${GITHUB_WORKSPACE}" && pwd -P)" || exit 1
  if [[ "${path}" != "${workspace_dir}" && "${path}" != "${workspace_dir%/}/"* ]]; then
    echo "::error::${label} resolves outside the workspace: ${path}"
    exit 1
  fi
}

# Discover the hub registry host from a hub's .well-known configuration.
# Usage: hub_registry_host <hub_url>
#   Echoes the registry host (scheme and trailing slash stripped) and exits 0,
#   or exits non-zero with a ::error on stderr. The host is validated against
#   a strict pattern — no newlines or shell metacharacters — so the result is
#   safe to write to GITHUB_ENV. Single source of truth for hub discovery:
#   finalize.sh and the grcli-canary workflow both call this.
hub_registry_host() {
  local hub_url="$1" discovery_json host
  if ! discovery_json=$(curl -sf "${hub_url}/.well-known/grc-store-configuration" 2>&1); then
    echo "::error::hub discovery request failed: ${discovery_json}" >&2
    return 1
  fi
  if ! host=$(printf '%s' "${discovery_json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('registry_url',''))" 2>/dev/null); then
    echo "::error::hub discovery returned unparseable JSON" >&2
    return 1
  fi
  host="${host#https://}"
  host="${host#http://}"
  host="${host%/}"
  if ! [[ "${host}" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
    echo "::error::hub discovery returned an invalid registry host: '${host}'" >&2
    return 1
  fi
  printf '%s' "${host}"
}

# Validate that the working directory resolves inside GITHUB_WORKSPACE.
# Exits with error if the resolved path escapes the workspace.
# Usage: validate_working_directory
#   Expects: INPUT_WORKING_DIRECTORY and GITHUB_WORKSPACE to be set.
#   Side effect: changes directory to the validated path.
validate_working_directory() {
  local workspace_dir
  workspace_dir="$(cd -- "${GITHUB_WORKSPACE}" && pwd -P)" || exit 1
  cd -- "${workspace_dir%/}/${INPUT_WORKING_DIRECTORY}" || exit 1
  local resolved_dir
  resolved_dir="$(pwd -P)"
  if [[ "${resolved_dir}" != "${workspace_dir}" && "${resolved_dir}" != "${workspace_dir%/}/"* ]]; then
    echo "::error::working_directory resolves outside the workspace"
    exit 1
  fi
}
