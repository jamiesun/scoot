# Scoot Playground — Multi-Dimensional Assessment

- Time (local): <YYYYMMDD-HHMMSS>
- scoot: `<scoot --version>`
- Backend: `<base url>` (model `<model>`)
- Functional report: `playground/reports/<stamp>-evaluation.md`
- Overall verdict: **<PASS | WARN | FAIL>**

## Scorecard

| Dim | Dimension                  | Grade | Rationale (one line)            | Evidence            |
| --- | -------------------------- | ----- | ------------------------------- | ------------------- |
| F   | Functional health          | <P/W/F> | <e.g. suite PASS, all finals>  | `<path:line / count>` |
| C   | Capability coverage        | <P/W/F> | <e.g. 9/13 actions exercised>  | `<matrix ref>`      |
| S   | Safety & boundaries        | <P/W/F> | <e.g. guarded denies as expected> | `<policy output>` |
| R   | Reproducibility & isolation| <P/W/F> | <e.g. clean run, ignored-only diff> | `<git status>`  |
| D   | Documentation parity       | <P/W/F> | <e.g. coverage maps agree>     | `<diff ref>`        |
| M   | Maintainability & robustness | <P/W/F> | <e.g. set -eu everywhere>     | `<shellcheck>`      |

Headline grade = worst dimension (any FAIL → FAIL; else any WARN → WARN).

## F — Functional health

- Backend: <reachable | unreachable>
- wasm build/validate: <ok | FAILED>
- mcp_call smoke: <exit code>
- Per-task: `<name>` → exit `<n>` (reached final: <yes/no>) …
- Dominant failure mode (if any): <…>

## C — Capability coverage

Coverage matrix (action / policy → where tested, or `gap`):

| Surface        | Tested by                        | Status |
| -------------- | -------------------------------- | ------ |
| bash           | `tasks/…`                        | ok     |
| file_read      | `tasks/smoke.txt`                | ok     |
| …              | …                                | …      |
| recall         | —                                | gap    |

Ranked gaps (by product relevance): <…>

## S — Safety & boundaries

- `.env` ignored: <yes/no>; `config.toml` ignored: <yes/no>
- Inline secrets in `config.default.toml`: <none / FOUND at …>
- `guarded` denies destructive bash + out-of-root write: <yes/no>
- Secret leakage in report/audit: <none / …>

## R — Reproducibility & isolation

- `SCOOT_HOME=playground`: <yes/no>
- Ignored runtime set matches `clean.sh`: <yes/no>
- Run dirtied only ignored paths: <yes/no>

## D — Documentation parity

- README.md ↔ README.zh.md scope/commands/coverage: <agree / drift at …>
- Coverage map matches files on disk: <yes / mismatch at …>

## M — Maintainability & robustness

- Scripts set `set -eu`: <all / missing in …>
- Dangerous literals wrapped: <yes/no>
- shellcheck: <clean / installed? / findings …>

## Recommendations (highest leverage first)

1. <single concrete change> — touches `<file>`.
2. <…>
3. <…>

## Verdict

<one or two sentences: the headline grade, the worst dimension driving it, and
the single smallest next change that most improves the playground.>
