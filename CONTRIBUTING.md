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

The action is a composite action defined in [`action.yml`](action.yml). It calls `grc`, a small Go program in [`cmd/grc/`](cmd/grc/) that wraps the [go-gemara](https://github.com/gemaraproj/go-gemara) bundle SDK and ORAS. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the [ADRs](docs/adr/) for design context.

### Prerequisites

- Go (version in [`cmd/grc/go.mod`](cmd/grc/go.mod))
- [cosign](https://github.com/sigstore/cosign) and [ORAS](https://oras.land/) if you test signing or promotion locally

### Build

```bash
go build -C cmd/grc -o grc .
```

### Validate locally

CI builds `grc` and runs a validate, assemble, and pack dry run against [`testdata/minimal-catalog.yaml`](testdata/minimal-catalog.yaml). The push step fails because no registry is running, which is expected. To run the same check:

```bash
go build -C cmd/grc -o "$PWD/grc" .
cd testdata
GEMARA_REGISTRY_PASSWORD=dummy ../grc \
  -registry=localhost:5000 \
  -repository=ci/test \
  -tag=ci \
  -file=minimal-catalog.yaml \
  -username=ci \
  -validate=true
```

Output lines starting with `validate:`, `assemble:`, or `pack:` mean that stage failed.

## Pull Request Guidelines

PRs must meet the following criteria:

- **Clear title** following [Conventional Commits](https://www.conventionalcommits.org/) (for example `feat:`, `fix:`, `docs:`, `chore:`)
- **All CI checks pass**, including the build, dry run, and CodeQL
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
