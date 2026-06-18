---
name: auto-release
description: Cut a new scoot release end-to-end. Use when asked to "release", "发布版本", "出新版本", "bump the version", "tag a release", or "auto release". Determines the next semantic version from the PRs merged since the last tag (major vs minor vs patch), bumps the single source of truth in build.zig.zon, opens and merges a release PR, then pushes the git tag that triggers the GitHub release workflow.
---

# Auto Release

Cut a new release for **jamiesun/scoot** without hardcoded-version drift. The
version is computed from what changed since the last release, written to the one
source of truth (`build.zig.zon`), landed via a normal PR, then frozen as a git
tag that the `Release` workflow turns into binaries.

## Version model (read first)

- **Single source of truth:** `build.zig.zon` → `.version = "X.Y.Z"`.
  `build.zig` reads it and injects it through `build_options`; `src/root.zig`
  re-exports it as `scoot.version`. **Never** hardcode the version anywhere else.
- **Release builds** override it with the tag: the workflow runs
  `zig build -Dversion=${TAG#v}`, so a published binary always reports its tag.
- Therefore a release = (1) bump `.version` in `build.zig.zon` on `main`, then
  (2) push a matching `vX.Y.Z` tag. Keep them equal.

## Bump decision: major vs minor vs patch

Classify **every PR merged since the last tag**, then take the **highest**:

| Signal in the PR (label / title / body)                              | Bump  |
|----------------------------------------------------------------------|-------|
| Breaking change: label `breaking`/`breaking-change`/`major`, a `feat!:`/`fix!:` title, or `BREAKING CHANGE` in the body | **major** |
| New capability: label `enhancement`/`feature`, or `feat:` title       | **minor** |
| Fix / refactor / docs / chore / perf only: label `bug`, or `fix:`/`docs:`/`chore:`/`refactor:`/`perf:` title | **patch** |

Standard SemVer math on `X.Y.Z`:
- **major** → `(X+1).0.0`
- **minor** → `X.(Y+1).0`
- **patch** → `X.Y.(Z+1)`

Notes:
- `小版本` = minor, `大版本` = major, smallest = patch. If the user names a level
  explicitly, honor it; otherwise use the computed recommendation.
- **Pre-1.0 caveat (X = 0):** state the computed bump, then confirm intent with
  the user before a `1.0.0` jump — early projects often treat breaking changes as
  a *minor* bump while `0.y`. Default to the table unless the user says otherwise.
- If **no** PRs merged since the last tag, stop: there is nothing to release.

## Procedure

Run from the repo root. Assume `gh` is authenticated and `main` is the release branch.

### 1. Sync and find the last release

```sh
git checkout main && git pull --ff-only origin main
git fetch --tags origin
last_tag=$(git tag -l 'v*' --sort=-v:refname | head -1)   # e.g. v0.0.2
echo "last tag: ${last_tag:-<none>}"
```
If there are no tags, treat the last version as `v0.0.0` and start from there.

### 2. Collect the PRs merged since the last tag

This repo squash-merges, so each merge is a `main` commit ending in `(#N)`:

```sh
range="${last_tag:+$last_tag..}origin/main"
git log --oneline "$range" | grep -oE '\(#[0-9]+\)' | tr -d '(#)' | sort -un
```
For each PR number, read its signals:

```sh
gh pr view <N> --json number,title,labels,mergedAt \
  --jq '{n:.number, title:.title, labels:[.labels[].name]}'
```
If a commit has no `(#N)` (direct push), fall back to its commit message subject
for the same `feat/fix/feat!` classification.

### 3. Decide the next version

Apply the table above across all collected PRs (highest wins). Compute the new
`X.Y.Z` from `last_tag`. **Tell the user**: the recommended bump, the new
version, and the one-line evidence per PR (number, level, why). Honor an explicit
override. Respect the pre-1.0 caveat before any `1.0.0`.

### 4. Bump the single source of truth

Edit **only** `build.zig.zon`'s `.version`:

```sh
new_version="X.Y.Z"   # from step 3, no leading v
# update the .version line in build.zig.zon to "$new_version"
```
Then record the changelog in the repo so release notes are reproducible. In
`CHANGELOG.md` (and its Chinese counterpart `docs/CHANGELOG.zh.md`), turn the
`## [Unreleased]` heading into `## [X.Y.Z] - YYYY-MM-DD`, list the PRs since the
last tag under `Added`/`Fixed`/`Documentation`, add a fresh empty
`## [Unreleased]` section on top, and update the compare links at the bottom.

Verify the binary reports it, and that nothing else broke:

```sh
zig build && ./zig-out/bin/scoot --version          # must print: scoot X.Y.Z
zig build test                                       # must be green
```

### 5. Land the bump via a release PR

```sh
git checkout -b release/v"$new_version"
git add build.zig.zon CHANGELOG.md docs/CHANGELOG.zh.md
git commit -m "Release v$new_version

<bullet changelog: one line per PR since the last tag>

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push -u origin release/v"$new_version"

gh pr create --base main --head release/v"$new_version" \
  --title "Release v$new_version" \
  --body "Version bump to v$new_version.

## Changes since $last_tag
<bulleted changelog with PR links>"
```
Wait for required checks, then squash-merge and clean up:

```sh
gh pr checks <pr-number> --watch --interval 15      # all must pass
gh pr merge <pr-number> --squash --delete-branch
git checkout main && git pull --ff-only origin main
```
Confirm `main`'s `build.zig.zon` now has the new version before tagging.

### 6. Tag → trigger the release workflow

The `Release` workflow (`.github/workflows/release.yml`) fires on `v*` tags and
builds the 5 platform binaries with `-Dversion=$new_version`:

```sh
git tag -a "v$new_version" -m "Release v$new_version"
git push origin "v$new_version"
gh run watch "$(gh run list --workflow=Release --branch "v$new_version" \
  --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

### 7. Verify the release notes

The workflow now derives the published notes from the `## [X.Y.Z]` section of
`CHANGELOG.md` (falling back to GitHub auto-generated notes only when the version
has no entry). Because step 4 already landed that section, the notes are correct
without any manual `gh release edit`. Just confirm:

```sh
gh release view "v$new_version" --json tagName,isDraft,assets \
  --jq '{tag:.tagName, draft:.isDraft, assets:[.assets[].name]}'
```
If the notes are wrong, the fix is to correct `CHANGELOG.md` on `main` (the
source of truth) rather than hand-editing the release. Done when: the tag exists,
the release is published (not draft) with all five
`scoot-v$new_version-*.tar.gz` assets, and `build.zig.zon` on `main` equals the
tag. Report the new version, the bump level + reasoning, and the release URL.

## Guardrails

- **Never** tag before the bump PR is merged to `main` — the tag must point at a
  commit whose `build.zig.zon` already holds that version.
- **Never** merge the release PR while checks are failing.
- Abort if the working tree is dirty, if `main` is behind `origin/main`, or if
  step 2 finds no new PRs.
- Keep the `vX.Y.Z` tag and `build.zig.zon` `.version` identical.
- Keep `CHANGELOG.md` and `docs/CHANGELOG.zh.md` in sync, and land the version's
  changelog section in the bump PR so the workflow can publish reproducible notes.
- Do not edit `src/root.zig` for the version; it is derived from `build_options`.
