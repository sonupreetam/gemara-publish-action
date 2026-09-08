# Architecture: grcli wrapper for publish orchestration

This repository is a **thin GitHub Actions wrapper** around
**[grcli](https://github.com/gemaraproj/grcli)**, the standalone CLI for the
GRC artifact registry. All bundle semantics — assembly, packing, signing,
validation, and hub interaction — are owned by grcli and its upstream SDK
**[go-gemara](https://github.com/gemaraproj/go-gemara)**.

## How it works

1. **Install grcli** — the action pulls a pinned, pre-built `grcli` binary from
   `ghcr.io/gemaraproj/grcli:<version>` via ORAS. No Go toolchain is needed.
2. **Validate** (optional) — `grcli validate -f <file>` runs `cue vet` against the
   authoritative Gemara CUE schemas.
3. **Publish** — `grcli publish -f <file> --license <spdx>` assembles dependencies,
   packs the bundle into a signed OCI artifact with SLSA-shaped provenance, pushes
   to the hub-managed registry, and notifies the hub. Signing is keyless and
   in-process (sigstore-go) using the GitHub Actions OIDC token.
4. **Promote** (optional) — ORAS copies the published artifact to a second registry.
   Cosign re-signs / verifies the destination digest when `trust_mode=resign`.

## Intended split

| Concern | Owner | Notes |
|---------|-------|-------|
| Bundle assembly, packing, manifest shape | go-gemara SDK (via grcli) | `bundle.Assemble` + `bundle.Pack` |
| Signing (keyless CI) | grcli (sigstore-go in-process) | No external cosign for publish |
| Validation | grcli (`grcli validate`) | Wraps `cue vet` against Gemara spec |
| Hub interaction | grcli | Trusted publishing, version indexing, identity recording |
| Registry auth (source) | grcli via OIDC | `permissions: id-token: write` in caller |
| Cross-registry promotion | This action (ORAS + cosign) | grcli does not handle promotion |
| Destination trust | This action (cosign sign/verify) | resign / copy-only / copy-referrers |
| CI orchestration | This action (`action.yml`) | Input validation, step sequencing, outputs |

## Publish and promotion model

| Phase | What happens |
|-------|-------------|
| **1 — Validate** | `grcli validate` runs CUE schema checks (optional). |
| **2 — Publish** | `grcli publish` assembles, packs, signs (in-process), pushes, notifies hub. |
| **3 — Promote** | ORAS copies artifact to a destination registry (optional). |
| **4 — Destination trust** | Cosign resign/verify on destination digest (optional). |

## Why grcli instead of an embedded CLI

Previously, this repository shipped `cmd/grc/`, a Go CLI that called go-gemara's
SDK directly. With the introduction of grcli as a standalone project, maintaining
both tools created unnecessary duplication. grcli adds in-process signing, hub
integration, provenance, and a complete artifact lifecycle (validate, publish,
verify, unpack, cat) that the embedded CLI did not have.

See [ADR-0004](adr/0004-wrap-grcli.md) for the full decision record.

## Design decisions

Architectural decisions are recorded in [`docs/adr/`](adr/):

- [ADR-0001: Composite action pattern](adr/0001-composite-action-pattern.md)
- [ADR-0002: SDK-owned bundle contract](adr/0002-sdk-owned-bundle-contract.md)
- [ADR-0003: Cross-registry trust model](adr/0003-cross-registry-trust-model.md)
- [ADR-0004: Replace embedded grc CLI with grcli wrapper](adr/0004-wrap-grcli.md)

## Compliance

- **Do not** add Gemara YAML schema ownership or layer `mediaType` tables here — use **grcli** / **go-gemara**.
- **Do** pin `grcli_version` and `oras_version` and document migration.
