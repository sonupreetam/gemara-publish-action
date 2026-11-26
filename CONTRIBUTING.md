# Contributing to gemara-publish-action

Thanks for your interest in contributing! Bug reports, feature requests, and code changes are all welcome.

## Code of Conduct

This project follows the [OpenSSF Code of Conduct](https://openssf.org/community/code-of-conduct/).

## Getting Started

1. [Fork the repository](https://github.com/gemaraproj/gemara-publish-action/fork)
2. Clone your fork and create a branch
3. Make your changes
4. Open a pull request against `main`

## Development

The action is a composite action defined in [`action.yml`](action.yml). There is no embedded CLI: the action installs [grcli](https://github.com/gemaraproj/grcli) (SHA-pinned install action, cosign signature verified) and drives it through the shell scripts in [`scripts/`](scripts/) — `lib.sh` (shared helpers), `publish.sh` (validate/pack/push), and `finalize.sh` (sign/verify/promote). See the "Responsibility split" section of the [README](README.md) and the [ADRs](docs/adr/) — especially [ADR-0004](docs/adr/0004-wrap-grcli.md), which records the migration from the old embedded `grc` CLI — for design context.

### Prerequisites

- bash 4+, python3 (with PyYAML), curl
- [grcli](https://github.com/gemaraproj/grcli) for validation and dry-run packing
- [ORAS](https://oras.land/) and a container runtime (podman or docker) for the integration tests and local registry workflows
- [cosign](https://github.com/sigstore/cosign) if you test signing or promotion locally

### Test locally

Unit tests for the shell helpers (digest normalization, workspace boundary checks, YAML version detection) run anywhere:

```bash
bash scripts/test_lib.sh
```

Integration tests for `publish.sh` and `finalize.sh` (hub-mode digest extraction, finalize output states, hub registry-discovery fallbacks, traversal rejection) start a local `registry:2` container and need a container runtime plus `oras`:

```bash
bash scripts/test_integration.sh
```

To validate a fixture the way CI does, check out the Gemara spec and run grcli against it:

```bash
git clone --depth 1 https://github.com/gemaraproj/gemara /tmp/gemara-spec
grcli validate -f testdata/minimal-catalog.yaml --spec /tmp/gemara-spec
```

### CI

CI runs on every pull request against `main` (see [`.github/workflows/`](.github/workflows/)):

- `ci.yml` — validate (grcli + CUE against the Gemara spec), lib.sh unit tests, publish/finalize integration tests, legacy-bundle migration check
- `action-test.yml` — end-to-end runs of the composite action against a local registry: publish, version flag and precedence, tag rescue, promotion (resign, copy-only, and copy-referrers), input validation, schema-validation failure
- `signing-test.yml` — the default sign/verify posture (keyless cosign) against a local registry; runs on push (needs `id-token: write`, which fork PRs cannot receive)
- `codeql.yml` — CodeQL over the workflow files
- `grcli-canary.yml` — early-warning tests against unreleased grcli refs; runs on PRs touching `scripts/` or `testdata/` (hub-mode job is dispatch-only)

## Pull Request Guidelines

PRs must meet the following criteria:

- **Clear title** following [Conventional Commits](https://www.conventionalcommits.org/) (for example `feat:`, `fix:`, `docs:`, `chore:`)
- **All CI checks pass**, including unit, integration, and end-to-end tests
- **Actions pinned to a full commit SHA** with a version comment for any new or updated `uses:` reference
- **README updated** when you add or change inputs, outputs, or behavior

A member of [@gemaraproj/gemara-package-approvers](https://github.com/orgs/gemaraproj/teams/gemara-package-approvers) must approve each PR before merge.

## Reporting Bugs and Requesting Features

[Open an issue](https://github.com/gemaraproj/gemara-publish-action/issues/new) and include:

- **Bug reports:** the action version or commit SHA, the relevant workflow snippet (redact secrets), the failing step's log output, and what you expected to happen. A minimal Gemara YAML that reproduces the problem helps most.
- **Feature requests:** the use case and the behavior you would like.

For questions, join the OpenSSF Slack `#gemara` channel.

### Security Issues

**Do not report security vulnerabilities in public issues.** Report them privately through [GitHub Private Vulnerability Reporting](https://github.com/gemaraproj/gemara-publish-action/security/advisories/new). See the [security policy](https://github.com/gemaraproj/.github/blob/main/SECURITY.md) for details.

## Governance

This project is part of the [Gemara project](https://github.com/gemaraproj). See the org-level [governance](https://github.com/gemaraproj/.github/blob/main/GOVERNANCE.md) and [contributor ladder](https://github.com/gemaraproj/.github/blob/main/CONTRIBUTOR_LADDER.md) for roles and decision-making.

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
