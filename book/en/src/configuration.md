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
| `SCOOT_BACKEND_API_KEY_ENV` | `backend.api_key_env` | string (names the var holding the token) |
| `SCOOT_BACKEND_API_KEY_FILE` | `backend.api_key_file` | string |
| `SCOOT_BACKEND_API_KEY_CMD` | `backend.api_key_cmd` | string |
| `SCOOT_BACKEND_CA_FILE` | `backend.ca_file` | string |
| `SCOOT_BACKEND_PROMPT_CACHE` | `backend.prompt_cache` | string (`off` / `anthropic`) |
| `SCOOT_BACKEND_EXTRA_BODY` | `backend.extra_body` | JSON object |
| `SCOOT_AGENT_DEFAULT_MODE` | `agent.default_mode` | string (`goal`/`plan`) |
| `SCOOT_AGENT_MAX_TURNS` | `agent.max_turns` | integer |
| `SCOOT_AGENT_CONTEXT_BUDGET_BYTES` | `agent.context_budget_bytes` | integer |
| `SCOOT_TOOLS_POLICY` | `tools.policy` | string (`guarded`/`readonly`/`unrestricted`) |
| `SCOOT_TOOLS_TIMEOUT_MS` | `tools.timeout_ms` | integer |
| `SCOOT_TOOLS_CONFINE_WRITES` | `tools.confine_writes` | bool (`true`/`false`/`1`/`0`) |
| `SCOOT_TOOLS_BLOCK_INTERNAL_HTTP` | `tools.block_internal_http` | bool |
| `SCOOT_SKILLS_ENABLED` | `skills.enabled` | bool |
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
| `[agent]` | ReACT turn limit, cognition mode, context budget |
| `[tools]` | Tool timeout, execution policy, opt-in hardening |
| `[skills]` | Skill discovery toggle and extra search paths |
| `[audit]` | Audit log level and file output |
| `[schedule]` | Unattended scheduled jobs and the poll interval |

---

## `[backend]`

The LLM backend. Scoot speaks **only** the OpenAI-compatible `chat/completions`
protocol.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `base_url` | string | `http://127.0.0.1:11434/v1` | OpenAI-compatible endpoint base URL. |
| `model` | string | `qwen2.5` | Model name sent to the backend. |
| `api_key_env` | string | `OPENAI_API_KEY` | Environment variable used as the **first** token source. |
| `api_key_file` | string? | unset → `~/.scoot/token` | Path to a `0600` token file. Used after the env source. |
| `api_key_cmd` | string? | unset | Command that prints a token (e.g. `pass show openai`). Used last. |
| `ca_file` | string? | unset → system roots | PEM CA bundle for HTTPS. Set this on systems lacking root certs. |
| `prompt_cache` | string | `off` | Prompt-cache hint mode: `off` or `anthropic`. See below. |
| `extra_body` | table? | unset | Extra top-level JSON fields merged into every request. |

### `prompt_cache`

Controls whether the request body carries a prompt-cache breakpoint so the
**stable instruction prefix** (the leading `system` block — system prompt, tool
docs, skill list; re-sent every turn) bills at the cache rate instead of being
recomputed at full price each turn.

- `off` (default) — no cache markers; the request body is **byte-identical** to
  the legacy shape. OpenAI / vLLM / SGLang auto-cache stable prefixes, so leave
  it off (and avoid strict backends rejecting unknown fields).
- `anthropic` — tag the leading `system` block's content with an Anthropic-style
  `cache_control: {type: ephemeral}` breakpoint. Enable **only** on
  Anthropic-compatible gateways. Unknown values fall back to `off`.

### `[backend.extra_body]`

A pass-through table merged verbatim into the top-level `chat/completions` JSON.
Use it for backend-specific or newer fields without recompiling — e.g.
`reasoning_effort`, `service_tier`, `top_p`. Only a JSON **object** is accepted;
non-object values are ignored. **Never put secrets here**, and do not override
core fields like `model` or `messages`.

```toml
[backend]
base_url = "https://api.openai.com/v1"
model    = "gpt-4o-mini"
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
| `context_budget_bytes` | usize | `0` | Cumulative prompt-history budget in **bytes**. `0` disables it. |

**`context_budget_bytes`** guards small-context backends. When the running
transcript would exceed this size, the agent first **compacts history** —
keeping the system prompt, the original task, and the most recent turns while
replacing older tool transcripts with a short summary marker — so a long run can
continue instead of aborting. It only fails fast (with a clear error) *before*
the next backend call if the transcript is still over budget after compaction
(the budget is too small for even the minimal retained context). Bytes are a
coarse proxy for tokens — pick a conservative value below your backend's context
window (turn count is still bounded by `max_turns`).

```toml
[agent]
max_turns = 32
default_mode = "goal"
context_budget_bytes = 0          # e.g. 120000 for a ~32k-token backend
```

---

## `[tools]`

The tool sandbox and execution policy. See [Execution Policy & Security](policy.md)
for the full model.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `timeout_ms` | u64 | `30000` | Hard timeout for **every** tool call, in milliseconds. |
| `policy` | string | `guarded` | Execution policy: `guarded`, `readonly`, or `unrestricted` (alias `yolo`). Unknown values fall back to `guarded`. |
| `confine_writes` | bool | `false` | Opt-in: keep `file_write`/`file_edit` inside the project root. **`guarded` only.** |
| `block_internal_http` | bool | `false` | Opt-in: block `http_request` to internal/metadata hosts (SSRF guard). **`guarded` only.** |

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
confine_writes = false
block_internal_http = false
```

---

## `[skills]`

Local skill discovery. See [Skills](skills.md).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Enable skill discovery and injection. |
| `include_agents_skills` | bool | `false` | Include `~/.agents/skills`, the cross-agent user-level skill directory. |
| `extra_paths` | list of string | `[]` | Additional skill search paths, appended after the built-in ones. |

Skills are discovered in **priority order** (earlier wins on name collision):

1. `<cwd>/.agents/skills` — project-local, travels with the repository.
2. `~/.agents/skills` — cross-agent user-level skills, only when `include_agents_skills=true`.
3. `~/.scoot/skills` — Scoot's own user-level directory.
4. the `extra_paths` listed here.

Reading a skill's instructions is a native, read-only capability that works even
in `readonly` mode; what a skill then tells the model to run is still
policy-gated.

```toml
[skills]
enabled = true
include_agents_skills = false
extra_paths = ["/opt/scoot/skills", "./skills"]
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
