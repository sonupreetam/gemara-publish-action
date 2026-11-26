# Legacy Bundle Fixture

A static OCI image layout representing a bundle packed by the old
`cmd/grc/` CLI, before the project migrated to `grcli`. Used by CI to
verify that `grcli` can still read pre-migration bundles.

## How it was created

Hand-crafted OCI layout. Each blob was written with its SHA-256 digest
as the filename, and every descriptor digest was computed from the actual
blob content.

The layer content is a copy of `testdata/minimal-catalog.yaml`.

## Format constraints

This fixture intentionally omits features added by `grcli` / `grc-store-clientkit`:

- **No `org.opencontainers.image.licenses` annotation** on the manifest.
- **No `org.gemara.artifact.type` annotation** on the layer (old CLI didn't set `File.Type`).
- **No manifest-level annotations** (`org.opencontainers.image.created`, etc.).
- **No provenance referrer** (no SLSA provenance layer or subject field).
- **No signature referrer** (no cosign signature layer or subject field).
- **Minimal config blob** (20 bytes: `{"version":"0.0.1"}` vs ~1179 bytes in current format).

The fixture DOES include annotations that `go-gemara`'s `bundle.Pack` has
always set (since at least v0.4.0):

- `org.opencontainers.image.title: minimal-catalog.yaml` on the layer.
- `org.gemara.artifact.role: artifact` on the layer.

These are the defining characteristics of a "legacy" bundle and are what
the migration-check CI job asserts against.

## Media types

| Descriptor | Media type |
|---|---|
| Manifest | `application/vnd.oci.image.manifest.v1+json` |
| Artifact type | `application/vnd.gemara.bundle.v1` |
| Config | `application/vnd.gemara.manifest.v1+json` |
| Layer | `application/vnd.gemara.artifact.v1+yaml` |

## Integrity

Manifest digest: `sha256:c2516a7c4d94e608fe85e1f84579527a3a89630d4685e82480315ec547890d82`

Verify the layout is internally consistent:

```bash
python3 -c "
import json, hashlib, os

base = 'testdata/legacy-bundle'
blobs = os.path.join(base, 'blobs', 'sha256')

# Check index -> manifest
index = json.load(open(os.path.join(base, 'index.json')))
desc = index['manifests'][0]
manifest_path = os.path.join(blobs, desc['digest'].removeprefix('sha256:'))
manifest_bytes = open(manifest_path, 'rb').read()
assert hashlib.sha256(manifest_bytes).hexdigest() == desc['digest'].removeprefix('sha256:')
assert len(manifest_bytes) == desc['size']

# Check manifest -> config and layer
manifest = json.loads(manifest_bytes)
for blob_desc in [manifest['config']] + manifest['layers']:
    hex_digest = blob_desc['digest'].removeprefix('sha256:')
    blob_bytes = open(os.path.join(blobs, hex_digest), 'rb').read()
    assert hashlib.sha256(blob_bytes).hexdigest() == hex_digest
    assert len(blob_bytes) == blob_desc['size']

print('All digests and sizes verified.')
"
```

## Layout tag

The index tags the manifest as `0.0.1` via the
`org.opencontainers.image.ref.name` annotation.
