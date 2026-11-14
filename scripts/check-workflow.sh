#!/usr/bin/env bash
# Validates .github/workflows/ios.yml without requiring network access.
# actionlint is used when installed; otherwise Ruby's YAML parser plus structural
# assertions stand in. Exit 0 = valid, 1 = invalid.
set -euo pipefail
cd "$(dirname "$0")/.."

WORKFLOW="${1:-.github/workflows/ios.yml}"
fail=0
err() { echo "FAIL: $*"; fail=1; }

[ -f "$WORKFLOW" ] || { echo "FAIL: $WORKFLOW is missing"; exit 1; }

# 1. Parseable YAML.
if command -v ruby >/dev/null 2>&1; then
  if ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$WORKFLOW" >/dev/null 2>&1; then
    echo "yaml: parsed by ruby/psych"
  else
    err "$WORKFLOW is not parseable YAML"
  fi
else
  echo "yaml: ruby not available — structural checks only"
fi

# 2. actionlint when available (never installed silently).
if command -v actionlint >/dev/null 2>&1; then
  actionlint "$WORKFLOW" || err "actionlint reported problems"
else
  echo "actionlint: not installed — structural fallback used (documented in Phase 0)"
fi

# 3. Required structure.
for token in '^name:' '^on:' '^jobs:' 'pull_request:' 'workflow_dispatch:' 'permissions:' 'concurrency:'; do
  grep -Eq "$token" "$WORKFLOW" || err "missing required token: $token"
done

# The simulator job selects its image so a starved arm64 pool can be replaced
# by the Intel fallback at dispatch time without editing this file. The default
# must stay the arm64 label, because push and pull_request runs pass no input.
grep -Eq '^\s+runs-on:.*macos-[0-9]+' "$WORKFLOW" || err "no macos-N runner"
grep -Eq "^\s+runs-on: \\\$\\{\\{ inputs\.runner \\|\\| 'macos-26' \\}\\}" "$WORKFLOW" \
  || err "runner selector does not default to the arm64 label (macos-26)"
grep -Eq '^\s+timeout-minutes:' "$WORKFLOW" || err "no job timeout"
grep -Eq 'xcodebuild (build|test)' "$WORKFLOW" || err "no xcodebuild build/test step"
grep -Eq 'CODE_SIGNING_ALLOWED=NO' "$WORKFLOW" || err "simulator build is not signing-free"
grep -Eq 'actions/checkout@v[0-9]+' "$WORKFLOW" || err "checkout action is not pinned to a major version"
grep -Eq 'actions/upload-artifact@v[0-9]+' "$WORKFLOW" || err "artifact action is not pinned to a major version"

# No secrets may be referenced by the Phase 0 workflow.
if grep -Eq '\$\{\{\s*secrets\.' "$WORKFLOW"; then
  err "workflow references secrets; Phase 0 must run without any"
fi

# Every action reference must be pinned to a tag or SHA, never a branch.
while IFS= read -r line; do
  ref=$(printf '%s' "$line" | sed -E 's/.*@([^ ]+).*/\1/')
  if [ "$ref" = "main" ] || [ "$ref" = "master" ] || [ "$ref" = "HEAD" ]; then
    err "unpinned action reference: $line"
  fi
done < <(grep -E '^\s+uses:' "$WORKFLOW" || true)

# 4. ci-local must exist and be syntactically valid.
[ -f scripts/ci-local.sh ] || err "scripts/ci-local.sh is missing"
bash -n scripts/ci-local.sh || err "scripts/ci-local.sh has a syntax error"

if [ "$fail" -ne 0 ]; then
  echo "workflow check: FAIL"
  exit 1
fi
echo "workflow check: PASS — $WORKFLOW"
