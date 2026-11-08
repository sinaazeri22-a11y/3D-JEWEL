#!/usr/bin/env bash
# Validates docs/MASTER-PLAN.md against its own structural invariants.
# Exit 0 = all invariants hold. Exit 1 = at least one violation (all printed).
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  if command -v python3 >/dev/null 2>&1; then PY=python3; else PY=python; fi
fi

"$PY" - "$@" <<'PY'
import os
import re
import sys
from pathlib import Path

root = Path.cwd()
plan_path = Path(os.environ.get("PLAN_PATH", "docs/MASTER-PLAN.md"))
errors = []
warnings = []

REQUIRED = [
    ".github/workflows/ios.yml",
    "scripts/ci-local.sh",
    "scripts/check-plan.sh",
    "scripts/check-workflow.sh",
    "scripts/check-evidence.sh",
    "docs/evidence/README.md",
    "docs/evidence/schema.json",
    "docs/evidence/link-status.json",
    "docs/evidence/link-status.md",
    "docs/evidence/link-status.schema.json",
    "scripts/check-links.py",
    "docs/MASTER-PLAN.md",
    "docs/PROGRESS.md",
    "docs/branding.md",
    "docs/precision.md",
    "docs/legal/provenance.md",
    "docs/adr/README.md",
    "docs/research/README.md",
    "docs/research/00-findings-and-constraints.md",
    "docs/research/a-matrixgold-product.md",
    "docs/research/b-matrixgold-ux.md",
    "docs/research/c-jeweler-domain.md",
    "docs/research/d-cad-kernel.md",
    "docs/research/e-ipados-stack-legal.md",
    "docs/research/f-engineering-delivery.md",
    "docs/research/g-rendering-materials.md",
    "docs/research/h-production-interchange.md",
    "docs/research/i-competitive-kernels.md",
    "docs/PLAN-RECONCILIATION.md",
]

if not plan_path.exists():
    print(f"FAIL: {plan_path} does not exist")
    sys.exit(1)

text = plan_path.read_text(encoding="utf-8")

if "## 3. Phases 1–200" not in text or "## 4. Feature traceability" not in text:
    print("FAIL: plan section 3/4 markers are missing")
    sys.exit(1)

section = text.split("## 3. Phases 1–200", 1)[1].split("## 4. Feature traceability", 1)[0]
lines = section.splitlines()

arc_re = re.compile(r"^### Arc (\d+) — .*\(phases (\d+)–(\d+)\)$")
row_re = re.compile(r"^\| (\d+) \|")

arcs = []
cur = None
for line in lines:
    m = arc_re.match(line.strip())
    if m:
        cur = {"arc": int(m.group(1)), "lo": int(m.group(2)), "hi": int(m.group(3)), "rows": []}
        arcs.append(cur)
        continue
    if row_re.match(line.strip()):
        if cur is None:
            errors.append("phase row appears before the first arc heading")
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        cur["rows"].append(cells)

if not arcs:
    errors.append("no arc headings matched '### Arc N — ... (phases A–B)'")

rows = [c for a in arcs for c in a["rows"]]

# Arc coverage must be continuous from 1 to 200 and row counts must match ranges.
expected = 1
for a in arcs:
    if a["lo"] != expected:
        errors.append(f"arc {a['arc']} starts at {a['lo']}, expected {expected}")
    count = a["hi"] - a["lo"] + 1
    if len(a["rows"]) != count:
        errors.append(f"arc {a['arc']} declares {count} phases but has {len(a['rows'])} rows")
    expected = a["hi"] + 1
if arcs and arcs[-1]["hi"] != 200:
    errors.append(f"last arc ends at {arcs[-1]['hi']}, expected 200")
if len(rows) != 200:
    errors.append(f"expected exactly 200 phase rows, found {len(rows)}")

if len(rows) != 200:
    for e in errors:
        print("FAIL:", e)
    sys.exit(1)

VALID_AXES = {"spec", "design", "correctness", "concision"}
seen = set()
for idx, c in enumerate(rows):
    expected_n = idx + 1
    if len(c) != 6:
        errors.append(f"row {idx + 1}: expected 6 cells, found {len(c)}")
        continue
    try:
        n = int(c[0])
    except ValueError:
        errors.append(f"row {idx + 1}: phase number is not an integer: {c[0]!r}")
        continue
    if n != expected_n:
        errors.append(f"row {idx + 1}: phase number {n} is not continuous (expected {expected_n})")
    if n in seen:
        errors.append(f"phase {n}: duplicate number")
    seen.add(n)

    goal, deliv, accept, deps, axis = c[1], c[2], c[3], c[4], c[5]
    if not goal:
        errors.append(f"phase {n}: empty goal")
    if not deliv:
        errors.append(f"phase {n}: empty deliverables")
    if not axis:
        errors.append(f"phase {n}: empty axis")
    elif axis not in VALID_AXES:
        errors.append(f"phase {n}: axis {axis!r} is not one of {sorted(VALID_AXES)}")

    if not accept.startswith("CI: "):
        errors.append(f"phase {n}: acceptance must start with 'CI: ' so every phase has a runner-executable check")
    elif len(accept) < 30:
        errors.append(f"phase {n}: acceptance is too short to be meaningful")
    for phrase in ("TBD", "todo", "placeholder", "n/a", "plausibl", "acceptabl", "judged", "review note", "feels", "reasonabl"):
        if phrase in accept.lower():
            errors.append(f"phase {n}: acceptance contains non-checkable phrase {phrase!r}")

    dep_text = deps.strip()
    if not dep_text:
        errors.append(f"phase {n}: no dependencies declared")
        continue
    deps_list = []
    for part in re.split(r"[,\s]+", dep_text):
        if not part:
            continue
        if not re.fullmatch(r"\d+", part):
            errors.append(f"phase {n}: dependency {part!r} is not a phase number")
            continue
        deps_list.append(int(part))
    if not deps_list:
        errors.append(f"phase {n}: dependency cell has no numbers")

    for d in deps_list:
        if d == 0:
            if n != 1:
                errors.append(f"phase {n}: only phase 1 may depend on the phase-0 gate")
            continue
        if d < 1 or d > 200:
            errors.append(f"phase {n}: dependency {d} is outside 1..200")
        elif d == n:
            errors.append(f"phase {n}: depends on itself")
        elif d > n:
            errors.append(f"phase {n}: forward dependency on later phase {d}")
        elif d not in seen and d != 0:
            errors.append(f"phase {n}: dependency {d} does not exist")

for rel in REQUIRED:
    if not (root / rel).exists():
        errors.append(f"Phase 0 deliverable missing: {rel}")

# The workflow must exist and be structurally valid before any phase can be gated.
workflow = root / ".github/workflows/ios.yml"
if workflow.exists():
    wf = workflow.read_text(encoding="utf-8")
    for needle in ("pull_request:", "workflow_dispatch:", "macos-", "xcodebuild", "CODE_SIGNING_ALLOWED=NO", "timeout-minutes:"):
        if needle not in wf:
            errors.append(f"workflow is missing required token: {needle}")

if errors:
    print(f"plan check: {len(errors)} violation(s)")
    for e in errors:
        print("FAIL:", e)
    sys.exit(1)

by_axis = {}
for c in rows:
    by_axis[c[5]] = by_axis.get(c[5], 0) + 1
print(f"plan check: PASS — 200 phases, {len(arcs)} arcs, axis mix {by_axis}")
print(f"plan check: Phase 0 artefacts present ({len(REQUIRED)} checked)")
PY
