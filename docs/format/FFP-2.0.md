# FFP 2.0 — FacetForge document bundle, container revision 2

Status: **normative for format version 2.** Implemented by
`FacetForge/FileFormat/` and validated by
`FacetForgeTests/Phase38FormatEvolutionTests.swift` against
[`ffp-2.0.schema.json`](ffp-2.0.schema.json). [`FFP-1.0.md`](FFP-1.0.md)
remains normative for version-1 files, which this build still reads.

Version 2 changes **the container, not the document body**. The manifest keeps
its version-1 shape, `documentVersion` stays at the document model's schema
version, and no state hash, snapshot or thumbnail moves because of the upgrade.
Two reader rules that version 1 assumed become rules version 2 verifies.

## 1. What version 2 requires

1. **Complete checksum coverage.** Every owned file the bundle contains must be
   listed in `checksums.json`: `manifest.json` always, `preview.png` when it
   exists, and every buffer named by `geometry.buffers[].path`. Version 1
   verified the entries a file happened to list, so a bundle whose
   `checksums.json` omitted `manifest.json` loaded its document body without
   ever checking it.
2. **A resolvable geometry table.** Every `geometry.nodes[].nodeID` must name a
   node in `document.rootNodes` (recursively, through `children`), and each node
   may be referenced at most once. Version 1 attached whatever references it
   could resolve and silently dropped the rest, so one damaged entry could make
   a solid disappear without an error.

A violation is reported, never repaired silently:

| Condition | Error | Last-good recovery |
| --- | --- | --- |
| An owned file is absent from `checksums.json` | `unlistedEntry(path)` | yes |
| A reference names no node | `danglingGeometryReference(id)` | yes |
| Two references name one node | `malformedManifest(...)` | yes |
| `formatVersion` above this build | `unsupportedFormatVersion(n)` | no |

Recovery is allowed for the first three because they mean the bundle on disk is
inconsistent, which is exactly what the hidden previous save exists for. A
newer `formatVersion` never falls back: a file this build cannot fully verify
must not be replaced by an older one.

## 2. Reading a version-1 file

A version-1 bundle is read under version-1 rules and reports
`FFPMigrationReport(from: 1, to: 2, steps:)`, whose `headline` the shell shows
in its status line ("Upgraded from format 1 to 2"). The report names every step
the ladder applied so the reason for the change is legible rather than implied.

The version-1 reading rules are deliberately unchanged: a file this build
accepted before is accepted now with the same document content. Tightening a
read of an old file would turn a format revision into a compatibility break.

## 3. Writing

Every save writes `formatVersion: 2`, whichever version the file was read at.
The writer already listed every file it wrote, so a bundle written by this
build satisfies rule 1 by construction.

Version 1 is never written. `FFPFormatMigration.writingVersion1Copy(of:to:)` is
the only producer, it exists for the migration tests and the launch fixture, and
no shipping path calls it.

## 4. Why this needed a version bump

Rule 2 of FFP 1.0 says a change that removes or *reinterprets* an existing field
bumps `formatVersion`. Version 2 reinterprets `formatVersion` itself: a
version-2 bundle promises coverage that a version-1 reader cannot check, and a
version-1 reader that ignored the promise would silently drop the guarantee the
file was written with. Refusing a newer version, as rule 1 already required, is
the honest behaviour.

## 5. Compatibility notes

- A version-2 file cannot be opened by a build that predates this revision; that
  build reports `unsupportedFormatVersion(2)` and leaves the file untouched.
- Unknown object members and unknown bundle files are preserved exactly as FFP
  1.0 promises, including across the upgrade save.
- A legacy single-file `.facetforge.json` document still loads, is still not
  rewritten by a read, and is written as a version-2 bundle by the next save.
- `formatVersion` below `1` is `malformedManifest("formatVersion 0 is not a
  known revision")`, not a silent version-1 read.

## 6. Evidence

`Phase38FormatEvolutionTests` proves: the current manifest validates against the
2.0 schema and fails the frozen 1.0 schema; a version-1 bundle opens with an
identical document member, document model version and state hash, and reports
its migration; saving it writes version 2 with coverage while preserving an
unknown manifest member and an unknown bundle file; the uncovered-manifest hole
is demonstrated as accepted under version 1 and refused as `unlistedEntry`
under version 2; a dangling reference is refused and the same bytes read as
version 1 when declared as such; a future version never falls back; and a
10 000-case deterministic mutation corpus produces no crash, no unexplained
refusal and no silent loss of a document's nodes, materials or ordering.
