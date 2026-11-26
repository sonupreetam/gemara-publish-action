---
layout: page
title: Use a single pinned composite action for publish orchestration
status: accepted
date: 2026-05-08
---

# Use a single pinned composite action for publish orchestration

- **ADR:** 0001
- **Status:** Accepted

> **Note:** One mechanism detail has changed since this decision: the action no
> longer builds a Go SDK (`cmd/grc/` was removed). It installs the prebuilt
> grcli binary and pushes via ORAS — see [ADR-0004](0004-wrap-grcli.md). The
> composite-action decision itself is unaffected.

## Context

CI callers need a standardized way to publish Gemara bundles to OCI registries. Three patterns were evaluated for orchestrating publish, sign, and promotion steps in GitHub Actions:

1. **Fully inline caller workflow** — each repository implements pack, push, sign, and promotion with shell commands plus CLIs (`oras`, `cosign`, `crane`) directly in its workflow.
2. **Chained org-infra reusable workflows** — separate `workflow_call` reusable workflows (staging publish, sign/verify, promote) maintained in an org infrastructure repository, each pinned at its own commit SHA.
3. **Single pinned composite action** — one `uses:` reference at a full SHA encapsulating publish, trust handling, and optional promotion.

## Action

Adopt Option 3: a single composite action in this repository.

Callers reference the action with one `uses:` line pinned to a commit SHA. The action encapsulates Go SDK build, publish, sign/verify, and optional cross-registry promotion.

## Consequences

**Positive:**
- Single pin for callers — one SHA to audit and update.
- Forks and demos work without mirroring multiple reusable workflows.
- Orchestration logic is co-located with the SDK-based publisher.

**Negative:**
- Composite actions only receive string inputs (no native booleans, objects, or arrays).
- Caller-side controls (concurrency groups, environment gates, branch protection) must be applied on the calling job, not inside the composite.

## Alternatives Considered

**Option 1 (inline workflow)** was rejected because it duplicates transport and trust logic across repositories, making it difficult to keep aligned with [go-gemara#60](https://github.com/gemaraproj/go-gemara/issues/60) and to audit under a single pinned contract.

**Option 2 (chained reusable workflows)** fits organizations that centralize promotion and attestation policy, but callers depend on multiple workflow pins and on the infrastructure repository's release cadence. Forks need a coherent mirror set. Option 2 remains valid where governance explicitly requires it, but Option 3 is the default for this project.
