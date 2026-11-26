---
layout: page
title: Default to resign for cross-registry promotion trust
status: accepted
date: 2026-05-08
---

# Default to resign for cross-registry promotion trust

- **ADR:** 0003
- **Status:** Accepted

> **Correction:** the destination copy keeps the source digest — ORAS copy is
> content-addressed and `scripts/finalize.sh` enforces source/destination
> digest equality after promotion. The premise that "the destination copy
> gets a new digest" (and the digest-mismatch half of the `copy-referrers`
> rejection below) is wrong; the signature-does-not-transfer and
> registry-referrer-support rationales stand. The resign decision is
> unaffected.

## Context

When promoting a published bundle from a source registry (e.g. GHCR) to a destination registry (e.g. Quay, ECR), the cosign signature on the source digest is bound to the source registry's reference. The destination copy gets a new digest, and the original signature does not transfer automatically.

Three trust modes were considered for handling signatures across registries:

1. **`copy-only`** — copy the payload tag only; no signature handling.
2. **`copy-referrers`** — recursively copy the referrer graph (signatures, attestations) from source to destination, preserving the original signature chain where registry support allows.
3. **`resign`** — re-sign the destination digest with a fresh keyless cosign signature using the workflow's OIDC identity.

## Action

Default `trust_mode` to `resign`. The action re-signs the promoted artifact on the destination registry with the same GitHub Actions OIDC identity used to sign the source, then verifies the destination signature.

`copy-only` and `copy-referrers` remain available as optional compatibility modes for callers with different trust requirements.

## Consequences

**Positive:**
- Destination artifacts have a verifiable signature tied to the CI workflow identity, regardless of registry-specific referrer support.
- Verification on both source and destination uses the same identity policy (`cosign_certificate_oidc_issuer` + `allowed_identity_regex`).

**Negative:**
- Re-signing requires `id-token: write` permission in the caller workflow.
- The destination signature is a new signature, not a copy of the source signature — audit trails show two signing events.

## Alternatives Considered

**`copy-referrers`** was considered as the default but rejected because referrer support varies across registries and the copied signature references the source digest, which may not match the destination digest after copy. **`copy-only`** leaves the destination unsigned, which does not meet the trust requirements of most production workflows.
