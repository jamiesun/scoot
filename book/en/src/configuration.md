# Configuration

Scoot reads configuration from its runtime directory and falls back to built-in
defaults, so it runs with zero config. This page is the complete reference for
every section and key.

## File Locations & Loading Order

The runtime directory is `~/.scoot` by default. Override it with `--scoot-home`
(highest priority) or the `SCOOT_HOME` environment variable.

Within that directory, configuration is loaded in this order:

1. `config.toml`
2. `config.json`
3. built-in defaults

**Merge semantics:** loading is **per-section and per-field**. Any missing
section or field falls back to its built-in default, and **unknown fields are
ignored**. This means a partial config is always valid — you only specify what
you want to change. Start from [`config.example.toml`](https://github.com/jamiesun/scoot/blob/main/config.example.toml).

Run `scoot config` at any time to print the *resolved* runtime directory and
backend configuration (with secrets redacted).

## Environment Variable Overrides

Every non-secret config field can be overridden by a `SCOOT_*` environment
variable. The overlay is applied **in memory** with precedence:

```text
SCOOT_* environment  >  config.toml / config.json  >  built-in defaults
```

Environment values **always win**, whether or not a config file exists, so you
can run Scoot with **no config file at all** — point `SCOOT_HOME` at a throwaway
directory and pass everything through the environment. This is ideal for CI and
ephemeral, run-once-then-discard execution.

| Environment variable | Overrides | Type |
| --- | --- | --- |
| `SCOOT_BACKEND_BASE_URL` | `backend.base_url` | string |
| `SCOOT_BACKEND_MODEL` | `backend.model` | string |
| `SCOOT_BACKEND_TIMEOUT_MS` | `backend.timeout_ms` | integer |
| `SCOOT_BACKEND_API_KEY_ENV` | `backend.api_key_env` | string (names the var holding the token) |
| `SCOOT_BACKEND_API_KEY_FILE` | `backend.api_key_file` | string |
| `SCOOT_BACKEND_API_KEY_CMD` | `backend.api_key_cmd` | string |
| `SCOOT_BACKEND_CA_FILE` | `backend.ca_file` | string |
| `SCOOT_BACKEND_STORE` | `backend.store` | bool (`true`/`false`/`1`/`0`) |
| `SCOOT_BACKEND_EXTRA_BODY` | `backend.extra_body` | JSON object |
| `SCOOT_AGENT_DEFAULT_MODE` | `agent.default_mode` | string (`goal`/`plan`) |
| `SCOOT_AGENT_COMPACTOR` | `agent.compactor` | string (`drop`/`extractive`/`plugin:<name>`) |
| `SCOOT_AGENT_MAX_TURNS` | `agent.max_turns` | integer |
| `SCOOT_AGENT_CONTEXT_BUDGET_BYTES` | `agent.context_budget_bytes` | integer |
| `SCOOT_TOOLS_POLICY` | `tools.policy` | string (`guarded`/`readonly`/`unrestricted`) |
| `SCOOT_TOOLS_TIMEOUT_MS` | `tools.timeout_ms` | integer |
| `SCOOT_TOOLS_CONFINE_WRITES` | `tools.confine_writes` | bool (`true`/`false`/`1`/`0`) |
| `SCOOT_TOOLS_BLOCK_INTERNAL_HTTP` | `tools.block_internal_http` | bool |
| `SCOOT_SKILLS_ENABLED` | `skills.enabled` | bool |
| `SCOOT_SKILLS_INCLUDE_PROJECT_SKILLS` | `skills.include_project_skills` | bool |
| `SCOOT_SKILLS_INCLUDE_AGENTS_SKILLS` | `skills.include_agents_skills` | bool |
| `SCOOT_AUDIT_LEVEL` | `audit.level` | string |
| `SCOOT_AUDIT_TO_FILE` | `audit.to_file` | bool |

Notes:

- An **empty** value (`""`) is treated as *unset* and does not override the
  default — convenient for optional CI inputs.
- A value of the **wrong type** (e.g. a non-integer for `SCOOT_AGENT_MAX_TURNS`)
  is **ignored**, the field keeps its previous value, and a warning is printed to
  **stderr** (never stdout, so `-e` piping stays clean).
- **Secrets are never read from `SCOOT_*` directly.** The token still comes only
  from the source named by `backend.api_key_env` (default `OPENAI_API_KEY`), per
  the [Secrets](#secrets) rule below. `SCOOT_BACKEND_API_KEY_ENV` only changes
  *which* variable is consulted, not the token itself.

### Zero-config run in GitHub Actions

Store the token as a GitHub **secret** and pass the rest through `env`. No
`config.toml` is committed or written; the runtime directory is created on the
fly under the runner's temp space and discarded with the job.

```yaml
jobs:
  ask:
    runs-on: ubuntu-latest
    env:
      SCOOT_HOME: ${{ runner.temp }}/scoot
      OPENAI_API_KEY: ${{ secrets.LLM_KEY }}        # token value (secret)
      SCOOT_BACKEND_API_KEY_ENV: OPENAI_API_KEY     # which var holds it
      SCOOT_BACKEND_BASE_URL: https://api.openai.com/v1
      SCOOT_BACKEND_MODEL: gpt-4o-mini
      SCOOT_TOOLS_POLICY: readonly                  # safe default for CI
    steps:
      - uses: actions/checkout@v4
      - name: Install scoot
        run: |
          # download a release asset for your platform, then:
          install -m755 scoot /usr/local/bin/scoot
      - name: Ask
        run: scoot -e "Summarize the latest changes in this repository"
```

`scoot -e` checks `SCOOT_HOME`: if the directory is missing it is created with
built-in defaults; if it already exists, the `SCOOT_*` overlay is applied on top.
Either way no secret is ever written to disk.

## Sections At A Glance

| Section | Purpose |
| --- | --- |
| `[backend]` | LLM endpoint, model, API-key source, TLS, extra request fields |
| `[agent]` | ReACT turn limit, cognition mode, context budget, compactor plugins |
| `[tools]` | Tool timeout, execution policy, guarded hardening |
| `[skills]` | Skill discovery toggle and extra search paths |
| `[mcp]` | External MCP server declarations for `mcp_call` |
| `[audit]` | Audit log level and file output |
| `[schedule]` | Unattended scheduled jobs and the poll interval |

---

## `[backend]`

The LLM backend. Scoot speaks **only** the OpenAI-compatible Responses API
(`/v1/responses`).
By default Scoot resends the full `input` each turn so local context compaction
stays effective and token use stays bounded.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `base_url` | string | `http://127.0.0.1:11434/v1` | OpenAI-compatible endpoint base URL. |
| `model` | string | `qwen2.5` | Model name sent to the backend. |
| `timeout_ms` | u64 | `120000` | Hard timeout for one backend Responses API call, in milliseconds. `0` is coerced to the built-in default, never to “no deadline”. |
| `api_key_env` | string | `OPENAI_API_KEY` | Environment variable used as the **first** token source. |
| `api_key_file` | string? | unset → `~/.scoot/token` | Path to a `0600` token file. Used after the env source. |
| `api_key_cmd` | string? | unset | Command that prints a token (e.g. `pass show openai`). Used last. Treat as trusted config because it is executed by Scoot. |
| `ca_file` | string? | unset → system roots | PEM CA bundle for HTTPS. Set this on systems lacking root certs. |
| `store` | bool | `false` | Ask the backend to persist the response server-side via the Responses API `store` flag. Off by default to keep scoot stateless and local-first. |
| `extra_body` | table? | unset | Extra top-level JSON fields merged into every request. |

### `[backend.extra_body]`

A pass-through table merged verbatim into the top-level model request JSON.
Use it for backend-specific or newer fields without recompiling — e.g.
`reasoning_effort`, `service_tier`, `top_p`. Only a JSON **object** is accepted;
non-object values are ignored. **Never put secrets here**, and do not override
core fields like `model`, `messages`, or `input`.

```toml
[backend]
base_url = "https://api.openai.com/v1"
model    = "gpt-4o-mini"
# store = false
api_key_env = "OPENAI_API_KEY"

[backend.extra_body]
top_p = 0.9
reasoning_effort = "high"
```

---

## `[agent]`

The cognition engine.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `max_turns` | u32 | `32` | Maximum ReACT turns before the agent stops, to bound runaway loops. |
| `default_mode` | string | `goal` | Cognition mode. `goal` is implemented today; `plan` is reserved (see Roadmap) and does not yet change execution. |
| `compactor` | string | `extractive` | Context compaction strategy: `extractive` writes a deterministic summary; `drop` keeps the old count marker; `plugin:<name>` runs an external compressor package. |
| `context_budget_bytes` | usize | `80000` | Cumulative prompt-history budget in **bytes**. `0` disables it. |
| `compactor_plugin` | table | unset | Dynamic plugin configs keyed by name under `[agent.compactor_plugin.<name>]`. |

**`context_budget_bytes`** guards small-context backends. When the running
transcript would exceed this size, the agent first **compacts history** —
keeping the system prompt, the original task, and the most recent turns while
using `agent.compactor`. The default `extractive` strategy keeps a deterministic
navigation summary, such as files read or changed, commands and exit codes,
policy denials, and obvious TODO-like observations. `drop` is the smallest
fallback behavior: it replaces older tool transcripts with a short count marker.
`plugin:<name>` runs the configured external compressor first, but falls back to
`extractive` and then `drop` if the package is invalid, policy-denied, times
out, returns malformed output, or produces a marker that would still exceed the
budget.
It only fails fast (with a clear error) *before* the next backend call if the
transcript is still over budget after compaction (the budget is too small for
even the minimal retained context). Bytes are a coarse proxy for tokens. The
default is a conservative guardrail, not an exact model-window guarantee; set it
below your backend's context window, or set it to `0` to disable this check
(turn count is still bounded by `max_turns`).

```toml
[agent]
max_turns = 32
default_mode = "goal"
compactor = "extractive"          # or "drop"
context_budget_bytes = 80000      # 0 disables; tune below your backend window
```

### `[agent.compactor_plugin.<name>]`

External compressor plugins use the same static package descriptor boundary as
Wasm tool packages, but `manifest.toml` must set `kind = "compressor"`. Scoot
does not embed a Wasm runtime; compression is performed by a bounded child
process. The plugin receives a JSON `CompactionRequest` on stdin and must print
a JSON object such as `{"marker":"..."}` on stdout.

The package policy must grant only `compute`. Any non-`compute` capability, bad
output, timeout, non-zero exit, or over-budget marker is treated as unusable and
falls through to the built-in fallback chain.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `package` | string | required | Directory validated by `wasm_tool.validatePackage`. |
| `host` | list of string | unset | Command argv template. Placeholders: `{package}`, `{component}`, `{entry}`. If unset, Scoot tries `{package}/{entry}`. |
| `timeout_ms` | u64? | `tools.timeout_ms` | Hard child-process timeout. `0` is coerced to the built-in default, never to “no deadline”. |
| `stdout_limit` | usize? | `1048576` | Maximum stdout bytes accepted from the plugin. |
| `stderr_limit` | usize? | `262144` | Maximum stderr bytes accepted from the plugin. |

Use `scoot-wasm wasi {component}` when the optional standalone host is installed
on `PATH` (or replace `scoot-wasm` with its absolute path):

```toml
[agent]
compactor = "plugin:tiny"

[agent.compactor_plugin.tiny]
package = "/opt/scoot/compressors/tiny"
host = ["scoot-wasm", "wasi", "{component}"]
timeout_ms = 30000
stdout_limit = 1048576
stderr_limit = 262144
```

---

## `[tools]`

The tool sandbox and execution policy. See [Execution Policy & Security](policy.md)
for the full model.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `timeout_ms` | u64 | `30000` | Hard timeout for **every** tool call, in milliseconds. |
| `policy` | string | `guarded` | Execution policy: `guarded`, `readonly`, or `unrestricted` (alias `yolo`). Unknown values fall back to `guarded`. |
| `confine_writes` | bool | `true` | Keep `file_write`/`file_edit` inside the project root. **`guarded` only.** |
| `block_internal_http` | bool | `true` | Block `http_request` to internal/metadata hosts (SSRF guard). **`guarded` only.** |
| `wasm_host` | string array | `["scoot-wasm", "wasi", "{component}"]` | Trusted argv used by `wasm_tool`. With the default, Scoot first tries a sibling `scoot-wasm` next to the running `scoot` binary, then falls back to PATH. Placeholders: `{package}`, `{entry}`, `{component}`. |

Both hardening flags apply **only in `guarded` mode** — `readonly` already
fail-closes writes and network. `confine_writes` rejects absolute paths, `..`
escapes, and shell-style `~`/`$VAR` expansion. `block_internal_http` is a
heuristic over literal IP ranges and known internal names; it does **not**
resolve DNS, so DNS-rebinding can still bypass it — use `readonly` or a network
sandbox for real isolation.

```toml
[tools]
timeout_ms = 30000
policy = "guarded"
confine_writes = true
block_internal_http = true
wasm_host = ["./zig-out/bin/scoot-wasm", "wasi", "{component}"]
```

### `[tools.policy_hook]` (opt-in)

Optional external policy hook consulted after the built-in gate allows an action;
it can only tighten `allow`→`deny`, never relax a built-in deny, and fails closed
on any error. Off unless `package` is set. See [Execution Policy](policy.md#policy-hook-opt-in-defense-in-depth).

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `package` | string | _(empty)_ | Local Wasm tool package (manifest kind `policy`, compute-only). Empty = no hook. |
| `host` | string array | resolved `wasm_host` | argv template. Placeholders: `{package}`, `{entry}`, `{component}`. |
| `timeout_ms` | u64 | `tools.timeout_ms` | Hard per-call timeout for the hook. |

```toml
[tools.policy_hook]
package = "/opt/scoot/policy/org-guard"
host = ["scoot-wasm", "wasi", "{component}"]
timeout_ms = 5000
```

---

## `[skills]`

Local skill discovery. See [Skills](skills.md).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Enable skill discovery and injection. |
| `include_project_skills` | bool | `false` | Include `<cwd>/.agents/skills`, the repository-carried skill directory. Enable only for repositories you trust. |
| `include_agents_skills` | bool | `false` | Include `~/.agents/skills`, the cross-agent user-level skill directory. |
| `extra_paths` | list of string | `[]` | Additional skill search paths, appended after the built-in ones. |

Skills are discovered in **priority order** (earlier wins on name collision):

1. `<cwd>/.agents/skills` — project-local, only when `include_project_skills=true`.
2. `~/.agents/skills` — cross-agent user-level skills, only when `include_agents_skills=true`.
3. `~/.scoot/skills` — Scoot's own user-level directory.
4. the `extra_paths` listed here.

Project-local skills are disabled by default because repositories can carry
untrusted instructions. Opt in per trusted workspace.

Reading a skill's instructions is a native, read-only capability that works even
in `readonly` mode; what a skill then tells the model to run is still
policy-gated.

```toml
[skills]
enabled = true
include_project_skills = false
include_agents_skills = false
extra_paths = ["/opt/scoot/skills", "./skills"]
```

---

## `[mcp]`

External Model Context Protocol servers callable through the `mcp_call`
meta-action. MCP is client-only: Scoot launches or connects to configured
servers and calls their tools, but it does not expose a server.

Calls fail closed. The target `server` must exist in `[[mcp.servers]]`, and the
requested `tool` must be listed in `allowed_tools`; an empty `allowed_tools`
list denies every tool. `readonly` policy denies `mcp_call` entirely because
external MCP tools can read, write, or reach networks outside Scoot's static
tool classes. `guarded` and `unrestricted` still require the explicit server and
tool allowlist.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `servers` | array | `[]` | MCP server declarations. |

Each `[[mcp.servers]]` entry:

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | string | `""` | Name used by `mcp_call.server`. |
| `transport` | string | `stdio` | Supported transports: `stdio`, Streamable HTTP (`http` / `streamable_http`), and legacy `sse`. |
| `command` | string | `""` | Command to launch for stdio transport. |
| `args` | list of string | `[]` | Arguments for `command`. |
| `env` | list of `{ name, value }` | `[]` | Environment override block for the child process. If set, include everything the child needs, such as `PATH`. |
| `allowed_tools` | list of string | `[]` | Explicit tool allowlist. Empty means deny all. |
| `policy` | string | `readonly` | Declarative server posture for audit and future policy expansion. |
| `url` | string? | unset | Remote endpoint URL for HTTP/SSE transports. |
| `headers` | list of header objects | `[]` | Extra HTTP headers for remote transports. Use `value_env` for secrets. |

Header objects support `name`, exactly one of `value` or `value_env`, and an
optional `prefix`. Protocol headers such as `Accept`, `Content-Type`,
`MCP-Protocol-Version`, and `Mcp-Session-Id` are owned by Scoot and cannot be
overridden. If a `value_env` variable is missing or empty, the call fails closed.

```toml
[[mcp.servers]]
name = "demo"
transport = "stdio"
command = "/path/to/mcp-server"
args = ["--flag", "value"]
env = [{ name = "SERVER_MODE", value = "readonly" }]
allowed_tools = ["lookup", "read_resource"]
policy = "readonly"

[[mcp.servers]]
name = "remote-demo"
transport = "http"
url = "https://example.com/mcp"
allowed_tools = ["lookup"]
headers = [
  { name = "Authorization", value_env = "REMOTE_MCP_TOKEN", prefix = "Bearer " },
]

[[mcp.servers]]
name = "legacy-sse-demo"
transport = "sse"
url = "https://example.com/sse"
allowed_tools = ["lookup"]
headers = [
  { name = "X-API-Key", value_env = "REMOTE_MCP_API_KEY" },
]
```

---

## `[audit]`

Audit logging. See [Sessions & Audit](sessions.md).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `level` | string | `info` | Verbosity: `debug`, `info`, `warn`, or `error`. |
| `to_file` | bool | `true` | Write audit logs to `~/.scoot/logs/audit.jsonl`. |

```toml
[audit]
level = "info"
to_file = true
```

### `[audit.hook]` (opt-in)

Optional PostToolUse-style observability hook. After a tool action completes —
either executed (allowed) or denied by the policy gate — it receives a structured
JSON event for an external SIEM, analytics pipeline, or org audit engine. Like the
[policy hook](#toolspolicy_hook-opt-in), it runs the event through the same
realpath-validated Wasm data-transform boundary (manifest kind `audit`,
compute-only) rather than a raw shell callout. It is purely **observational**: it
never gates execution and has no allow/deny return, and delivery is **best-effort**
— any failure (missing/invalid package, wrong kind, non-compute capability, spawn
failure, timeout, oversized output, non-zero exit) is counted and surfaced as a
warning at flush, never fatal to the run. Off unless `package` is set.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `package` | string | _(empty)_ | Local Wasm tool package (manifest kind `audit`, compute-only). Empty = no hook. |
| `host` | string array | resolved `wasm_host` | argv template. Placeholders: `{package}`, `{entry}`, `{component}`. |
| `timeout_ms` | u64 | `tools.timeout_ms` | Hard per-call timeout for the hook. |

The event is one JSON object per line on the hook's stdin:

```json
{"version":1,"kind":"observation","session_id":"cli-...","action":"bash","input":"<tool input>","observation":"<tool result>","mode":"guarded"}
```

`kind` is `observation` for an executed tool or `policy_deny` for a gated one.

```toml
[audit.hook]
package = "/opt/scoot/audit/org-sink"
host = ["scoot-wasm", "wasi", "{component}"]
timeout_ms = 5000
```

---

## `[schedule]`

Unattended scheduled jobs. **Disabled by default** — autonomous execution must
be explicitly enabled. See [Scheduling & Daemon](scheduling.md).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | Enable the scheduler / daemon loop. |
| `poll_ms` | u64 | `1000` | Scheduler polling interval, in milliseconds. |
| `jobs` | list of table | `[]` | Scheduled job definitions (see below). |

### `[[schedule.jobs]]`

Each job is an array-of-tables entry with **exactly one** trigger.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `id` | string | — | Stable job identifier (required). |
| `goal` | string | `""` | The natural-language goal the agent runs. |
| `every_sec` | u64? | unset | Trigger: fixed interval in seconds. |
| `at_unix` | i64? | unset | Trigger: a fixed Unix-time instant. |
| `cron` | string? | unset | Trigger: 5-field UTC cron expression. |
| `mode` | string | `readonly` | Execution policy: `readonly` (default, safe) or `unrestricted`. |

**Exactly one** of `every_sec` / `at_unix` / `cron` must be set; otherwise the
job is invalid and skipped with a warning. Cron supports minute/hour/day/month/
weekday fields with `*`, comma lists, ranges, and `/step`.

**Safety:** scheduled jobs default to `readonly`, and `guarded` is coerced to
effective `readonly` at execution time. Use `unrestricted` only with deliberate
acceptance of unattended write/network risk.

```toml
[schedule]
enabled = true
poll_ms = 1000

[[schedule.jobs]]
id = "disk-check"
goal = "Inspect disk usage and summarize anomalies"
every_sec = 300
mode = "readonly"

[[schedule.jobs]]
id = "morning-brief"
goal = "Prepare today's task brief"
at_unix = 1893456000
mode = "readonly"
```

---

## Secrets

**Never put a plaintext API key in `config.toml`/`config.json`.** Scoot resolves
the backend token from three sources, tried in order:

1. **Environment variable** named by `backend.api_key_env` (default `OPENAI_API_KEY`).
2. **Token file** at `backend.api_key_file`, or `~/.scoot/token` if unset. The
   file **must be mode `0600`**; Scoot refuses to read it if permissions are too
   open.
3. **Credential command** in `backend.api_key_cmd` (e.g. `pass show openai`).
   Keep it bounded and non-interactive.

The resolved value is never written back to disk, printed by `config`/`doctor`,
or recorded in audit logs — only the *source* is reported. See the [Agent
Guide](agent.md) for the secret-handling iron rule.

```sh
# Source 1 — environment:
export OPENAI_API_KEY="sk-..."

# Source 2 — private token file:
umask 077
printf '%s' "sk-..." > ~/.scoot/token

# Source 3 — credential command (in config):
#   api_key_cmd = "pass show openai"
```

## JSON Configuration

If you prefer JSON, create `config.json` in the runtime directory (used only
when `config.toml` is absent). The structure mirrors the TOML sections:

```json
{
  "backend": { "base_url": "https://api.openai.com/v1", "model": "gpt-4o-mini" },
  "agent":   { "max_turns": 32 },
  "tools":   { "policy": "guarded", "timeout_ms": 30000 }
}
```

## Annotated Example

The repository ships a fully commented [`config.example.toml`](https://github.com/jamiesun/scoot/blob/main/config.example.toml).
Copy it and edit:

```sh
cp config.example.toml ~/.scoot/config.toml
```
