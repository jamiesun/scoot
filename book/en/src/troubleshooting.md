# Troubleshooting & FAQ

When something doesn't work, run `scoot doctor` first — it checks the runtime
directory, config source, secret source, skill discovery, schedule status, and
the audit path without printing any secrets.

## Diagnostic Commands

```sh
scoot doctor                         # local health checks
scoot config                         # resolved runtime dir + backend (redacted)
scoot --trace -e "your goal"         # full ReACT trace on stderr
scoot policy check <action> <input> --mode <mode>   # why was this allowed/denied?
```

## Common Problems

### "No home directory" / wrong runtime directory

Scoot needs `$HOME` (or `SCOOT_HOME`) to locate `~/.scoot`. In minimal
environments where `$HOME` is unset, pass `--scoot-home`:

```sh
scoot --scoot-home /var/lib/scoot doctor
```

`--scoot-home` always wins over `SCOOT_HOME`. Run `scoot config` to confirm which
directory is actually in use.

### Backend authentication fails / no token

Scoot resolves the token from env → `0600` token file → credential command. Check
which source `doctor` reports, then:

- ensure `OPENAI_API_KEY` (or your `api_key_env`) is exported in the same shell;
- if using a token file, it **must be mode `0600`** or Scoot refuses it:
  `chmod 600 ~/.scoot/token`;
- if using `api_key_cmd`, confirm the command prints the token and is
  non-interactive.

Never put the key in `config.toml`. See [Configuration → Secrets](configuration.md#secrets).

### TLS / certificate errors on HTTPS backends

Minimal/embedded images often lack system root certificates. Point `ca_file` at a
PEM bundle:

```toml
[backend]
ca_file = "/etc/ssl/certs/ca-certificates.crt"
```

### "Connection refused" to the backend

The default `base_url` is a local Ollama endpoint (`http://127.0.0.1:11434/v1`).
If you don't run Ollama, set `base_url`/`model` to your real backend. Verify the
endpoint is reachable from the same host/network as Scoot.

### The agent says it "can't" run a command

That's usually the policy gate, not a bug. In `readonly`, `bash`, writes, and
network are denied by design; in `guarded`, catastrophic commands are blocked.
Confirm with `policy check`:

```sh
scoot policy check bash "the command" --mode readonly
```

Switch `[tools] policy` to `guarded` (interactive) or `unrestricted` (full trust)
if appropriate — see [Execution Policy & Security](policy.md).

### `file_edit` fails with an ambiguous/!found match

`file_edit` requires `old` to appear **exactly once**. `file_read` the file first
and copy a longer, unique surrounding span into `old`.

### A skill isn't discovered

- Check `scoot skills` to see the resolved search paths and what was found.
- Ensure `[skills] enabled = true`.
- Verify the directory has a valid `SKILL.md` with non-empty `name` and
  `description`: `scoot skills check path/to/skill`.
- Remember the priority order — a same-named skill earlier in the list wins
  (`<cwd>/.agents/skills` > optional `~/.agents/skills` > `~/.scoot/skills` > `extra_paths`).

### Skills don't work in `readonly`

They do — **reading** a skill is native and policy-independent. What a skill then
asks the model to *run* is still gated. If a skill's *actions* are blocked in
`readonly`, that's expected; loading its instructions is not.

### A scheduled job never fires

- `[schedule] enabled` must be `true`.
- Each job needs **exactly one** trigger; `schedule list` shows invalid jobs as
  `INACTIVE`.
- Cron expressions are 5-field UTC schedules and fire at most once per matching
  minute.
- A job set to `guarded` runs as effective `readonly`; if it seems unable to
  write or reach the network, that's the unattended-safety coercion.

### The run stops early with a context-budget error

You set `[agent] context_budget_bytes` and the transcript stayed over budget even
after history compaction — i.e. the budget is too small for the minimal retained
context (system prompt + original task + most recent turns). Raise the budget
(staying below your backend's context window) or set it to `0` to disable the
check (turn count is still bounded by `max_turns`).

### The agent loops without finishing

It hit `max_turns` (default 32). Increase `[agent] max_turns`, or narrow the goal.
Use `--trace` to see where it's spinning.

## FAQ

**Does Scoot send my code to a third party?**
Only to the model backend you configure (`base_url`). There is no telemetry, no
cloud sync, and secrets are never logged. Point it at a local backend for fully
on-device operation.

**Can I use it fully offline?**
Yes — with a local OpenAI-compatible backend (e.g. Ollama). The structured tools
need no external commands.

**Is `guarded` mode a sandbox?**
No. It's an accident-catching tripwire. `readonly` is the fail-closed safety
primitive; combine it with OS-level isolation for hostile inputs. See the
[honest threat model](policy.md#honest-threat-model).

**Where are logs and history?**
`~/.scoot/logs/audit.jsonl` and `~/.scoot/state/sessions/<id>.jsonl`. See
[Sessions & Audit](sessions.md).

**What is "plan mode"?**
Reserved, not yet implemented. `default_mode` accepts `goal` today; `plan` does
not change execution yet. See the [Roadmap](roadmap.md).

**How do I update?**
Rebuild from source (`git pull && zig build`) or install a newer release
artifact. See [Installation](installation.md).

**Still stuck?**
Re-run with `--trace`, capture `scoot doctor` output, and open an issue at the
project repository.
