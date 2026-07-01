# Sessions & Audit

Scoot persists what it does as **append-only JSONL** on local disk — short-term
session transcripts and a step-by-step audit log. Both are plain text and easy to
replay, grep, or pipe into other tools. There is **no** long-term semantic memory
or vector database by design (see the [Roadmap](roadmap.md)).

## Sessions

A session is the message transcript of a single interaction. `-e` runs and REPL
conversations get a fresh id for each process, such as `cli-<ms>-<pid>` or
`repl-<ms>-<pid>`, so independent runs do not get appended into one shared
`cli.jsonl` or `repl.jsonl` file. Scheduled jobs keep the stable id
`job-<id>` because they represent a continuing unattended task.

It is persisted to:

```text
~/.scoot/state/sessions/<id>.jsonl
```

Each line is one message:

```json
{"role":"system","content":"..."}
{"role":"user","content":"count the Zig files"}
{"role":"assistant","content":"{\"thought\":\"...\",\"action\":\"glob\",\"action_input\":\"...\"}"}
```

`role` is `system`, `user`, or `assistant`. Writes are **append-only**, so a file
accumulates the full back-and-forth for that session and can be replayed in order.
Resume/loading a previous transcript is intentionally separate from persistence
and is not enabled by the session file naming alone.

Sessions are short-term memory only. They are not indexed or summarized across
runs; persistence is for auditability and inspection, not recall.

### Inspecting Sessions

Use the read-only CLI commands to inspect persisted session files without
starting the agent:

```bash
scoot sessions list
scoot session show <id>
```

`sessions list` prints each local session id with its modification timestamp,
message count, and first user-message summary. `session show <id>` prints that
session transcript as JSONL so it can be piped into other tools.

## Audit Log

Every meaningful step is recorded to the audit log when `[audit] to_file = true`
(the default):

```text
~/.scoot/logs/audit.jsonl
```

Each line is one event:

```json
{"seq":0,"ts":1718600000123,"session_id":"cli-1718600000000-4242","kind":"run","msg":"goal: count the Zig files"}
{"seq":1,"ts":1718600000456,"session_id":"cli-1718600000000-4242","kind":"thought","msg":"..."}
{"seq":2,"ts":1718600000789,"session_id":"cli-1718600000000-4242","kind":"tool_call","msg":"glob {\"pattern\":\"**/*.zig\"}"}
{"seq":3,"ts":1718600000900,"session_id":"cli-1718600000000-4242","kind":"observation","msg":"..."}
{"seq":4,"ts":1718600001000,"session_id":"cli-1718600000000-4242","kind":"final","msg":"There are 23 Zig files."}
```

| Field | Meaning |
| --- | --- |
| `seq` | Monotonic event sequence number (per logger instance, from 0). |
| `ts` | Wall-clock timestamp, Unix **milliseconds**. |
| `session_id` | Local session id that correlates audit events with `state/sessions/<id>.jsonl`. |
| `run_id` | Optional finer-grained run correlation field. |
| `kind` | Event type (see below). |
| `msg` | Message text, with secrets redacted. |

### Event Kinds

| `kind` | When it's written |
| --- | --- |
| `run` | Start of a run, carrying the user goal (separates runs in the log). |
| `thought` | The model's one-line reasoning for a step. |
| `tool_call` | An action about to execute, with its input. |
| `observation` | The tool's result fed back to the model. |
| `final` | The terminal answer. |
| `policy_deny` | An action rejected by the policy gate. |
| `system_error` | An internal/recoverable error. |

`run` markers let you split a single append-only file into individual runs, and
`seq` + `ts` let you replay a timeline and correlate events. `policy_deny` entries
are an audit trail of exactly what the gate blocked.

To inspect the events for one session:

```bash
scoot audit show <session-id>
```

The command filters `logs/audit.jsonl` by `session_id` and prints matching events
as JSONL, preserving `seq`, `ts`, optional `run_id`, `kind`, and `msg`.

## Verbosity

Control how much is logged with `[audit] level` — `debug`, `info` (default),
`warn`, or `error`. Set `to_file = false` to disable file logging entirely.
`max_retained_generations` (default `8`) bounds how many rotated audit
generations are kept before the oldest is evicted; see [Retention](#retention).

```toml
[audit]
level = "info"
to_file = true
max_retained_generations = 8
```

## Secrets Are Never Logged

The backend token value is **never** written to sessions or the audit log — only
its *source* is ever reported (by `config`/`doctor`). Audit messages pass through
redaction before they're written. See the [Agent Guide](agent.md) secret rule.

## Retention

Session transcripts are append-oriented JSONL files. Scoot rotates an
individual session file to `.1` before appending once it reaches the built-in
size limit, keeping daemon runs from growing one file without bound; only the
latest backup is kept.

The audit log uses a sturdier scheme so a future `scoot-edge` audit shipper
can never silently lose a range (issue #187): once `logs/audit.jsonl` reaches
the size limit, it is retired to a monotonically numbered
`logs/audit.jsonl.<gen>` instead of a single clobbered `.1` backup. The
generation counter is tracked durably in a `logs/audit.jsonl.gen` sidecar so it
survives process restarts. Up to `[audit] max_retained_generations` (default
`8`) retired generations are kept on disk; only once that cap is exceeded is
the oldest evicted, and every eviction is durably recorded as
`{gap_from, gap_to, ts}` in `logs/audit.jsonl.gaps.jsonl` rather than silently
disappearing. `scoot doctor` reports `audit.retention` as `WARN` if any gap was
ever recorded, so a bounded retention cap never becomes an invisible loss.
