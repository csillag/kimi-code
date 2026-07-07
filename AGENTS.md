# AGENTS.md — operator guide for the `csillag/kimi-code` fork

Runbook for **agents (Claude, scripted runs) and humans** maintaining this
fork. It documents the one supported maintenance flow: periodically rebase the
feature branches onto latest upstream, then trigger a binary build that
**combines all feature branches**, versions them, and auto-publishes a GitHub
Release.

**New agent landing here: read this file end-to-end before changing anything.**

> This runbook lives on the fork's **`main`** branch, which holds only build
> infrastructure on top of upstream. Each feature branch keeps upstream's own
> `AGENTS.md` (they must stay clean for upstream PRs). If a feature branch is
> checked out, read this file via `git show main:AGENTS.md`.

---

## Branches

`main` is the **infra branch**: upstream `origin/main` + the build workflow,
`smart-install.sh`, and this file. It builds nothing on its own tree — the build
merges the feature branches at run time. It is the fork's **default branch** (so
`workflow_dispatch` is available) and the host of the raw `smart-install.sh`.

Feature branches (each based on upstream `origin/main`, each independently
PR-able upstream, each carrying only its own change):

| Branch | Upstream issue | Change |
| --- | --- | --- |
| `csillag/iframe` | #1387 | Embeddable web UI under a subpath: `vite base:'./'`, static `<base href="/">`, `document.baseURI` server base. |
| `csillag/web-permission-display-fix` | #1386 | Sync the permission indicator from `/status` in `refreshSessionStatus`. |
| `csillag/hide-sidebar` | (fork-only) | `?embed=1` query param hard-hides the sidebar + rail for iframe embedding. |
| `csillag/acp-graded-thinking` | (issue TBD) | ACP `session/set_config_option` accepts + advertises graded reasoning effort (`low`/`medium`/`high`/`xhigh`/`max`) live, not just on/off. Touches `packages/acp-adapter` only. |

Keep every feature branch rebased onto the **same** upstream base so they share a
clean merge-base (the build's octopus merge-base).

## Remotes (note: reversed from the usual convention)

```
origin   = https://github.com/MoonshotAI/kimi-code.git   # UPSTREAM
csillag  = https://github.com/csillag/kimi-code.git      # THIS FORK
```

The build workflow runs **on the fork**, where the feature branches live.

---

## Rebase → build → release cycle

### 0. Sanity

```sh
cd ~/deai/kimi-code
git status --short              # clean; else STOP and ask
git remote -v                   # origin=MoonshotAI, csillag=csillag
git fetch origin --prune        # upstream
git fetch csillag --prune       # fork
```

### 1. Rebase each feature branch onto upstream main

```sh
for b in csillag/iframe csillag/web-permission-display-fix csillag/hide-sidebar csillag/acp-graded-thinking; do
  git checkout "$b"
  git rebase origin/main        # resolve conflicts (each branch touches few files)
done
# sanity: the web app still builds
pnpm install
pnpm --filter @moonshot-ai/kimi-web run typecheck
pnpm --filter @moonshot-ai/kimi-web run build
```

### 2. Rebase the infra branch onto upstream main

```sh
git checkout main
git rebase origin/main
```

Conflicts to expect (main overrides these files vs upstream):
- **`AGENTS.md`** — keep the FORK's runbook (this file). During a rebase the
  sides swap: `--ours` is upstream's base, `--theirs` is the fork commit being
  reapplied. So: `git checkout --theirs AGENTS.md && git add AGENTS.md`
  (verify with `git show :3:AGENTS.md | head -2` — must be this runbook).
- **`.github/workflows/_native-build.yml`** — we only ADD a `version` input, a
  `ref` input, and the "Override CLI version" step, and set `ref:` on the
  checkout. Re-apply those additions on top of upstream, then `git add`.
  `build-fork.yml` and `smart-install.sh` are fork-only files and never conflict.

### 3. Push everything to the fork

```sh
for b in csillag/iframe csillag/web-permission-display-fix csillag/hide-sidebar csillag/acp-graded-thinking main; do
  git push --force-with-lease csillag "$b"
done
```

`main` must remain the fork's **default branch** (for `workflow_dispatch`). One-time (already set):
`gh api --method PATCH repos/csillag/kimi-code -f default_branch=main`
GitHub **Actions must be enabled** (one-time, already done):
`gh api --method PUT repos/csillag/kimi-code/actions/permissions -F enabled=true -f allowed_actions=all`

### 4. Trigger the build

```sh
gh workflow run build-fork.yml --repo csillag/kimi-code --ref main
```

`build-fork.yml`:
- **Combines** all feature branches (input `branches`, default = the four above)
  onto their octopus merge-base into a temporary `ci/combined-<run_id>` branch,
  pushes it, then reuses `_native-build.yml` against that ref.
- **Version** `= <upstream>-csillag.<N>` (N = highest existing fork-release
  counter + 1), baked in via the `version` input → `kimi --version`.
- **Tag** `= v<version>.<combined-short-sha>` (one SHA — the combined tree tip;
  the release notes list each feature branch and its SHA).
- Auto-creates the GitHub Release and deletes the temp branch on cleanup. No
  manual tagging. `-f release=false` builds artifacts without publishing.
- Override branches: `-f branches="csillag/iframe csillag/web-permission-display-fix"`.

### 5. Monitor

```sh
RID=$(gh run list --repo csillag/kimi-code --workflow build-fork.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RID" --repo csillag/kimi-code --exit-status
```

Unsigned 6-target matrix (linux x2, darwin x2, win32 x2). Windows builds but is
unused by `smart-install.sh` (macOS/Linux only); a failed Windows leg does not
block the release (`fail-fast: false`).

### 6. Verify

```sh
gh release view --repo csillag/kimi-code --json tagName,assets -q '.tagName, (.assets[].name)'
./smart-install.sh --resolve    # what optio calls: JSON with url + sha256
```

---

## How consumers use the binaries

- **Install / upgrade (linux/macOS):**
  `curl -fsSL https://raw.githubusercontent.com/csillag/kimi-code/main/smart-install.sh | bash`
- **optio:** calls `smart-install.sh --check` (prints `kimi ok` / `download <url>`);
  downloads `<url>` with its own tooling and unzips the `kimi` binary (zip root).
- **Disable kimi's in-app auto-update** (optio upgrades before each session):
  set `KIMI_CODE_NO_AUTO_UPDATE=1` in kimi's launch env.

## Invariants — do not break

- Keep the tag↔version transform identical in `build-fork.yml` (tag build) and
  `smart-install.sh` (`sed 's/^v//; s/\.[0-9a-f]+$//'`). It strips the single
  trailing `.<combined-sha>` to recover the binary version from the release tag.
- Every feature branch stays free of fork-only infra (for its upstream PR) and
  carries no agent/co-author attribution in commits (upstream `AGENTS.md` rule).
- The `_native-build.yml` `version`/`ref` inputs are no-ops when empty, so
  upstream's own callers of that reusable workflow are unaffected.
