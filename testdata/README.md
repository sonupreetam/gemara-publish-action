# Test fixtures

## `minimal-catalog.yaml`

Minimal **Gemara ControlCatalog** used by CI to exercise `grcli validate` and
`grcli publish --dry-run`. Contains a single family and control — enough to validate
that grcli can parse the YAML, validate it against the Gemara CUE spec, and run
assemble/pack without errors.

Used in `.github/workflows/ci.yml` as the dry-run target.
