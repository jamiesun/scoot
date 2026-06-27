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
  |  discover · select · load |    |  bash · file · search · http · MCP · Wasm host shim    |
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

Implemented actions/tools:

- `bash`
- `file_read`
- `file_write`
- `file_edit`
- `grep`
- `glob`
- `outline`
- `http_request`
- `skill`
- `recall`
- bounded read-only `parallel`
- `mcp_call`
- `wasm_tool`

Core file, search, outline, and HTTP tools are implemented in-process and do not require external `cat`, `sed`, `grep`, `find`, or `curl`. Shell execution is still available through `/bin/sh`, but it is policy-checked and timeout-bound. `mcp_call` is a configured client boundary, and `wasm_tool` runs compute-only local packages through a configured `scoot-wasm` host argv rather than through broad shell command synthesis.

### OpenAI-Compatible API Integration

Scoot speaks only the OpenAI-compatible Responses API (`/v1/responses`). Leading system messages are sent as the top-level `instructions` field; the rest become the `input` array, with strict JSON schema response formatting to force structured model steps. Transport is stateless by default (`store=false`, full `input` resent each turn), which keeps local context compaction in control. Local servers that serve this API include Ollama >= 0.13.3 and vLLM.

Current boundaries:

- OpenAI-compatible Responses API (`/v1/responses`) only; Chat Completions has been removed.
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
- `outline`
- `http_request`
- `mcp_call`
- `wasm_tool`
- `skill`
- `recall`
- `parallel`
- `final`

Each action is schema-constrained, argument-parsed, policy-checked where appropriate, executed through the tool layer or native read-only boundary, audited, and fed back as an observation. Tool observations are treated as untrusted data and must not become instructions.

### Execution Policy

Modes:

- `guarded`: interactive tripwire mode; blocks catastrophic shell patterns and applies default-on write confinement plus internal HTTP target blocking.
- `readonly`: fail-closed unattended mode; rejects shell, writes, and network, and allows only project-relative, non-sensitive local read built-in capabilities plus compute-only boundaries.
- `unrestricted`: no policy limit, still audited.

Scheduled jobs correct `guarded` to `readonly` at execution time because unattended execution must not rely on a human tripwire. `guarded` is not a sandbox; strong isolation remains an OS/deployment concern.

### Skills

Skills are directories containing `SKILL.md`. Discovery reads front matter (`name`, `description`, and optional review metadata such as `capabilities`, `allowed_tools`, and `scope`) and injects a compact manifest into the system context. Full skill instructions and resources are loaded only when relevant through the native read-only `skill` action, confined to the selected skill directory and audited.

Skills do not bypass policy or the tool sandbox. Reading instructions is native and read-only so it works in `readonly`; any skill-requested shell, write, network, MCP, or Wasm action still goes through the normal registered tool boundary.

### Schedule

Implemented triggers:

- `every_sec`
- `at_unix`
- 5-field UTC `cron` (minute/hour/day/month/weekday; `*`, lists, ranges, and steps)

### Daemon Lifecycle And Local App-Server Mode

`scoot daemon run` is the foreground long-running mode for scheduled jobs. It records `state/daemon.json` and `state/daemon.pid`, handles SIGTERM/SIGINT, and treats a stale `running` state on restart as evidence of an unclean previous stop. `daemon status` reports Scoot's last recorded lifecycle state, and `daemon stop` sends SIGTERM only when the pid file and running state agree.

`scoot serve` is a foreground stdio NDJSON protocol for local app integrations. It remains CLI/text I/O rather than a GUI or web service, and exposes run/session/audit methods over local stdin/stdout.

### Sessions, Recall, Audit, And Embedding

Sessions are persisted as JSONL under `state/sessions`. The native `recall` action retrieves exact earlier messages from the current session transcript when active context has been compacted. Audit logs are persisted as JSONL under `logs` and can be queried through CLI/serve paths.

The public Zig package root is intentionally narrow: an opaque `Runtime`, `Options`, `start`, `run`, `stop`, and `version`. Internal modules are exported through `src/internal.zig` for CLI/repository tests, not through the stable package root.

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
- No remote plugin registry or remote code-loading path for skills or Wasm packages.
- No plaintext secrets in committed config, binaries, logs, or audit output.
- No skill privilege escalation outside the registered tools.
- No broad public package-root export of private subsystems without an explicit API-boundary decision.

## Direction

### 1. Round-Based Memory Discipline

Keep per-turn scratch allocations short-lived, and keep session history in deliberate long-lived storage. Long-running daemon behavior must remain memory-stable.

### 2. Dual Cognitive Modes

The current mode is goal-oriented ReACT. A future plan mode should produce a bounded plan or DAG first, then execute after confirmation or review.

### 3. Schedule Management

Declarative config already covers the core scheduled-job case. Future work may add CLI/REPL schedule editing, but it should not introduce unnecessary runtime state complexity.

### 4. Local Skills

Skills should remain lightweight instruction/data bundles. They should not become native binary plugins or remote code loaders.

### 5. Optional Tool Boundaries

MCP and Wasm are extension seams, not excuses to grow an unbounded trusted core. MCP calls must remain configuration-gated with explicit allowed tools and hard timeouts. Wasm execution must stay outside the core binary unless explicitly built as the standalone `scoot-wasm` host, with compute-only package policy for the native Agent action.

### 6. Runtime Governance

Runtime state, config, secrets, logs, skills, and sessions should stay under one local runtime directory. Directory permissions, log lifecycle, and audit/query ergonomics should remain part of the safety posture.

## Completion Signals

The foundation is healthy when these are observable:

- Invalid model JSON is caught and fed back without crashing.
- Tool, MCP, Wasm-host, subprocess, and network calls time out reliably.
- Long-running schedule and serve loops do not leak memory.
- A new skill can be added without recompilation.
- Optional extension seams remain configuration-gated and auditable.
- Audit logs can reconstruct a run.
- Secrets are never visible in config, logs, audit events, or errors.
- The public package root stays small and intentionally stable.

## Near-Term Work Worth Doing

- Keep backend and run diagnostics actionable: HTTP status, response excerpts, run summaries, transcript/audit paths, and policy-denial counts should remain easy to inspect.
- Audit optional boundaries (`mcp_call`, `wasm_tool`, external compressor plugins, and `serve`) for total timeouts, bounded output, secret redaction, and request-scoped allocation.
- Keep English/Chinese docs and mdBook pages aligned with the actual action set and stable API boundary.
- Continue hardening runtime governance: permissions, bounded retention, audit query ergonomics, and failure-mode clarity.
- Build plan mode only after ReACT reliability, diagnostics, and extension-boundary audits are stronger.
