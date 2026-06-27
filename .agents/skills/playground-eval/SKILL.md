---
name: playground-eval
description: Run a multi-dimensional, multi-angle assessment of the scoot playground/ test environment and write a scored Markdown report. Use when asked to "evaluate the playground", "评估 playground", "给 playground 打分", "playground 多维度评估", or to audit how well the committed playground exercises scoot end-to-end. Goes beyond the functional pass/fail smoke in playground-evaluator: it scores functional health, capability coverage, safety boundaries, reproducibility, documentation parity, and maintainability, then recommends the highest-leverage fixes.
---

# Playground Multi-Dimensional Evaluation

Assess the committed `playground/` environment (see `playground/README.md`) from
several angles at once and produce a single scored report. This is the holistic
layer on top of the functional smoke: `playground/scripts/evaluate.sh` and the
`playground-evaluator` skill answer "does it pass?"; this skill answers "how good
is the playground, where are the gaps, and what is the smallest fix that helps
most?".

Drive everything with the normal tools (`bash`, `file_read`, `grep`, `glob`).
Run read-only checks by default. Do not commit anything. Write the report to the
gitignored `playground/reports/` area, never to a tracked file.

## Scope and ground truth

- The product boundaries live in `AGENT.md` and `docs/ROADMAP.md`. Score the
  playground against those, not against your own preferences.
- The authoritative list of built-in actions to look for (AGENT.md): `bash`,
  `file_read`, `file_write`, `file_edit`, `grep`, `glob`, `outline`,
  `http_request`, `skill`, `recall`, `parallel`, `mcp_call`, `wasm_tool`.
- The three execution policies to look for: `guarded`, `readonly`,
  `unrestricted`.
- Never read `playground/logs/audit.jsonl` directly; it can carry large escaped
  observations that bloat context. Use `playground/scripts/state-brief.sh`.
- Hard rule reminder: secrets must never be committed, printed, or logged; every
  subprocess and network path must have a hard timeout. Treat violations of these
  as automatic FAIL on the relevant dimension.

## The six dimensions

Score each dimension `PASS` / `WARN` / `FAIL` and cite one line of evidence
(a path, a command output line, a count). Definitions:

1. **Functional health (F).** Backend reachable, wasm build/validate ok, every
   task prompt reaches a `final`, mcp_call smoke passes, policy dry-runs behave.
   Source of truth is a fresh `evaluate.sh` run plus `state-brief.sh`.
2. **Capability coverage (C).** How much of the authoritative action list and the
   three policies the playground actually exercises. Map each action/policy to
   where it is tested (or mark it as an uncovered gap).
3. **Safety & boundaries (S).** `.env` is gitignored and `config.default.toml`
   carries no inline key; `guarded` mode actually denies destructive `bash` and
   out-of-root `file_write`; nothing in the report or audit leaks a secret.
4. **Reproducibility & isolation (R).** Runs use `SCOOT_HOME=playground`; the
   committed-vs-ignored split in `playground/.gitignore` matches reality;
   `clean.sh` restores a clean slate without deleting `.env` or committed assets.
5. **Documentation parity (D).** `README.md` and `README.zh.md` agree on scope,
   commands, and the coverage map, and the coverage map matches the real
   `tasks/`, `scripts/`, and `skills/` on disk (per the bilingual docs policy).
6. **Maintainability & robustness (M).** Scripts set `set -eu`, handle failure
   explicitly, keep dangerous literals wrapped (e.g. `policy-dry-runs.sh`), and
   are shellcheck-clean.

## Procedure

Run from the repo root. Prerequisite: scoot is built and `playground/.env` has a
working `SCOOT_PLAYGROUND_API_KEY` (see `playground/README.md` Setup). If the
build or `.env` is missing, say so and offer to run setup rather than guessing.

### 1. Gather functional evidence (F)

Optionally reset first for a clean, comparable run:

```sh
playground/scripts/clean.sh        # optional; ask before wiping prior reports
```

Run the functional suite with a generous timeout (it drives several agent
sub-runs and may take minutes), then capture lightweight state:

```sh
playground/scripts/evaluate.sh     # prints "Report written: <path>" on the last line
playground/scripts/state-brief.sh
```

Read the generated `playground/reports/<stamp>-evaluation.md` (plain Markdown) —
not the raw audit log — and lift its `## Verdict` plus per-task exits. A task
"passed" only if its run reached a `final` event; do not infer success from the
mere absence of errors. Name the dominant failure mode if any (malformed
actions, policy denials, backend failures).

### 2. Score capability coverage (C)

Build the coverage matrix from disk, not from memory:

```sh
ls playground/tasks/*.txt
grep -RoiE '"action"\s*:\s*"[a-z_]+"' playground/tasks || true
grep -RhoE '\b(guarded|readonly|unrestricted)\b' playground/config.default.toml playground/scripts || true
```

For each authoritative action and each policy, record where it is exercised or
mark `gap`. The playground intentionally focuses on read tools, policy, wasm_tool,
mcp_call, audit/sessions, and skills (see the README coverage map); call out
genuinely untested surfaces (e.g. `recall`, `parallel`, `http_request` live,
`file_edit`, schedule firing) as coverage gaps, ranked by product relevance.

### 3. Audit safety & boundaries (S)

```sh
git -C . check-ignore playground/.env playground/config.toml   # both must be ignored
grep -niE 'key|token|secret|password' playground/config.default.toml || true
playground/scripts/policy-dry-runs.sh guarded                  # destructive bash + out-of-root write must be DENIED
```

Confirm `guarded` denies `bash rm -rf /` and out-of-root `file_write`, and that
`readonly` denies writes too. Skim the fresh evaluation report and `state-brief`
output for any leaked secret value (there must be none). Any leaked secret or a
missing subprocess/network timeout is an automatic `FAIL`.

### 4. Check reproducibility & isolation (R)

```sh
grep -n 'SCOOT_HOME' playground/scripts/env.sh
sed -n '1,40p' playground/.gitignore
git -C . status --porcelain playground   # a run must not dirty committed files
```

Verify the ignored runtime dirs (`runs/ logs/ state/ reports/ tmp/`,
`config.toml`, built `component.wasm`) match what `clean.sh` manages, and that an
evaluation run leaves only ignored paths changed.

### 5. Check documentation parity (D)

Compare the two READMEs and validate the coverage map against the filesystem:

```sh
diff <(sed -n '/Coverage map/,$p' playground/README.md) \
     <(sed -n '/覆盖范围/,$p' playground/README.zh.md) || true
ls playground/scripts playground/tasks playground/skills
```

Flag any command, skill, or coverage-map row that exists in one language but not
the other, or that names a script/task/skill that is not actually on disk.

### 6. Check maintainability & robustness (M)

```sh
grep -L 'set -eu' playground/scripts/*.sh    # every script should appear to set it
command -v shellcheck >/dev/null 2>&1 && shellcheck playground/scripts/*.sh || \
  echo "shellcheck not installed; review scripts manually"
```

Note missing `set -eu`, unguarded dangerous literals, or unhandled failure paths.

## Write the report

Write a timestamped report to the gitignored reports area using the structure in
`report-template.md` (read it from this skill's directory). Suffix it
`-assessment.md` so it does not collide with `evaluate.sh`'s `-evaluation.md`:

- Path: `playground/reports/<YYYYMMDD-HHMMSS>-assessment.md`.

The report must contain, in order:

1. A header with timestamp, scoot version, backend, and the linked functional
   report path.
2. A scorecard table: one row per dimension (F, C, S, R, M, D) with
   `PASS/WARN/FAIL`, a one-line rationale, and one evidence pointer.
3. A short section per dimension expanding the rationale with concrete findings.
4. A prioritized recommendations list (highest leverage first), each phrased as a
   single concrete change with the file it touches.
5. An overall verdict line: the worst dimension caps the headline grade — any
   `FAIL` makes the overall `FAIL`; otherwise any `WARN` makes it `WARN`.

## Final summary to the user

After writing the report, give a concise spoken summary (not the whole file):

- the overall verdict and the per-dimension PASS/WARN/FAIL line,
- whether the backend was reachable and the functional suite's PASS/FAIL,
- the top 1–3 coverage gaps or boundary issues,
- the single smallest next change that most improves the playground,
- the report path and the underlying functional report path.

## Guardrails

- Read-only by default. The only writes are the report under
  `playground/reports/` and whatever `evaluate.sh`/`clean.sh` already manage under
  ignored runtime dirs. Never edit tracked files as part of an evaluation.
- Ask before running `clean.sh` if prior reports might still be needed.
- Never paste secret values into the report; reference env var names only.
- Score against `AGENT.md` and `docs/ROADMAP.md`, not personal preference; if a
  "gap" is actually an intentional non-goal, label it as out-of-scope, not a fail.
- If the backend is unreachable or scoot is unbuilt, still score S/R/D/M from
  static inspection, mark F/C as `blocked`, and say what to fix to unblock.
