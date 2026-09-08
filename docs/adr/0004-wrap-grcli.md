---
layout: page
title: Replace embedded grc CLI with grcli wrapper
---

- **ADR:** 0004
- **Status:** Accepted
- **Supersedes:** ADR-0002 (SDK-owned bundle contract — the principle remains, but the mechanism changes from an embedded CLI to a pre-built external CLI)

## Context

The action originally shipped an embedded Go CLI (`cmd/grc/`) that called go-gemara's `bundle.Assemble`, `bundle.Pack`, and `oras.Copy` directly. This worked but duplicated bundling, signing, and validation logic that the [grcli](https://github.com/gemaraproj/grcli) project now provides as a standalone, multi-platform binary distributed via GHCR.

`grcli` adds capabilities the embedded `grc` CLI did not have:

- **In-process keyless signing** via sigstore-go (no external cosign dependency for the publish path).
- **SLSA-shaped provenance** attached as an OCI referrer.
- **Hub integration** (trusted publishing, signer identity recording, version indexing).
- **validate / verify / unpack / cat** commands for a complete artifact lifecycle.
- **Pre-built multi-platform binaries** (no Go toolchain needed at runtime).

Maintaining both `grc` and `grcli` creates unnecessary divergence and doubles the surface area for bundle-format changes.

## Action

Replace the embedded `cmd/grc/` CLI with a wrapper that installs `grcli` from its GHCR release artifact and invokes `grcli validate`, `grcli publish`, and related commands. The action no longer builds Go code or ships a go.mod.

Key changes:

1. **Removed:** `cmd/grc/` (Go source, go.mod, go.sum).
2. **Removed:** `actions/setup-go` and `cue-lang/setup-cue` steps (grcli handles validation internally via `cue vet`; Go is not needed).
3. **Added:** `oras pull ghcr.io/gemaraproj/grcli:<version>` install step.
4. **Added:** `grcli_version` input (pin the binary version).
5. **Added:** `license` input (required by `grcli publish --license`).
6. **Changed:** Source signing is now handled in-process by grcli (sigstore-go), not by a separate cosign step. Cosign is only installed when cross-registry promotion is enabled.
7. **Changed:** Validation uses `grcli validate` instead of a manual CUE setup + `cue vet` invocation.

## Consequences

**Positive:**
- Single source of truth for bundle assembly, packing, signing, and validation — `grcli`.
- No Go toolchain required at action runtime; faster CI execution.
- Signing happens in-process (no cosign version skew for the publish path).
- Hub-aware publishing with trusted CI authentication (OIDC, no stored secrets).
- Simpler action surface: fewer steps, fewer inputs (registry auth for source is hub-managed).

**Negative:**
- The action depends on a pre-built binary from `ghcr.io/gemaraproj/grcli`.
- `grcli publish` requires `--license` (SPDX expression) — callers must supply this.
- Cross-registry promotion still requires ORAS + cosign, since grcli does not handle promotion to arbitrary registries.
- Callers using the old `registry` / `username` / `password` source auth pattern must migrate to hub-based trusted publishing.

## Alternatives Considered

**Keep the embedded `grc` CLI and add grcli features incrementally** — rejected because it would duplicate the growing grcli feature set (provenance, hub sync, in-process signing) and violate the SDK-owned-semantics principle from ADR-0002.

**Shell out to grcli from Go** — rejected as unnecessary indirection; the action's bash steps can call grcli directly.
