# Scoot Roadmap And Project Shape

This document defines what Scoot should become, what it must not become, and which engineering boundaries are non-negotiable. It is intentionally a project shape document, not a task schedule.

Chinese version: [ROADMAP.zh.md](ROADMAP.zh.md)

## Project Overview

Scoot is a lightweight AI agent daemon and CLI that runs in a plain text environment. It turns a goal or a scheduled job into auditable system-level actions: shell commands, file operations, search, and HTTP requests.

Scoot is built for system administrators, developers, and advanced technical users who want automation that is local-first, explainable, and controllable. The project bias is defensive programming: reject unsafe work, keep state local, and record what happened.

```text
                +---------------------------+
                |       User / Operator     |
                |  CLI · REPL · Daemon mode |
                +-------------+-------------+
                              |
                              v
 +-------------------------------------------+    OpenAI-compatible API    +--------------------------+
 |             Scoot Core (CLI)              | <------------------------> |        LLM Backend       |
 |  Cognitive Engine: ReACT / Plan           |  JSON Schema · strict      |     Local / Remote       |
 |  Memory: per-loop arena discipline        |   token: env/file/cmd      |                          |
 +----+---------------------------------+----+                            +--------------------------+
      |                                 |
      | skill progressive disclosure     | spawn / I/O with hard timeout
      v                                 v
 +---------------------------+    +-------------------------------------------------------+
 |        Skill Engine       |    |                  Execution Sandbox                    |
 |  discover · select · load |    |  bash · grep · glob · file_read/write/edit · http     |
 +---------------------------+    +-------------------------------------------------------+
      |                                 |
      v                                 v
 +-------------------------------+    +-------------------------------+
 |        Schedule Engine        |    |    Local State & Audit Log    |
 |        every · at             |    |    JSONL / local state        |
 +-------------------------------+    +-------------------------------+
```

## Target State

Scoot should be:

- **A single lightweight binary.** Build with the Zig toolchain and deploy by copying one executable.
- **Auditable before clever.** Every thought, tool call, observation, policy denial, final answer, and system error should be traceable.
- **Defensive by default.** Invalid model output is corrected or rejected; it is never executed directly.
- **Stable for long-running use.** A daemon must stay memory-stable and survive individual tool failures.
- **CLI-only.** Configuration files, command line commands, and plain text logs are the interface.
- **Skill-extensible without recompilation.** Users add instruction bundles under the skills directory.
- **Secret-safe.** Tokens come from environment variables, private files, or credential commands, not committed config.

Priority order:

1. Safety and controllability.
2. Stability and leak resistance.
3. Small, simple implementation.
4. Feature breadth.

## Current Capabilities

### Core Toolset

Implemented tools:

- `bash`
- `file_read`
- `file_write`
- `file_edit`
- `grep`
- `glob`
- `http_request`

Most tools are implemented in-process and do not require external `cat`, `sed`, `grep`, `find`, or `curl`. Shell execution is still available through `/bin/sh`, but it is policy-checked and timeout-bound.

### OpenAI-Compatible API Integration

Scoot targets `/v1/chat/completions` and uses strict JSON schema response formatting to force structured model steps.

Current boundaries:

- OpenAI-compatible protocol only.
- No provider-specific API glue.
- No streaming requirement.
- No dependency on backend-native tool calling.

### ReACT Loop

The agent loop asks the model for one structured step:

```json
{"thought":"...","action":"...","action_input":"..."}
```

Supported actions:

- `bash`
- `file_read`
- `file_write`
- `file_edit`
- `grep`
- `glob`
- `http_request`
- `final`

Each action is validated, policy-checked, executed through the tool layer, audited, and fed back as an observation.

### Execution Policy

Modes:

- `guarded`: interactive tripwire mode; blocks catastrophic shell patterns.
- `readonly`: fail-closed unattended mode; rejects shell and network, and allows only project-relative, non-sensitive local read built-in capabilities.
- `unrestricted`: no policy limit, still audited.

Scheduled jobs correct `guarded` to `readonly` at execution time because unattended execution must not rely on a human tripwire.

### Skills

Skills are directories containing `SKILL.md`. Discovery reads front matter (`name`, `description`, and optional review metadata such as `capabilities`, `allowed_tools`, and `scope`) and injects a compact manifest into the system context. Full skill instructions are loaded only when relevant.

Skills do not bypass policy or the tool sandbox.

### Schedule

Implemented triggers:

- `every_sec`
- `at_unix`
- 5-field UTC `cron` (minute/hour/day/month/weekday; `*`, lists, ranges, and steps)

### Daemon Lifecycle

`scoot daemon run` is the foreground long-running mode for scheduled jobs. It records `state/daemon.json` and `state/daemon.pid`, handles SIGTERM/SIGINT, and treats a stale `running` state on restart as evidence of an unclean previous stop. `daemon status` reports Scoot's last recorded lifecycle state, and `daemon stop` sends SIGTERM to the recorded pid.

### Sessions And Audit

Sessions are persisted as JSONL under `state/sessions`. Audit logs are persisted as JSONL under `logs`.

Current audit events include:

- `run`
- `thought`
- `tool_call`
- `observation`
- `policy_deny`
- `final`
- `system_error`

## Non-Goals

These are hard boundaries unless explicitly changed in the roadmap:

- No GUI, web UI, tray UI, or desktop UI.
- No provider-specific non-OpenAI protocol adapters.
- No complex cloud synchronization.
- No execution of unvalidated model output.
- No heavy runtime or native plugin system that breaks the single-binary posture.
- No plaintext secrets in committed config, binaries, logs, or audit output.
- No skill privilege escalation outside the registered tools.

## Direction

### 1. Round-Based Memory Discipline

Keep per-turn scratch allocations short-lived, and keep session history in deliberate long-lived storage. Long-running daemon behavior must remain memory-stable.

### 2. Dual Cognitive Modes

The current mode is goal-oriented ReACT. A future plan mode should produce a bounded plan or DAG first, then execute after confirmation or review.

### 3. Schedule Management

Declarative config already covers the core scheduled-job case. Future work may add CLI/REPL schedule editing, but it should not introduce unnecessary runtime state complexity.

### 4. Local Skills

Skills should remain lightweight instruction/data bundles. They should not become native binary plugins or remote code loaders.

### 5. Runtime Governance

Runtime state, config, secrets, logs, skills, and sessions should stay under one local runtime directory. Directory permissions and log lifecycle should be hardened further.

## Completion Signals

The foundation is healthy when these are observable:

- Invalid model JSON is caught and fed back without crashing.
- Tool and network calls time out reliably.
- Long-running schedule loops do not leak memory.
- A new skill can be added without recompilation.
- Audit logs can reconstruct a run.
- Secrets are never visible in config, logs, audit events, or errors.

## Near-Term Work Worth Doing

- Improve `BackendError` diagnostics with HTTP status and response excerpts.
- Add compact per-run summaries for exit code, event counts, transcript path, backend status, and policy-denial count.
- Harden runtime directory permissions.
- Add log rotation or bounded audit retention.
- Build plan mode only after ReACT reliability and diagnostics are stronger.
