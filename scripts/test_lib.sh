#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Unit tests for lib.sh functions.
# Run: bash scripts/test_lib.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

PASS=0
FAIL=0

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

assert_fail() {
  local label="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "  FAIL: ${label} — expected failure, got success"
    ((FAIL++))
  else
    echo "  PASS: ${label}"
    ((PASS++))
  fi
}

echo "=== normalize_oci_digest ==="

VALID_HEX="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

result=$(normalize_oci_digest "sha256:${VALID_HEX}") || true
assert_eq "valid sha256: prefix" "sha256:${VALID_HEX}" "$result"

result=$(normalize_oci_digest "${VALID_HEX}") || true
assert_eq "bare hex gets sha256: prefix" "sha256:${VALID_HEX}" "$result"

result=$(normalize_oci_digest "SHA256:ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789") || true
assert_eq "uppercase normalized" "sha256:${VALID_HEX}" "$result"

cr_input=$'sha256:'"${VALID_HEX}"$'\r\n'
result=$(normalize_oci_digest "$cr_input") || true
assert_eq "strips CR/LF" "sha256:${VALID_HEX}" "$result"

assert_fail "rejects short hex" normalize_oci_digest "sha256:abcdef"
assert_fail "rejects non-hex" normalize_oci_digest "sha256:zzzzzz0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
assert_fail "rejects empty" normalize_oci_digest ""

echo ""
echo "=== validate_working_directory ==="

# Set up a temp workspace to test traversal.
# Resolve with pwd -P so macOS /private prefix matches what the function sees.
TMPCONTAINER=$(mktemp -d)
TMPCONTAINER=$(cd "${TMPCONTAINER}" && pwd -P)
trap 'rm -rf "${TMPCONTAINER}"' EXIT
TMPWS="${TMPCONTAINER}/workspace"
mkdir -p "${TMPWS}/subdir"
mkdir "${TMPCONTAINER}/workspace-sibling"

# Valid: stays inside workspace
export GITHUB_WORKSPACE="${TMPWS}"
export INPUT_WORKING_DIRECTORY="subdir"
(validate_working_directory 2>/dev/null)
assert_eq "valid subdir accepted" "0" "$?"

# Valid: default "."
export INPUT_WORKING_DIRECTORY="."
(validate_working_directory 2>/dev/null)
assert_eq "default '.' accepted" "0" "$?"

# Invalid: traversal escapes workspace
export INPUT_WORKING_DIRECTORY="../../.."
if (validate_working_directory 2>/dev/null); then
  assert_eq "traversal rejected" "should have failed" "succeeded"
else
  assert_eq "traversal rejected" "rejected" "rejected"
fi

# Invalid: symlink escape
ln -sf /tmp "${TMPWS}/escape-link"
export INPUT_WORKING_DIRECTORY="escape-link"
if (validate_working_directory 2>/dev/null); then
  assert_eq "symlink escape rejected" "should have failed" "succeeded"
else
  assert_eq "symlink escape rejected" "rejected" "rejected"
fi

# A sibling can share every byte of the workspace prefix and still be outside.
export INPUT_WORKING_DIRECTORY="../workspace-sibling"
if (validate_working_directory 2>/dev/null); then
  assert_eq "same-prefix sibling traversal rejected" "should have failed" "succeeded"
else
  assert_eq "same-prefix sibling traversal rejected" "rejected" "rejected"
fi

ln -s "${TMPCONTAINER}/workspace-sibling" "${TMPWS}/prefix-escape-link"
export INPUT_WORKING_DIRECTORY="prefix-escape-link"
if (validate_working_directory 2>/dev/null); then
  assert_eq "symlink to same-prefix sibling rejected" "should have failed" "succeeded"
else
  assert_eq "symlink to same-prefix sibling rejected" "rejected" "rejected"
fi

# Resolving an in-workspace symlink preserves the same directory boundary.
ln -s "${TMPWS}/subdir" "${TMPWS}/inside-link"
export INPUT_WORKING_DIRECTORY="inside-link"
(validate_working_directory 2>/dev/null)
assert_eq "in-workspace symlink accepted" "0" "$?"

# Canonicalise the trusted root too, so spelling it through a symlink or a
# trailing separator cannot turn the same physical workspace into an escape.
ln -s "${TMPWS}" "${TMPCONTAINER}/workspace-link"
export GITHUB_WORKSPACE="${TMPCONTAINER}/workspace-link"
export INPUT_WORKING_DIRECTORY="."
(validate_working_directory 2>/dev/null)
assert_eq "symlinked workspace accepted" "0" "$?"

export GITHUB_WORKSPACE="${TMPWS}/"
(validate_working_directory 2>/dev/null)
assert_eq "workspace with trailing separator accepted" "0" "$?"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
