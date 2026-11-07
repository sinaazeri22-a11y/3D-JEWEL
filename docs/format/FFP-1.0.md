# FFP 1.0 — FacetForge document bundle

Status: **normative for format version 1.** Implemented by
`FacetForge/FileFormat/` and validated by
`FacetForgeTests/Phase25FileFormatTests.swift` against
[`ffp-1.0.schema.json`](ffp-1.0.schema.json).

A `.ffp` document is a **directory bundle**. A bundle is used rather than a
single file because geometry is binary and grows without bound, because a
thumbnail should be replaceable without rewriting the model, and because an
unknown file written by a future minor version can be copied through a save.

## 1. Bundle layout

```
Chair.ffp/
  manifest.json                 required
  geometry/geometry-000.bin     zero or more buffers
  preview.png                   optional thumbnail, 256x192 px
  checksums.json                required
  ...                           any other entry is unknown-but-preserved
```

Every entry except `checksums.json` is listed in `checksums.json`. Entries the
writer does not own (everything except `manifest.json`, `checksums.json`,
`preview.png` and the `geometry/` directory) are copied byte-for-byte when an
existing bundle is rewritten.

## 2. Version fields and compatibility policy

Two integers version a bundle:

| Field | Meaning | Current |
| --- | --- | --- |
| `formatVersion` | Bundle layout and manifest shape | `1` |
| `documentVersion` | The `FFDocument` model (`schemaVersion`) | `1` |

The rules are normative for writers and readers:

1. **Readers accept `formatVersion` less than or equal to their own.** A higher
   integer is rejected with `unsupportedFormatVersion`, before any state is
   replaced. A newer bundle is never partially loaded into an older app.
2. **A change that removes or reinterprets an existing field bumps
   `formatVersion`.** Additive fields do not: they are introduced with the same
   `formatVersion` and readers that do not know them preserve them.
3. **Unknown object members are preserved on rewrite.** Preservation applies to
   the manifest top level, the `document` object, every node, material and
   layer object (matched by `id`), and every unknown file in the bundle.
4. **Deleted objects stay deleted.** Arrays merge only for elements whose `id`
   is present in the newly written document. A preserved element with no typed
   counterpart is dropped, so an undo that removed a node cannot be reversed by
   a stale merge.
5. **Values in known keys are always the writer's.** Preserved fields never
   shadow geometry, dates, versions, the document body or the thumbnail.
6. **Unknown array elements in known arrays are not preserved** unless they
   carry an `id` that the new document also contains. A future major version
   that adds new node types must bump `formatVersion`.
7. **A single-file legacy document is still readable.** Before Phase 25 the app
   wrote canonical JSON with a `.facetforge.json` suffix. The reader detects a
   regular file and decodes it; the next save writes a bundle. The old file is
   not deleted by the reader.

## 3. `manifest.json`

The manifest is UTF-8 JSON. Encoding uses sorted keys, so identical content
produces identical bytes. Its schema is the sibling JSON Schema file; the
required members are:

```json
{
  "format": "facetforge-document",
  "formatVersion": 1,
  "documentVersion": 1,
  "createdAt": "2026-11-07T10:00:00Z",
  "modifiedAt": "2026-11-07T10:04:00Z",
  "generator": { "name": "FacetForge", "format": "ffp" },
  "document": { "schemaVersion": 1, "...": "FFDocument, geometry removed" },
  "geometry": {
    "buffers": [
      { "path": "geometry/geometry-000.bin", "byteLength": 128, "sha256": "…64 lowercase hex…" }
    ],
    "nodes": [
      { "nodeID": "…uuid…", "buffer": 0, "offset": 0, "length": 128, "kind": "mesh" }
    ]
  }
}
```

`createdAt` survives a rewrite; `modifiedAt` is the save time. `document` is the
model's own canonical JSON with every node's `geometry` member removed —
geometry lives only in the buffers. `documentVersion` is repeated at the top
level so a reader can reject an unsupported document model before walking the
tree.

## 4. Geometry buffers

Each referenced block is self-describing and little-endian. The manifest records
the kind; the block repeats it as a magic so a misplaced offset fails loudly.
Counts are validated against the block length before any allocation.

**Mesh — `FFM1` (`0x314D4646`)**

```
u32 magic          0x314D4646
u32 positionCount
u32 triangleCount
    positionCount × { f64 x, f64 y, f64 z }
    triangleCount × { u32 a, u32 b, u32 c }
```

**Curve — `FFC1` (`0x31434646`)

```
u32 magic          0x31434646
u32 flags          bit 0 = closed; no other bit may be set
u32 segmentCount
    per segment:
      u32 kind     0 = Bézier, 1 = NURBS
      u32 pointCount
      u32 weightCount
      u32 knotCount
      u32 degree
      pointCount  × { f64 x, f64 y }
      weightCount × { f64 w }
      knotCount   × { f64 t }
```

Coordinates, weights and knots must be finite; a reader rejects a NaN or an
infinity rather than passing it to the kernel. A block with trailing bytes is
corrupt. A buffer is at most 4 MiB; a block larger than that gets its own
buffer. Offsets are byte offsets within their buffer and lengths are exact.

## 5. Checksums

`checksums.json` is canonical JSON:

```json
{
  "algorithm": "sha256",
  "files": [
    { "path": "geometry/geometry-000.bin", "byteLength": 128, "sha256": "…" },
    { "path": "manifest.json", "byteLength": 2048, "sha256": "…" }
  ]
}
```

Files are sorted by path. `checksums.json` does not list itself. A reader
verifies every listed entry's length and SHA-256 before parsing the manifest;
a missing entry is `missingEntry`, a length or digest mismatch is
`checksumMismatch`. Unlisted files are preserved but not trusted. Paths must be
relative, forward-slash separated, and may not contain `..`.

## 6. Thumbnail

`preview.png` is optional. When present it is a 256×192 PNG at scale 1 showing
an isometric wireframe of the document's geometry on the format's dark
background. It is a cache: a reader may ignore it, and a writer may omit it.
It is included in the checksum list when present.

## 7. Writing and reading

The writer builds a complete `.<name>.<uuid>.tmp` directory beside the
destination, writes buffers, manifest, thumbnail and preserved files, computes
checksums and swaps the directory in. Readers never mutate the bundle.

Errors are typed (`FFPFormatError`) so callers can distinguish an unsupported
future version, a malformed manifest, corrupt geometry, a missing entry, a
checksum mismatch and an unsafe path. Phase 26 adds the interrupted-write
recovery journal on top of this format; the format itself does not depend on it.
