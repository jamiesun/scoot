---
name: project-audit
description: Run a comprehensive, multi-dimensional audit of the whole scoot repository and write a single scored Markdown report. Use when asked to audit the project, 全面审计, 项目审计, 代码审查, 给项目打分, 多维度审计, review the whole repo, or check overall project health. Scores ten angles at once — documentation/functionality consistency, documentation friendliness, code quality & robustness, roadmap boundary compliance, config-file consistency, security & vulnerabilities, bilingual documentation parity, build & test health, Zig memory/resource discipline, and public-API/binary-size discipline — then ranks the highest-leverage fixes. Read-only by default; only writes the report.
---

# Whole-Project Audit

Audit the **entire repository** (not just `playground/`) across ten dimensions at
once and produce one scored Markdown report. This is the repo-wide health review:
the `playground-eval` skill scores the test environment; this skill scores the
product itself — its source, docs, config, and boundaries.

Drive everything with the normal tools (`bash`, `file_read`, `grep`, `glob`,
`outline`). Run **read-only** checks by default. **Do not commit anything** and do
**not** edit tracked files as part of an audit; the only write is the report.

## Scope and ground truth

Score against the project's own declared intent, not personal preference:

- `AGENT.md` — the implementation handbook, Code Map, Zig 0.16 habits, Memory
  Discipline, and the **Hard Rules** (1–10). Treat any Hard Rule violation as an
  automatic `FAIL` on the relevant dimension.
- `docs/ROADMAP.md` / `docs/ROADMAP.zh.md` — product intent and **non-goals**. A
  "missing feature" that is an explicit non-goal is **out-of-scope**, not a gap.
- The authoritative built-in actions (AGENT.md): `bash`, `file_read`,
  `file_write`, `file_edit`, `grep`, `glob`, `outline`, `http_request`, `skill`,
  `recall`, `parallel`, `mcp_call`, `wasm_tool`.
- The three execution policies: `guarded`, `readonly`, `unrestricted`.
- The Code Map in `AGENT.md` is the expected `src/` layout — drift between it and
  the real `src/` tree is a finding under DF and BL.

Never read large generated/log artifacts in full (`*.jsonl` audit logs,
`zig-out/`, `.zig-cache/`). They bloat context and prove nothing. Grep them
narrowly if you must.

## The ten dimensions

Score each `PASS` / `WARN` / `FAIL` and cite **one** piece of evidence (a path, a
line, a command-output line, a count). Definitions:

1. **Documentation ↔ Functionality consistency (DF).** Do the docs describe what
   the code actually does? Every action, policy, command, flag, and config key
   named in `README.md`, `AGENT.md`, `docs/`, and `book/` must exist in the
   source — and vice-versa, public capabilities should be documented. The
   `AGENT.md` Code Map must match the real `src/` tree.
2. **Documentation friendliness (DX).** Can a new user get from zero to a working
   run? Check that `README.md` has install, first-run, config, and secret-setup
   paths that actually work; that examples/commands are copy-pasteable; that
   `book/` navigation, `docs/` cross-links, and `--help` text are coherent and not
   stale.
3. **Code quality & robustness (CQ).** Idiomatic Zig 0.16 (see AGENT.md habits),
   input validation before external effects, explicit error handling, no
   `unreachable`/`@panic` on reachable paths, no obvious resource leaks, and
   **every subprocess and network path has a hard timeout** (Hard Rule 6).
4. **Roadmap boundary compliance (RB).** Nothing crosses the Hard Rules or
   non-goals: no GUI/web/tray, only the `/v1/responses` API shape (no Chat
   Completions glue), no cloud sync, no unvalidated model execution, no
   long-term/vector memory, Wasm stays a pure stdin/stdout/argv/exit transform.
5. **Config consistency (CC).** `config.example.toml`, the loaded defaults in
   `src/config.zig`, the TOML subset in `src/toml.zig`, and every config key
   mentioned in docs all agree. No inline plaintext keys anywhere; config schema
   in code matches the documented schema.
6. **Security & vulnerabilities (SEC).** Secrets never compiled in, committed,
   printed, or written to audit logs (Hard Rule 7); policy gates (`src/policy.zig`)
   actually enforce path/network guardrails; no command/path injection in
   `src/tools/*`; no unbounded reads of untrusted input; `.gitignore` keeps
   `config.toml`/secrets out of the tree; Wasm host exposes no ambient authority
   (Hard Rule 9).
7. **Bilingual documentation parity (BL).** Hard Rule 10: every English doc has a
   synced Chinese counterpart and vice-versa — `README.md`↔`docs/README.zh.md`,
   `AGENT.md`↔`docs/AGENT.zh.md`, `ROADMAP`, `CHANGELOG`, `DAEMON`, `SKILLS`,
   `WASM_TOOLS`, and `book/en`↔`book/zh`. Scope, commands, and safety rules must
   match across languages.
8. **Build & test health (BT).** `zig build` and `zig build test` are green;
   `zig fmt --check` is clean; ReleaseSafe builds; `--version` smoke works. Every
   `src/*.zig` module carries `test { std.testing.refAllDecls(@This()); }` and new
   subsystems are exported from `src/internal.zig`.
9. **Memory & resource discipline (MEM).** Per-turn arenas for temporary ReACT
   work; session history in longer-lived storage; no per-turn JSON/request scratch
   in long-lived allocators; `deinit` only where ownership isn't process/arena
   scoped. Look for leaks, double-frees, and use-after-free risks.
10. **Public-API & binary-size discipline (API).** `src/root.zig` stays a narrow
    whitelisted facade (it has a whitelist test); private subsystems are exported
    only via `src/internal.zig`. The single-binary, low-dependency design holds —
    `build.zig.zon` adds no heavyweight deps, ReleaseSmall stays small (Hard
    Rule 5).

> Want a lighter pass? You may run a **subset**: ask which dimensions matter and
> score only those, but always say which ones you skipped and why.

## Procedure

Run from the repo root. The audit is mostly static, so it works even if the
backend is unreachable; mark dynamic checks `blocked` rather than guessing.

### 0. Orient

```sh
git -C . rev-parse --short HEAD
git -C . status --porcelain        # note pre-existing dirt; never clean it
ls src src/tools docs book/en book/zh
```

### 1. Build & test health (BT)

```sh
zig fmt --check src build.zig            # must be clean
zig build                                 # Debug build must succeed
zig build test                            # tests must be green
zig build -Doptimize=ReleaseSafe          # release build must succeed
./zig-out/bin/scoot --version             # smoke
grep -rL 'refAllDecls' src --include='*.zig'   # modules missing the test hook
```

Run the long ones with a generous `timeout_ms`. If a build/test fails, capture the
failing command and the first real error line; don't paste the whole log.

### 2. Documentation ↔ functionality (DF) + Code Map drift

Cross-check declared surface against source:

```sh
# Every built-in action should be implemented and registered:
for a in bash file_read file_write file_edit grep glob outline http_request skill recall parallel mcp_call wasm_tool; do
  printf '%s: ' "$a"; grep -rl "\"$a\"" src --include='*.zig' | head -1 || echo MISSING
done
# Code Map vs reality:
ls src/*.zig
grep -n '| \`src/' AGENT.md
# CLI flags/commands documented vs parsed in main.zig:
grep -nE '"--?[a-z-]+"' src/main.zig | head -50
```

Flag actions/policies/flags named in docs but absent in code, and notable public
capabilities present in code but undocumented.

### 3. Documentation friendliness (DX)

```sh
sed -n '1,80p' README.md                  # install + first-run path present?
grep -niE 'install|setup|quick ?start|first run' README.md
grep -rn 'SCOOT_HOME\|config.toml\|api[_ ]?key' README.md docs/README.zh.md
ls book/en/src book/zh/src 2>/dev/null
```

Verify the zero-to-run story is complete and copy-pasteable, secret setup is
explained without leaking values, and `book/` SUMMARY navigation isn't stale.

### 4. Roadmap boundary compliance (RB)

```sh
grep -rniE 'chat[/_-]?completions|/v1/chat' src        # must be empty (Hard Rule 2)
grep -rniE 'gui|webview|tray|electron|http server|listen\(' src | grep -vi 'http_request\|comment' || true
grep -rniE 'vector|embedding|faiss|sqlite|postgres' src || true   # long-term memory creep
```

Read `docs/ROADMAP.md` non-goals and confirm nothing in `src/` crosses them. Any
hit is a candidate `FAIL`; confirm by reading the surrounding code before judging.

### 5. Config consistency (CC)

```sh
grep -nE '^\s*[a-z_]+\s*=' config.example.toml | sed -E 's/=.*//' | tr -d ' ' | sort -u
grep -nE '\.[a-z_]+\b' src/config.zig | head -80
grep -niE 'key|token|secret|password' config.example.toml   # no inline secret values
```

Diff the keys in `config.example.toml` against the struct fields parsed in
`src/config.zig` and the keys documented in `docs/`. Flag any key in one place but
not the others.

### 6. Security & vulnerabilities (SEC)

```sh
git -C . check-ignore config.toml                       # must be ignored
grep -rniE 'sk-[a-z0-9]{12,}|api[_-]?key\s*=\s*"[^"]+"' src config.example.toml || true
grep -rn 'timeout\|deadline' src/tools src/llm.zig | head     # every subprocess/network path bounded?
grep -rnE 'execvp|system\(|sh -c|popen' src/tools           # injection surface — must be sandboxed
grep -rn 'audit' src/audit.zig | head                        # confirm secrets are redacted, not logged
```

Confirm: secrets only via env / 0600 file / credential command (`src/secret.zig`);
audit log redacts secret values; Wasm host (`src/wasm_host.zig`) traps fs/net/env/
clock/random imports; policy gate denies destructive `bash` and out-of-root writes
in `guarded`/`readonly`. Any leak or missing timeout is an automatic `FAIL`.

### 7. Bilingual documentation parity (BL)

```sh
# Every English doc should have a Chinese twin and vice-versa:
ls README.md AGENT.md CHANGELOG.md
ls docs/README.zh.md docs/AGENT.zh.md docs/CHANGELOG.zh.md docs/ROADMAP.md docs/ROADMAP.zh.md
diff <(ls book/en/src) <(ls book/zh/src) || true
# Spot heading/scope drift between a pair:
grep -cE '^#' README.md docs/README.zh.md
```

Flag any doc that exists in one language but not the other, and any pair whose
scope, command list, or safety rules visibly diverge.

### 8. Code quality, memory, and API discipline (CQ + MEM + API)

```sh
grep -rnE '\bunreachable\b|@panic\(' src | grep -v test     # reachable panics?
grep -rn 'arena' src/agent.zig | head                        # per-turn arena usage
grep -rn 'deinit' src --include='*.zig' | wc -l              # sanity, then inspect hot spots
sed -n '1,60p' src/root.zig                                  # whitelist facade still narrow?
grep -n 'dependencies' build.zig.zon                         # no heavyweight deps crept in
zig build -Doptimize=ReleaseSmall && ls -la zig-out/bin/scoot   # binary still small
```

Read the hot modules (`src/agent.zig`, `src/llm.zig`, `src/tools/*`, `src/policy.zig`)
closely enough to judge idiomatic 0.16 style, validation-before-effect, error
handling, arena vs long-lived allocation, and that `root.zig` hasn't grown beyond
its whitelist.

## Write the report

Write a timestamped report using the structure in `report-template.md` (read it
from this skill's directory). Write to a **gitignored** location so the audit never
dirties the tree:

- Path: `reports/<YYYYMMDD-HHMMSS>-project-audit.md`.
- If `reports/` is not gitignored, add `reports/` to `.gitignore` first (this is
  the one allowed tracked-file edit), or fall back to `/tmp` and say so. Confirm
  with `git -C . status --porcelain` that the audit left only ignored paths changed
  (plus the optional `.gitignore` line).

The report must contain, in order:

1. A header: timestamp, scoot version, current commit, and which dimensions were
   scored vs skipped.
2. A scorecard table: one row per dimension (DF, DX, CQ, RB, CC, SEC, BL, BT, MEM,
   API) with `PASS/WARN/FAIL`, a one-line rationale, and one evidence pointer.
3. A short section per scored dimension expanding the rationale with concrete
   findings (path + line + what's wrong).
4. A prioritized recommendations list, highest leverage first, each phrased as a
   single concrete change naming the file it touches.
5. An overall verdict: the worst dimension caps the grade — any `FAIL` → overall
   `FAIL`; otherwise any `WARN` → `WARN`; else `PASS`.

## Final summary to the user

After writing the report, give a concise spoken summary (not the whole file):

- the overall verdict and the per-dimension PASS/WARN/FAIL line,
- whether build/test were green (or blocked, and why),
- the top 1–3 findings (Hard Rule violations and security issues first),
- the single smallest next change that most improves project health,
- the report path.

## Guardrails

- **Read-only by default.** The only writes are the report under `reports/` and,
  at most, adding `reports/` to `.gitignore`. Never edit source, docs, or config as
  part of an audit — propose fixes, don't apply them.
- Score against `AGENT.md` and `docs/ROADMAP.md`, not personal taste. An
  intentional non-goal is **out-of-scope**, never a `FAIL`.
- Any Hard Rule (1–10) violation, leaked secret, or missing subprocess/network
  timeout is an automatic `FAIL` on its dimension and a top recommendation.
- Never paste secret **values** anywhere — reference env-var names only.
- Never read full audit `*.jsonl`, `zig-out/`, or `.zig-cache/`; grep narrowly.
- Don't clean a pre-existing dirty tree; record it as context and continue.
- If a dynamic check can't run (no backend, unbuilt toolchain), mark that
  dimension `blocked`, score the rest statically, and say what to fix to unblock.
