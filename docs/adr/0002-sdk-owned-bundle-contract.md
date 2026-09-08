---
layout: page
title: Delegate all bundle semantics to go-gemara SDK
---

- **ADR:** 0002
- **Status:** Superseded by ADR-0004

> **Note:** This ADR's mechanism (embedded `cmd/grc/` CLI) has been replaced by
> grcli. See [ADR-0004](0004-wrap-grcli.md). The principle of SDK-owned bundle
> semantics remains — grcli is now the sole consumer of the go-gemara SDK.

## Context

The [go-gemara SDK](https://github.com/gemaraproj/go-gemara) defines bundle semantics: manifest shape, `artifactType`, layer `mediaType`s, and the `Assemble` / `Pack` / `Unpack` lifecycle ([go-gemara#60](https://github.com/gemaraproj/go-gemara/issues/60)).

This action needs to publish bundles to OCI registries. The question is whether the action should own any bundle-level logic (layer descriptors, media types, manifest construction) or treat the SDK as the sole source of truth.

## Action

The action treats go-gemara as the source of truth for all bundle semantics. The `grc` CLI (`cmd/grc/`) calls `bundle.Assemble`, `bundle.Pack`, and `oras.Copy` from the SDK. It does not construct layer descriptors, define media types, or manipulate manifest contents.

The action owns only transport and CI concerns: registry authentication, cosign sign/verify orchestration, optional cross-registry promotion, and structured `GITHUB_OUTPUT` values.

## Consequences

**Positive:**
- Bundle format evolves in one place (go-gemara) without requiring synchronized changes in this action.
- No risk of the action and SDK producing incompatible manifests.
- Clear audit boundary: this repository owns transport, go-gemara owns semantics.

**Negative:**
- Breaking changes in go-gemara's `bundle` API require updating `cmd/grc/`.
- The action cannot override or extend bundle format without an upstream SDK change.

## Alternatives Considered

Implementing bundle assembly directly in the action (handcrafting OCI layer descriptors and manifests) would give the action full control but would duplicate SDK logic and risk format drift between the action and SDK consumers (e.g. `complyctl`).
