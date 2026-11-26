---
layout: page
title: Replace embedded grc CLI with grcli dry-run and ORAS push
status: accepted
date: 2026-10-02
---

# Replace embedded grc CLI with grcli dry-run and ORAS push

- **ADR:** 0004
- **Status:** Accepted
- **Supersedes:** ADR-0002 (the SDK-owned-semantics principle remains; the mechanism changes)

## Context

The action shipped an embedded Go CLI (`cmd/grc/`) calling go-gemara's
`bundle.Assemble` + `bundle.Pack` + `oras.Copy`. The `grcli` project now
provides the same packing logic plus SLSA provenance, license validation,
and in-process signing.

All 10 known callers push to plain OCI registries (GHCR, Quay) using
`registry` + `username` + `password`. grcli cannot push to a plain
registry (it requires hub discovery via `--url`). A direct `grcli publish`
wrapper would break every caller.

## Action

Support two publish modes, selected by the presence of `grcli_url`:

### Direct mode (default — `grcli_url` empty)

1. `grcli publish --dry-run --no-sign -f <file> --license <license>` packs
   the bundle into a local OCI layout with SLSA provenance and license
   annotation.
2. `oras copy --from-oci-layout <layout>:<version> <registry>/<repo>:<tag>`
   pushes to the caller's registry with the caller's tag.
3. `cosign sign` handles source signing (same as the old action).

This preserves all existing inputs (`registry`, `tag`, `username`,
`password`, `sign_source`, `verify_source`) while replacing the embedded
Go CLI with grcli.

### Hub mode (`grcli_url` set)

1. `grcli publish -f <file> --license <license>` pushes through provided Gemara-compatible hub implementation:
   hub discovery, OIDC auth, in-process sigstore-go signing, hub sync.
2. No ORAS push, no cosign — grcli handles transport and signing internally.

Callers who want hub-managed publishing set `grcli_url` and
`permissions: id-token: write`; no registry credentials needed for the
source publish.

### Both modes

- Optional `grcli validate` before publish.
- Optional promotion to a second registry via ORAS copy with `trust_mode`.
- Structured outputs: source/destination refs, digests, verification state.

## Consequences

**Positive:**
- Backward compatible — existing callers add only `license` (new required input).
- Bundles gain SLSA provenance and license annotation (additive).
- No Go toolchain at runtime (grcli is a pre-built binary).
- No upstream grcli change needed for the core flow.
- SDK-owned-semantics boundary preserved — packing delegates to grcli/go-gemara.
- Hub mode gives callers in-process signing and hub indexing when they want it.

**Negative:**
- `verified_source` and `verified_destination` outputs emit `skipped`
  instead of `false` when verification is not attempted. Callers whose
  downstream steps branch on `== 'false'` to mean "not attempted" must
  update to check for `skipped`.
- In direct mode, source signing remains external cosign, not grcli's
  in-process sigstore-go. Callers who want in-process signing use hub mode.
- In direct mode, grcli records SLSA provenance at dry-run time (before
  ORAS pushes), so the provenance `repository` field reflects the local
  build context, not the push destination. The OCI manifest itself lives
  at the destination registry.
- `metadata.version` is required by grcli for packing. Callers whose
  artifacts lack it can set the action's `version` input, which passes
  `--version` to grcli.
- Two publish paths to maintain (direct + hub), though they share
  validation, promotion, and output logic.

### Refinements since drafting

These landed during implementation and review; they refine the decisions
above without reversing any of them.

- The grcli binary's cosign signature is verified at install
  (`verify: "true"`; cosign installs unconditionally so the check runs in
  every mode). The install action resolves the tag to a digest before
  verifying, so a retag cannot bypass the check.
- Direct-mode version precedence: the `version` input (explicit
  override), then the YAML's own `metadata.version`, then the `tag` input
  as a rescue for files that omit the version. The tag never stamps over
  a version the file already carries.
- The workspace boundary guard covers the `file` input as well as
  `working_directory`: an absolute path, `../`, or symlinked file that
  resolves outside the workspace is rejected.
- Hub-mode constraints surfaced by live testing: the hub's catalog
  requires the bundle's `metadata.author.id` to match the repository
  namespace (`slugify(author.id)/slugify(id)`; a mismatch is refused at
  sync with `catalog_coordinate_mismatch`); hub mode works only inside
  GitHub Actions, because grcli's CI auth uses the GitHub Actions OIDC
  token exclusively; and the grcli pin must match the hub's
  staging-cutover state — released v0.2.0 pushes the served repository
  while v0.3.0 and later push `staging/<ns>/<id>` first, so a 401 at the
  first blob push means pin and hub are on opposite sides of the cutover.

## Alternatives Considered

**Hub-only (no direct mode):** Removes `registry`/`tag`/`password`
inputs and requires grc.store. Breaks all 10 known callers. Rejected as
the sole path; now available as an opt-in mode.

**Add `--registry` flag to grcli:** Cleanest long-term solution but requires
an upstream change. Can be adopted later without breaking the ORAS-push path.

**Keep `cmd/grc/` alongside grcli:** Defeats the purpose of issue #29
(deduplicate bundling logic). Rejected.
