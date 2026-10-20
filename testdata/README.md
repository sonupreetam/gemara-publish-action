# Test fixtures

## `minimal-catalog.yaml`

Minimal **Gemara ControlCatalog** used by CI to exercise `grcli validate` and
`grcli publish --dry-run`. Contains a single family and control — enough to
validate that grcli can parse the YAML, validate it against the Gemara CUE
spec, and run assemble/pack without errors.

Includes `metadata.version: "0.0.1"` which grcli uses as the OCI layout tag.

Used in `.github/workflows/ci.yml` and `.github/workflows/action-test.yml`.

## `minimal-catalog-no-version.yaml`

Same structure as `minimal-catalog.yaml` but **omits `metadata.version`**.
Used to test the `version` action input, which passes `--version` to grcli
to stamp the version from the CLI.

Used in `.github/workflows/action-test.yml` (version-flag job).

## `legacy-bundle/`

Static OCI image layout representing a bundle packed by the old `cmd/grc/`
CLI. Used by the `migration-check` CI job to verify `grcli` can still read
pre-migration bundles. See [`legacy-bundle/README.md`](legacy-bundle/README.md)
for format details, integrity verification, and media types.
