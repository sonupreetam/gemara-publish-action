#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Integration tests for publish.sh and finalize.sh.
# Requires: podman (or docker), oras, bash 4+.
#
# Tests:
#   1. Hub mode publish path — digest extraction from grcli output
#   2. Direct mode with no_sign=true — signing skipped, outputs correct
#   3. validate_working_directory rejection via publish.sh entry point
#
# Run: bash scripts/test_integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
CONTAINER_NAME="test-registry-$$"
REGISTRY_PORT=""
TMPDIR_TEST=""

cleanup() {
  if [[ -n "${CONTAINER_NAME}" ]]; then
    podman rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  fi
  if [[ -n "${TMPDIR_TEST}" ]]; then
    rm -rf "${TMPDIR_TEST}"
  fi
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: ${label}"
    ((PASS++))
  else
    echo "  FAIL: ${label} — expected '${expected}', got '${actual}'"
    ((FAIL++))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: ${label}"
    ((PASS++))
  else
    echo "  FAIL: ${label} — '${needle}' not found in output"
    ((FAIL++))
  fi
}

# ── Setup ──────────────────────────────────────────────────────
echo "=== Setup ==="

TMPDIR_TEST=$(mktemp -d)
TMPDIR_TEST=$(cd "${TMPDIR_TEST}" && pwd -P)

if ! command -v podman &>/dev/null; then
  echo "SKIP: podman not found"
  exit 0
fi
if ! command -v oras &>/dev/null; then
  echo "SKIP: oras not found"
  exit 0
fi

REGISTRY_PORT=5555
podman run -d --name "${CONTAINER_NAME}" -p "${REGISTRY_PORT}:5000" \
  docker.io/library/registry:2 >/dev/null 2>&1
echo "Registry started on localhost:${REGISTRY_PORT}"

for i in {1..10}; do
  if curl -sf "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# ── Test 1: Hub mode publish — digest extraction ─────────────
echo ""
echo "=== Test 1: Hub mode publish — digest extraction ==="

MOCK_BIN="${TMPDIR_TEST}/bin"
mkdir -p "${MOCK_BIN}"
KNOWN_DIGEST="sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

cat > "${MOCK_BIN}/grcli" << MOCK
#!/usr/bin/env bash
echo "Publishing bundle..."
echo "manifest digest: ${KNOWN_DIGEST}"
echo "Done."
MOCK
chmod +x "${MOCK_BIN}/grcli"

GITHUB_OUTPUT="${TMPDIR_TEST}/hub-output.txt"
RUNNER_TEMP="${TMPDIR_TEST}/runner"
mkdir -p "${RUNNER_TEMP}"
GITHUB_WORKSPACE="${TMPDIR_TEST}/workspace"
mkdir -p "${GITHUB_WORKSPACE}"
cp "${REPO_DIR}/testdata/minimal-catalog.yaml" "${GITHUB_WORKSPACE}/"

export PATH="${MOCK_BIN}:${PATH}"
export GITHUB_OUTPUT RUNNER_TEMP GITHUB_WORKSPACE
export GRCLI_URL="https://mock.hub.example"
export INPUT_WORKING_DIRECTORY="."
export INPUT_FILE="minimal-catalog.yaml"
export INPUT_LICENSE="Apache-2.0"
export INPUT_REPOSITORY="test/hub-repo"
export INPUT_VERSION="1.0.0"
export INPUT_NO_SIGN="false"
export INPUT_TAG=""
export INPUT_REGISTRY=""
export INPUT_USERNAME=""
export INPUT_PASSWORD=""
export GITHUB_ACTOR="test-actor"

bash "${SCRIPT_DIR}/publish.sh"
hub_rc=$?

assert_eq "hub publish exits 0" "0" "$hub_rc"

if [[ -f "${GITHUB_OUTPUT}" ]]; then
  hub_digest=$(grep '^digest=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  hub_mode=$(grep '^mode=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  assert_eq "hub digest extracted" "${KNOWN_DIGEST}" "${hub_digest}"
  assert_eq "hub mode output" "hub" "${hub_mode}"
else
  echo "  FAIL: GITHUB_OUTPUT not written"
  ((FAIL++))
fi

# ── Test 2: Finalize with no_sign — signing skipped ──────────
echo ""
echo "=== Test 2: Finalize with no_sign=true (direct mode) ==="

unset GRCLI_URL
export PATH="${PATH#${MOCK_BIN}:}"

oras copy --from-oci-layout "${REPO_DIR}/testdata/legacy-bundle:0.0.1" \
  "localhost:${REGISTRY_PORT}/test/nosign:latest" 2>/dev/null

REAL_DIGEST=$(oras resolve "localhost:${REGISTRY_PORT}/test/nosign:latest" 2>/dev/null | tr -d '\r\n')
echo "Real digest: ${REAL_DIGEST}"

GITHUB_OUTPUT="${TMPDIR_TEST}/nosign-output.txt"
> "${GITHUB_OUTPUT}"

export GITHUB_OUTPUT
export PUBLISH_MODE="direct"
export REGISTRY="localhost:${REGISTRY_PORT}"
export REPOSITORY="test/nosign"
export TAG="latest"
export PASSWORD="test"
export USERNAME="test"
export SOURCE_DIGEST="${REAL_DIGEST}"
export SIGN_SOURCE="false"
export VERIFY_SOURCE="false"
export NO_SIGN="true"
export PROMOTE="false"
export DEST_REGISTRY="" DEST_REPOSITORY="" DEST_TAG=""
export DEST_USERNAME="" DEST_PASSWORD=""
export TRUST_MODE="resign"
export SIGN_DESTINATION="true"
export VERIFY_DESTINATION="false"
export ALLOWED_IDENTITY_REGEX=""
export DEFAULT_ALLOWED_IDENTITY_REGEX="^https://github.com/test/.github/workflows/"
export COSIGN_CERTIFICATE_OIDC_ISSUER="https://token.actions.githubusercontent.com"

bash "${SCRIPT_DIR}/finalize.sh"
nosign_rc=$?

assert_eq "finalize with no_sign exits 0" "0" "$nosign_rc"

if [[ -f "${GITHUB_OUTPUT}" ]]; then
  vs=$(grep '^verified_source=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  vd=$(grep '^verified_destination=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  sr=$(grep '^source_ref=' "${GITHUB_OUTPUT}" | cut -d= -f2)

  assert_eq "verified_source is skipped" "skipped" "${vs}"
  assert_eq "verified_destination is skipped" "skipped" "${vd}"
  assert_contains "source_ref contains digest" "${REAL_DIGEST}" "${sr}"
else
  echo "  FAIL: GITHUB_OUTPUT not written"
  ((FAIL++))
fi

# ── Test 3: validate_working_directory rejects traversal ─────
echo ""
echo "=== Test 3: validate_working_directory rejects traversal ==="

WS="${TMPDIR_TEST}/traversal-ws/deep/nested/project"
mkdir -p "${WS}"
WS=$(cd "${WS}" && pwd -P)
cp "${REPO_DIR}/testdata/minimal-catalog.yaml" "${WS}/"

ln -sf /tmp "${WS}/escape"

export GITHUB_WORKSPACE="${WS}"
export INPUT_WORKING_DIRECTORY="escape"
export INPUT_FILE="minimal-catalog.yaml"
export INPUT_LICENSE="Apache-2.0"
export GRCLI_URL=""
export GITHUB_OUTPUT="${TMPDIR_TEST}/traversal-output.txt"
export RUNNER_TEMP="${TMPDIR_TEST}/runner"

traversal_rc=0
output=$(bash "${SCRIPT_DIR}/publish.sh" 2>&1) || traversal_rc=$?

if [[ $traversal_rc -ne 0 ]]; then
  echo "  PASS: symlink traversal correctly rejected (exit ${traversal_rc})"
  ((PASS++))
else
  echo "  FAIL: symlink traversal should have been rejected but publish succeeded"
  ((FAIL++))
fi
assert_contains "error message mentions workspace" "working_directory resolves outside" "${output}"

# ── Results ──────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
