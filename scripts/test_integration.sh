#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# allow-fake-secrets: this suite uses dummy credentials ("test") for a
# local, unauthenticated registry:2 container; nothing here is a real secret.
#
# Integration tests for publish.sh and finalize.sh.
# Requires: podman or docker, oras, bash 4+, python3.
#
# Tests:
#   1.  Hub mode publish path — digest extraction from grcli output
#   2.  Direct mode with no_sign=true — signing skipped, outputs correct
#   2b. no_sign=true with verify_source=true — verification skipped with warning
#   2c. Direct-mode promotion with :latest fallback — plus password no-leak
#   3.  validate_working_directory rejection via publish.sh entry point
#   4.  finalize.sh rejects empty SOURCE_DIGEST
#   5.  finalize.sh rejects malformed SOURCE_DIGEST
#   6.  Hub mode finalize — registry discovery, source_ref fallbacks
#   6b. Hub mode without repository — digest-only source_ref with warning
#   7.  Hub-mode promotion — repository-required error and discovery-based copy
#
# Run: bash scripts/test_integration.sh
# In CI (CI=true) missing tools fail the run instead of skipping.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
CONTAINER_NAME="test-registry-$$"
CONTAINER_RUNTIME=""
REGISTRY_PORT=""
TMPDIR_TEST=""

cleanup() {
  if [[ -n "${CONTAINER_NAME}" && -n "${CONTAINER_RUNTIME}" ]]; then
    "${CONTAINER_RUNTIME}" rm -f "${CONTAINER_NAME}" 2>/dev/null || true
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

# Container runtime: prefer podman, fall back to docker (GitHub-hosted
# runners ship docker; local dev boxes commonly have either).
if command -v podman &>/dev/null; then
  CONTAINER_RUNTIME="podman"
elif command -v docker &>/dev/null; then
  CONTAINER_RUNTIME="docker"
else
  echo "SKIP: no container runtime found (podman or docker)"
  if [[ "${CI:-}" == "true" ]]; then
    echo "::error::test_integration.sh requires podman or docker in CI — a silent skip here would read as a pass."
    exit 1
  fi
  exit 0
fi
if ! command -v oras &>/dev/null; then
  echo "SKIP: oras not found"
  if [[ "${CI:-}" == "true" ]]; then
    echo "::error::test_integration.sh requires oras in CI — a silent skip here would read as a pass."
    exit 1
  fi
  exit 0
fi

REGISTRY_PORT=5555
"${CONTAINER_RUNTIME}" run -d --name "${CONTAINER_NAME}" -p "${REGISTRY_PORT}:5000" \
  docker.io/library/registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null 2>&1
echo "Registry started on localhost:${REGISTRY_PORT} (${CONTAINER_RUNTIME})"

registry_ready=false
for i in {1..10}; do
  if curl -sf "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    registry_ready=true
    break
  fi
  sleep 0.5
done
if [[ "${registry_ready}" != "true" ]]; then
  echo "FAIL: Registry did not become ready on port ${REGISTRY_PORT}"
  exit 1
fi

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

ORIGINAL_PATH="${PATH}"
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
export PATH="${ORIGINAL_PATH}"

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

# ── Test 2b: no_sign=true with verify_source=true — verification skipped ──
echo ""
echo "=== Test 2b: no_sign=true with verify_source=true ==="

GITHUB_OUTPUT="${TMPDIR_TEST}/nosign-verify-output.txt"
> "${GITHUB_OUTPUT}"
export GITHUB_OUTPUT
export VERIFY_SOURCE="true"
# Empty password skips the registry login block (cosign is never invoked:
# the point of this test is the gate, and the suite must not depend on
# docker being present for it).
SAVED_PASSWORD="${PASSWORD}"
export PASSWORD=""

nosign_verify_rc=0
nosign_verify_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || nosign_verify_rc=$?

assert_eq "finalize with no_sign + verify_source exits 0" "0" "$nosign_verify_rc"
assert_contains "warns about the no_sign/verify_source interaction" "verify_source is true but no_sign is true" "${nosign_verify_output}"

if [[ -f "${GITHUB_OUTPUT}" ]]; then
  vs=$(grep '^verified_source=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  assert_eq "verified_source is skipped despite verify_source=true" "skipped" "${vs}"
else
  echo "  FAIL: GITHUB_OUTPUT not written"
  ((FAIL++))
fi

export VERIFY_SOURCE="false"
export PASSWORD="${SAVED_PASSWORD}"

# ── Test 2c: direct-mode promotion, :latest fallback, no password leak ──
echo ""
echo "=== Test 2c: direct promotion with :latest fallback and password hygiene ==="

GITHUB_OUTPUT="${TMPDIR_TEST}/promo-output.txt"
> "${GITHUB_OUTPUT}"
export GITHUB_OUTPUT
# Marker passwords: the spec requires the action SHALL NOT print the
# password to logs; the captured output is asserted clean below.
export PASSWORD="ci-marker-src-password-DoNotPrint"
export DEST_PASSWORD="ci-marker-dest-password-DoNotPrint"
export PUBLISH_MODE="direct"
export REGISTRY="localhost:${REGISTRY_PORT}"
export REPOSITORY="test/nosign"
export TAG=""
export PROMOTE="true"
export DEST_REGISTRY="localhost:${REGISTRY_PORT}"
export DEST_REPOSITORY="test/promo-dest"
export DEST_TAG=""
export DEST_USERNAME="test"
export TRUST_MODE="copy-only"
export SIGN_DESTINATION="false"
export VERIFY_DESTINATION="false"

promo_rc=0
promo_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || promo_rc=$?

assert_eq "direct promotion with empty tags exits 0" "0" "$promo_rc"
assert_contains "warns about the :latest fallback" "Neither destination_tag nor tag is set" "${promo_output}"
if [[ "${promo_output}" == *"ci-marker-src-password-DoNotPrint"* || "${promo_output}" == *"ci-marker-dest-password-DoNotPrint"* ]]; then
  echo "  FAIL: a password marker leaked into the output (spec: SHALL NOT print the password)"
  ((FAIL++))
else
  echo "  PASS: no password marker leaked into the output"
  ((PASS++))
fi

if [[ -f "${GITHUB_OUTPUT}" ]]; then
  dd=$(grep '^destination_digest=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  vd=$(grep '^verified_destination=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  assert_eq "destination_digest matches source" "${REAL_DIGEST}" "${dd}"
  assert_eq "verified_destination is skipped" "skipped" "${vd}"
  # The fallback must actually have pushed :latest.
  latest_digest=$(oras resolve "localhost:${REGISTRY_PORT}/test/promo-dest:latest" 2>/dev/null | tr -d '\r\n')
  assert_eq ":latest tag pushed by the fallback" "${REAL_DIGEST}" "${latest_digest}"
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

# ── Test 4: finalize.sh rejects empty SOURCE_DIGEST ──────────
echo ""
echo "=== Test 4: finalize.sh rejects empty SOURCE_DIGEST ==="

GITHUB_OUTPUT="${TMPDIR_TEST}/empty-digest-output.txt"
> "${GITHUB_OUTPUT}"

export GITHUB_OUTPUT
export PUBLISH_MODE="direct"
export REGISTRY="localhost:${REGISTRY_PORT}"
export REPOSITORY="test/nosign"
export TAG="latest"
export PASSWORD="test"
export USERNAME="test"
export SOURCE_DIGEST=""
export SIGN_SOURCE="false"
export VERIFY_SOURCE="false"
export NO_SIGN="true"
export PROMOTE="false"
export DEST_REGISTRY="" DEST_REPOSITORY="" DEST_TAG=""
export DEST_USERNAME="" DEST_PASSWORD=""
export TRUST_MODE="resign"
export SIGN_DESTINATION="false"
export VERIFY_DESTINATION="false"
export ALLOWED_IDENTITY_REGEX=""
export DEFAULT_ALLOWED_IDENTITY_REGEX="^https://github.com/test/.github/workflows/"
export COSIGN_CERTIFICATE_OIDC_ISSUER="https://token.actions.githubusercontent.com"
unset GRCLI_URL

empty_rc=0
empty_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || empty_rc=$?

if [[ $empty_rc -ne 0 ]]; then
  echo "  PASS: empty SOURCE_DIGEST correctly rejected (exit ${empty_rc})"
  ((PASS++))
else
  echo "  FAIL: empty SOURCE_DIGEST should have been rejected"
  ((FAIL++))
fi
assert_contains "error mentions digest" "No digest" "${empty_output}"

# ── Test 5: finalize.sh rejects malformed SOURCE_DIGEST ──────
echo ""
echo "=== Test 5: finalize.sh rejects malformed SOURCE_DIGEST ==="

GITHUB_OUTPUT="${TMPDIR_TEST}/bad-digest-output.txt"
> "${GITHUB_OUTPUT}"

export GITHUB_OUTPUT
export SOURCE_DIGEST="not-a-valid-digest"

bad_rc=0
bad_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || bad_rc=$?

if [[ $bad_rc -ne 0 ]]; then
  echo "  PASS: malformed SOURCE_DIGEST correctly rejected (exit ${bad_rc})"
  ((PASS++))
else
  echo "  FAIL: malformed SOURCE_DIGEST should have been rejected"
  ((FAIL++))
fi
assert_contains "error mentions digest format" "Expected sha256" "${bad_output}"

# ── Test 6: Hub mode finalize — discovery + source_ref fallbacks ─
echo ""
echo "=== Test 6: Hub mode finalize — registry discovery, source_ref fallbacks ==="

HUB_FIXTURE_DIR="${TMPDIR_TEST}/hub-www"
mkdir -p "${HUB_FIXTURE_DIR}/.well-known"
cat > "${HUB_FIXTURE_DIR}/.well-known/grc-store-configuration" << 'JSON'
{"registry_url": "http://localhost:5555"}
JSON

# Start the mock hub and wait until it answers; fail loudly if it cannot
# bind (e.g. the previous instance has not released the port yet).
start_mock_hub() {
  python3 -m http.server 8099 --directory "${HUB_FIXTURE_DIR}" >/dev/null 2>&1 &
  HTTP_SERVER_PID=$!
  local ready=false _
  for _ in {1..20}; do
    if curl -sf "http://localhost:8099/.well-known/grc-store-configuration" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 0.25
  done
  if [[ "${ready}" != "true" ]]; then
    echo "FAIL: mock hub discovery server did not start"
    kill "${HTTP_SERVER_PID}" 2>/dev/null || true
    exit 1
  fi
}

stop_mock_hub() {
  kill "${HTTP_SERVER_PID}" 2>/dev/null || true
  # Reap the process so the port is released before any restart.
  wait "${HTTP_SERVER_PID}" 2>/dev/null || true
}

start_mock_hub

GITHUB_OUTPUT="${TMPDIR_TEST}/hub-finalize-output.txt"
> "${GITHUB_OUTPUT}"

export GITHUB_OUTPUT
export PUBLISH_MODE="hub"
export GRCLI_URL="http://localhost:8099"
export REPOSITORY="test/hub-repo"
export TAG=""
export SOURCE_DIGEST="${REAL_DIGEST}"
export PROMOTE="false"

hub_fin_rc=0
hub_fin_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || hub_fin_rc=$?

assert_eq "hub finalize with discovery exits 0" "0" "$hub_fin_rc"
if [[ "${hub_fin_output}" == *"Hub registry discovery failed"* ]]; then
  echo "  FAIL: discovery unexpectedly failed with the mock hub up"
  ((FAIL++))
else
  echo "  PASS: no discovery warning with the mock hub up"
  ((PASS++))
fi

if [[ -f "${GITHUB_OUTPUT}" ]]; then
  sr=$(grep '^source_ref=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  assert_eq "source_ref includes discovered host" "localhost:5555/test/hub-repo@${REAL_DIGEST}" "${sr}"
else
  echo "  FAIL: GITHUB_OUTPUT not written"
  ((FAIL++))
fi

# Discovery failure: hub unreachable -> warning, host-less fallback.
GITHUB_OUTPUT="${TMPDIR_TEST}/hub-finalize-nodiscovery-output.txt"
> "${GITHUB_OUTPUT}"
export GITHUB_OUTPUT
export GRCLI_URL="http://localhost:1"

nodisc_rc=0
nodisc_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || nodisc_rc=$?

assert_eq "hub finalize without discovery exits 0" "0" "$nodisc_rc"
assert_contains "discovery failure warns" "Hub registry discovery failed" "${nodisc_output}"

if [[ -f "${GITHUB_OUTPUT}" ]]; then
  sr=$(grep '^source_ref=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  assert_eq "source_ref falls back host-less" "test/hub-repo@${REAL_DIGEST}" "${sr}"
else
  echo "  FAIL: GITHUB_OUTPUT not written"
  ((FAIL++))
fi

stop_mock_hub

# ── Test 6b: Hub mode finalize without repository — digest-only source_ref ─
echo ""
echo "=== Test 6b: Hub mode without repository (digest-only source_ref) ==="

# Restart the mock hub for this and the following hub tests.
start_mock_hub

GITHUB_OUTPUT="${TMPDIR_TEST}/hub-finalize-norepo-output.txt"
> "${GITHUB_OUTPUT}"
export GITHUB_OUTPUT
export PUBLISH_MODE="hub"
export GRCLI_URL="http://localhost:8099"
export REPOSITORY=""
export TAG=""
export PROMOTE="false"

norepo_rc=0
norepo_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || norepo_rc=$?

assert_eq "hub finalize without repository exits 0" "0" "$norepo_rc"
assert_contains "warns source_ref is digest-only" "source_ref is digest-only" "${norepo_output}"

if [[ -f "${GITHUB_OUTPUT}" ]]; then
  sr=$(grep '^source_ref=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  assert_eq "source_ref is digest-only" "@${REAL_DIGEST}" "${sr}"
else
  echo "  FAIL: GITHUB_OUTPUT not written"
  ((FAIL++))
fi

# ── Test 7: Hub-mode promotion branches ──────────────────────
echo ""
echo "=== Test 7: Hub-mode promotion (repository required, discovery-based copy) ==="

# Error branch: hub promotion without repository fails with the documented error.
GITHUB_OUTPUT="${TMPDIR_TEST}/hub-promo-error-output.txt"
> "${GITHUB_OUTPUT}"
export GITHUB_OUTPUT
export PROMOTE="true"
export DEST_REGISTRY="localhost:${REGISTRY_PORT}"
export DEST_REPOSITORY="test/promo-hub-dest"
export DEST_TAG="2.0.0"
export DEST_USERNAME="test"
export DEST_PASSWORD="test"
export TRUST_MODE="copy-only"
export SIGN_DESTINATION="false"
export VERIFY_DESTINATION="false"

hubpromo_err_rc=0
hubpromo_err_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || hubpromo_err_rc=$?

assert_eq "hub promotion without repository fails" "1" "$hubpromo_err_rc"
assert_contains "error names the repository requirement" "repository input is required for promotion in hub mode" "${hubpromo_err_output}"

# Success branch: with repository set, the discovered host builds the source
# reference and oras copy promotes across (same registry, different repo).
GITHUB_OUTPUT="${TMPDIR_TEST}/hub-promo-output.txt"
> "${GITHUB_OUTPUT}"
export GITHUB_OUTPUT
# test/nosign exists in the registry from Test 2; the mock hub's discovery
# points at the same registry, so the copy resolves.
export REPOSITORY="test/nosign"

hubpromo_rc=0
hubpromo_output=$(bash "${SCRIPT_DIR}/finalize.sh" 2>&1) || hubpromo_rc=$?

assert_eq "hub promotion with repository exits 0" "0" "$hubpromo_rc"

if [[ -f "${GITHUB_OUTPUT}" ]]; then
  sr=$(grep '^source_ref=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  dd=$(grep '^destination_digest=' "${GITHUB_OUTPUT}" | cut -d= -f2)
  assert_eq "source_ref uses the discovered host" "localhost:${REGISTRY_PORT}/test/nosign@${REAL_DIGEST}" "${sr}"
  assert_eq "destination_digest matches source" "${REAL_DIGEST}" "${dd}"
else
  echo "  FAIL: GITHUB_OUTPUT not written"
  ((FAIL++))
fi

stop_mock_hub

# ── Results ──────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
