# Project Audit Report

- **Timestamp:** <YYYY-MM-DD HH:MM:SS TZ>
- **scoot version:** <output of `scoot --version`, or "unbuilt">
- **Commit:** <short SHA from `git rev-parse --short HEAD`>
- **Working tree:** <clean | dirty: list pre-existing changes>
- **Dimensions scored:** <e.g. all 10 | DF, SEC, CC only>
- **Dimensions skipped:** <none | name + why>

## Scorecard

| # | Dimension | Verdict | Rationale (one line) | Evidence |
|---|-----------|---------|----------------------|----------|
| DF  | Documentation ↔ Functionality | PASS/WARN/FAIL/blocked | | `path:line` / count |
| DX  | Documentation friendliness    | PASS/WARN/FAIL/blocked | | |
| CQ  | Code quality & robustness     | PASS/WARN/FAIL/blocked | | |
| RB  | Roadmap boundary compliance   | PASS/WARN/FAIL/blocked | | |
| CC  | Config consistency            | PASS/WARN/FAIL/blocked | | |
| SEC | Security & vulnerabilities    | PASS/WARN/FAIL/blocked | | |
| BL  | Bilingual documentation parity| PASS/WARN/FAIL/blocked | | |
| BT  | Build & test health           | PASS/WARN/FAIL/blocked | | |
| MEM | Memory & resource discipline  | PASS/WARN/FAIL/blocked | | |
| API | Public-API & binary-size      | PASS/WARN/FAIL/blocked | | |

**Overall verdict:** <PASS | WARN | FAIL> — <worst dimension caps the grade>

## Findings by dimension

### DF — Documentation ↔ Functionality
<concrete findings: path + line + what's wrong, or "no issues found">

### DX — Documentation friendliness
<...>

### CQ — Code quality & robustness
<...>

### RB — Roadmap boundary compliance
<...>

### CC — Config consistency
<...>

### SEC — Security & vulnerabilities
<Hard Rule 7/9 status, timeouts, injection surface, .gitignore coverage. No secret values.>

### BL — Bilingual documentation parity
<missing twins, scope/command drift between EN and ZH>

### BT — Build & test health
<zig fmt --check, zig build, zig build test, ReleaseSafe, --version, refAllDecls coverage>

### MEM — Memory & resource discipline
<arena vs long-lived allocation, leaks, deinit placement>

### API — Public-API & binary-size discipline
<root.zig whitelist width, internal.zig exports, deps, ReleaseSmall size>

## Prioritized recommendations

Highest leverage first. Each item = one concrete change + the file it touches.

1. **[SEC|FAIL]** <change> — `path` — <why it's the top priority>
2. **[<dim>|<sev>]** <change> — `path`
3. **[<dim>|<sev>]** <change> — `path`
4. ...

## Notes

- <blocked checks and how to unblock them>
- <intentional non-goals encountered (out-of-scope, not failures)>
- <pre-existing dirty-tree context, if any>
