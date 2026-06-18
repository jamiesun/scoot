# Sessions & Audit

Scoot persists what it does as **append-only JSONL** on local disk — short-term
session transcripts and a step-by-step audit log. Both are plain text and easy to
replay, grep, or pipe into other tools. There is **no** long-term semantic memory
or vector database by design (see the [Roadmap](roadmap.md)).

## Sessions

A session is the message transcript of a single interaction (one `-e` run, one
REPL conversation, or one scheduled job). It is persisted to:

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

Sessions are short-term memory only. They are not indexed or summarized across
runs; persistence is for auditability and inspection, not recall.

## Audit Log

Every meaningful step is recorded to the audit log when `[audit] to_file = true`
(the default):

```text
~/.scoot/logs/audit.jsonl
```

Each line is one event:

```json
{"seq":0,"ts":1718600000123,"kind":"run","msg":"goal: count the Zig files"}
{"seq":1,"ts":1718600000456,"kind":"thought","msg":"..."}
{"seq":2,"ts":1718600000789,"kind":"tool_call","msg":"glob {\"pattern\":\"**/*.zig\"}"}
{"seq":3,"ts":1718600000900,"kind":"observation","msg":"..."}
{"seq":4,"ts":1718600001000,"kind":"final","msg":"There are 23 Zig files."}
```

| Field | Meaning |
| --- | --- |
| `seq` | Monotonic event sequence number (per logger instance, from 0). |
| `ts` | Wall-clock timestamp, Unix **milliseconds**. |
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

## Verbosity

Control how much is logged with `[audit] level` — `debug`, `info` (default),
`warn`, or `error`. Set `to_file = false` to disable file logging entirely.

```toml
[audit]
level = "info"
to_file = true
```

## Secrets Are Never Logged

The backend token value is **never** written to sessions or the audit log — only
its *source* is ever reported (by `config`/`doctor`). Audit messages pass through
redaction before they're written. See the [Agent Guide](agent.md) secret rule.

## Retention

Session and audit files are append-oriented JSONL files. Scoot rotates an
individual JSONL file to `.1` before appending once it reaches the built-in size
limit, keeping daemon runs from growing one file without bound.
