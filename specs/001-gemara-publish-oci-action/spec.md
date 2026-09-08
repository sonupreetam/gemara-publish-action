# Feature Specification: Gemara publish OCI composite GitHub Action

## Document overview

This specification describes the **composite** GitHub Action shipped from this repository
(`action.yml`): validate a root Gemara YAML, publish it as a signed OCI bundle via grcli,
and optionally promote to a second registry with explicit trust modes.

**Key metadata**

- **Action definition:** `action.yml` (composite)
- **Related design:** [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md), [docs/adr/](../../docs/adr/)

**Scope boundary:** This repository is a **thin wrapper** around
[grcli](https://github.com/gemaraproj/grcli). It does not assemble Gemara layer manifests,
construct OCI artifacts, or handle signing directly — grcli owns all of that.

## Background and motivation

CI callers need a **small, auditable** Action that:

1. Accepts a root Gemara artifact YAML (Policy, Catalog, or Guidance) and publishes it as a
   signed OCI bundle via grcli.
2. Authenticates to the hub using the workflow's OIDC token (trusted publishing), without
   requiring stored secrets.
3. Signs the artifact keyless and in-process via sigstore-go (handled by grcli).
4. Optionally promotes the bundle to a second registry with configurable trust modes.
5. Emits stable outputs for source/destination refs, digests, and verification state for
   downstream release jobs.

## Core user scenarios

### Priority 1: Full publish orchestration for callers

A maintainer calls the action once with the file path and license; the action installs grcli,
optionally validates the artifact, publishes it (assemble + pack + sign + push), and returns
digest outputs.

**Test coverage:** `.github/workflows/ci.yml` installs grcli, runs a dry-run validate and
publish against `testdata/minimal-catalog.yaml`.

### Priority 2: Destination trust behavior

Callers can choose trust mode for cross-registry promotion:

- `copy-only`
- `copy-referrers`
- `resign` (default)

and verify destination trust with the same workflow identity constraints.

## Edge cases addressed

- **Missing or invalid root YAML:** `grcli validate` fails before publish.
- **Missing license:** Fail with a clear error (grcli requires `--license`).
- **Digest resolution:** Use `oras resolve` on destination references and fail fast if unavailable.
- **Dry-run mode:** `grcli publish --dry-run` writes OCI layout locally without pushing.

## Functional requirements summary

The Action must:

1. **Install grcli** from its GHCR release artifact using ORAS.
2. **Install ORAS** using the `oras_version` input for grcli install and promotion copy.
3. **Validate:** Optionally run `grcli validate` against the Gemara CUE spec.
4. **Publish:** Run `grcli publish` with the caller's `file` and `license`.
   grcli handles assembly, packing, signing (in-process keyless), and hub notification.
5. **Optional promotion:** Copy source to destination registry with selected trust mode and
   destination sign/verify via cosign.
6. **Output contract:** Append source/destination refs, digests, and verification booleans to
   `GITHUB_OUTPUT`.

## Scope boundaries

**In scope:** grcli install, ORAS install pin, grcli validate/publish invocation,
optional cross-registry promotion via ORAS + cosign, structured outputs.

**Out of scope:** Gemara YAML schema ownership, layer `mediaType` tables, Pack/Unpack
implementation details, signing implementation (these live in grcli / go-gemara).

## Formal requirements (SHALL / scenarios)

### Requirement: Pinned grcli binary install

The Action SHALL install the grcli binary for the runner platform using ORAS and the
`grcli_version` input as the version selector, and SHALL place the `grcli` binary on
`PATH` for subsequent steps.

#### Scenario: Default version is used when input omitted

- **WHEN** the workflow invokes the Action without setting `grcli_version`
- **THEN** the Action SHALL install the default grcli version documented in `action.yml`

#### Scenario: Caller pins a specific grcli version

- **WHEN** the workflow sets `grcli_version` to a supported release (e.g. `v0.1.0`)
- **THEN** the Action SHALL install grcli from the corresponding GHCR artifact

### Requirement: Hub authentication via OIDC

The Action SHALL authenticate to the hub using the workflow's GitHub OIDC token.
The caller workflow must set `permissions: id-token: write`.

#### Scenario: Publish with OIDC auth

- **WHEN** the caller job has `permissions: id-token: write`
- **THEN** `grcli publish` SHALL authenticate via the OIDC token and succeed
  when the repository has a trusted-publisher binding on the hub

### Requirement: License is required

The Action SHALL require a `license` input (SPDX expression) and SHALL fail before
publish if it is missing.

#### Scenario: Missing license

- **WHEN** `license` is empty
- **THEN** the Action SHALL fail with an error indicating `license` is required

### Requirement: Publish via grcli

The Action SHALL invoke `grcli publish` with the caller's `file` and `license` inputs.
grcli handles assembly, packing, signing, and push internally.

#### Scenario: Successful publish

- **WHEN** the root Gemara YAML is valid and hub auth succeeds
- **THEN** grcli SHALL publish the bundle and the action SHALL emit a digest output

#### Scenario: Validation failure

- **WHEN** `validate` is `"true"` and `grcli validate` fails
- **THEN** the Action SHALL fail before attempting publish

### Requirement: Source and destination output contract

After a successful publish, the Action SHALL write source digest outputs. If promotion
is enabled, it SHALL write destination digest/reference outputs and verification status.

#### Scenario: Outputs available to downstream steps

- **WHEN** publish completes successfully
- **THEN** `digest` and `source_digest` SHALL be non-empty outputs

### Requirement: Destination trust mode

When `promote_to_destination` is enabled, the Action SHALL honor `trust_mode`
(`copy-only`, `copy-referrers`, `resign`) and SHALL fail for unsupported values.

## Success metrics

- **CI green:** grcli installs, validate and dry-run publish succeed against
  `testdata/minimal-catalog.yaml`.
- **Consumers** can pin `grcli_version` and rely on stable `with:` / `outputs.digest`
  semantics documented in [README.md](../../README.md).
