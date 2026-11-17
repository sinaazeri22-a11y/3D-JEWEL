# Workflow scope: the one user-gated step for the Phase 59 guard

This note exists so the guard does not need another expiring device code or a
rediscovery pass. It records the state, the single command only the account
owner can run, and what happens after.

## State at the time of writing (2026-11-17)

- `main` and `origin/main` were at `762e214` when this note was written; it is docs-only and changes no app code. Row 59 is closed: its trunk
  addendum cites run `44048585940` attempt 2 at `86fce44`. Do not re-record
  row 59 to land this guard.
- The guard is two commits on `phase-59-rail-sweep`, tip `94d04d6` whose
  parent is `e81955f`. It pins `runs-on: macos-26` and refuses to build when
  `/Applications/Xcode_26.6.app` is absent.
- The guard is **not** in `main` (`git merge-base --is-ancestor e81955f main`
  returns false). Row 59 deliberately shipped without it, and both the row and
  its addendum name that as a gap rather than an omission.
- `scripts/check-workflow.sh` passes on the guard's tree (structural fallback;
  ruby and actionlint are not installed here).
- The credential the repo uses reports scopes `gist, read:org, repo` — no
  `workflow`, which is why GitHub refuses a push that touches
  `.github/workflows/ios.yml`.
- No device-flow poll is running. Earlier codes (`A029-3446`, `8B1C-758B`)
  expired; do not issue another one.

## Why one command fixes both `gh` and `git push`

The repository's local git config resets the system helper and installs one of
its own:

```
credential.helper =
credential.helper = !GH_CONFIG_DIR=D:/dev-cache/gh-config /d/dev-cache/tools/gh/gh auth git-credential
```

So HTTPS pushes to `origin` authenticate with the same token `gh` reports,
stored under `GH_CONFIG_DIR=/d/dev-cache/gh-config`. Refreshing that token
with `workflow` is sufficient; no second credential needs attention.

## The command (run it whenever you are at the keyboard)

```bash
cd "/d/Test projects/3D JEWERLY" && \
GH_CONFIG_DIR=/d/dev-cache/gh-config /d/dev-cache/tools/gh/gh auth refresh -h github.com -s workflow
```

It prints a one-time code and `https://github.com/login/device`. Open the URL,
enter the code, and approve the request for the `workflow` scope on the
`sinaazeri22-a11y` account. The command blocks until approval or about fifteen
minutes pass; it keeps the existing scopes and adds `workflow`.

Nothing is written to `C:`: the config directory is on `D:`. The token itself
lives in the OS credential store by default (as it does today). Append
`--insecure-storage` if you want the token written into
`D:\dev-cache\gh-config\hosts.yml` instead.

## Confirm the scope took

```bash
cd "/d/Test projects/3D JEWERLY" && \
GH_CONFIG_DIR=/d/dev-cache/gh-config /d/dev-cache/tools/gh/gh api user -i | grep -i '^X-Oauth-Scopes'
```

Expected: `X-Oauth-Scopes: gist, read:org, repo, workflow`.

## What happens next (no decisions left open)

1. Cherry-pick `e81955f` onto a fresh branch off `main`; do not merge
   `phase-59-rail-sweep`, whose phase commit `94d04d6` predates the gated
   `7013376` and would reintroduce a stale tree.
2. Push that branch and dispatch `iOS gate` at its head with no runner input,
   so it lands on the arm64 `macos-26` default.
3. Watch that run to a real conclusion. A perf or UI miss on untouched code is
   answered by a rerun at the same head, never by relaxing a threshold.
4. On green: ff-merge into `main`, push, dispatch a trunk run at the merged
   head, and record it as a docs-only addendum citing the run id, attempt,
   head, counts and step durations. Row 59 itself stays as recorded.
