# CLI Reference

```text
scoot [options] [command]
```

With no command, Scoot starts the interactive REPL. Global options can precede
or follow the command. The runtime directory defaults to `~/.scoot` and can be
overridden with `--scoot-home` or `SCOOT_HOME`.

## Global Options

| Option | Description |
| --- | --- |
| `-e, --eval <prompt>` | Run a single goal to completion, print the answer, and exit. |
| `--retries <N>` | Retries for transient backend errors in `-e` mode (default `2`, `0` disables). |
| `--scoot-home <dir>` | Override the runtime directory. Wins over `SCOOT_HOME`. |
| `--trace` | Print the ReACT execution trace to **stderr** (answer/conversation stays on stdout). Works in `-e` and interactive REPL mode. |
| `--ticks <N>` | For `schedule run` / `daemon run`: run `N` poll cycles then exit (default `0` = run forever). |
| `-h, --help` | Show usage. |
| `-v, --version` | Show the version. |

## Commands

### Choosing A Run Mode

| Mode | Source of work | Exit behavior | Use when |
| --- | --- | --- | --- |
| `scoot -e "<goal>"` | Command-line prompt. | Exits after one answer. | You want one immediate task. |
| `scoot schedule run --ticks 1` | Configured `[[schedule.jobs]]`. | Exits after one scheduler poll. | cron, systemd timer, or CI owns the schedule. |
| `scoot daemon run` | Configured `[[schedule.jobs]]`. | Runs forever by default. | Scoot owns the schedule loop and a supervisor keeps it alive. |

`daemon run` is not a shortcut for `-e`: it never takes an ad hoc prompt from
the command line. It loads configured jobs, checks their triggers, writes
daemon pid/state files, and applies unattended job safety rules.

### `repl` (default)

```sh
scoot              # or: scoot repl
```

Starts an interactive Read-Eval-Print loop. Type a goal, watch the agent work,
get an answer, repeat. Type `/exit` to leave. Each prompt runs the full ReACT
loop under the configured policy. Add `--trace` to stream each turn's ReACT
trace to **stderr** while the conversation stays on stdout:

```sh
scoot --trace            # interactive REPL with execution trace on stderr
```

### `-e, --eval` — one-shot

```sh
scoot -e "count the Zig source files in this repository"
scoot --retries 4 -e "summarize README.md"
scoot --trace -e "list the largest files under src/"
```

Runs one goal and prints **only the final answer** to stdout — ideal for
scripting and piping. `--trace` adds the step-by-step trace on stderr for
debugging without polluting the answer. The trace emits a live progress marker
*before* each blocking step — `thinking:` before calling the model and
`running: <tool>` before executing a tool — so you can see what the agent is
doing while it waits, instead of the trace appearing to freeze. `--retries`
controls retry of transient backend failures (rate limits, 5xx).

### `config`

```sh
scoot config
```

Prints the resolved runtime directory and backend configuration. Secrets are
**redacted** — only the resolved source is shown, never the token value. Use it
to confirm which config file and runtime directory are in effect.

### `doctor`

```sh
scoot doctor
scoot --scoot-home /tmp/scoot-test doctor
```

Runs local health checks without printing secrets: runtime directory and
permissions, config source, backend prerequisites, the resolved **secret
source**, skill discovery, schedule status, and the audit log path. Run it first
when something misbehaves.

### `policy check`

```sh
scoot policy check <action> <input> [--mode <mode>]
```

Dry-runs a tool action against a policy mode and explains whether it would be
**allowed** or **denied**, without executing anything. `<mode>` is `guarded`
(default), `readonly`, or `unrestricted`.

```sh
scoot policy check bash "rm -rf /" --mode guarded      # deny
scoot policy check bash "ls -la"   --mode readonly     # deny (no shell in readonly)
scoot policy check file_read '{"path":"README.md"}' --mode readonly  # allow
scoot policy check skill '{"name":"demo"}' --mode readonly           # allow (native)
scoot policy check recall '{"query":"old"}' --mode readonly          # allow (native)
```

This is the fastest way to understand the policy model — see
[Execution Policy & Security](policy.md).

### `skills`

```sh
scoot skills                       # list discovered skills (name / description / dir)
scoot skills check [dir]           # validate a skill dir, or all search paths if omitted
scoot skills pack <dir> [out.tar]  # validate and export a reviewable tar package
```

- `skills` prints the resolved search paths and every discovered skill.
- `skills check [dir]` validates structure **without executing** any skill
  scripts. A valid skill has `SKILL.md` with non-empty `name` and `description`;
  optional `capabilities`, `allowed_tools`, and `scope` metadata is validated.
- `skills pack` validates then exports a tar with a `.scoot-skill.json` review
  manifest. It includes regular non-hidden files, rejects unsafe types like
  symlinks, and grants no policy bypass.

See [Skills](skills.md) for authoring details.

### `wasm-tools check`

```sh
scoot wasm-tools check <dir>
```

Statically validates a local Wasm tool package boundary — `manifest.toml`,
`policy.toml`, referenced JSON schemas, and safe relative paths. It **never
loads or executes** the Wasm. See [Wasm Tool Packages](wasm-tools.md).

### `schedule`

```sh
scoot schedule list                 # show configured jobs and their state
scoot schedule run                  # run the scheduler loop (foreground)
scoot schedule run --ticks 1        # run one poll cycle then exit
```

Lists or runs scheduled jobs. Unattended runs enforce fail-closed `readonly`
safety. Requires `schedule.enabled = true` to run. See
[Scheduling & Daemon](scheduling.md).

### `daemon`

```sh
scoot daemon status                 # print last recorded daemon state
scoot daemon run                    # foreground long-running scheduler
scoot daemon run --ticks 3          # run three poll cycles then exit
scoot daemon stop                   # send SIGTERM to a running daemon
```

The foreground long-running mode for scheduled jobs. It writes
`state/daemon.json` and `state/daemon.pid`, installs SIGTERM/SIGINT handlers, and
preserves the unattended `readonly` safety rule. It does **not** fork into the
background — use `systemd`, `launchd`, `tmux`, or a shell job for that. See
[Scheduling & Daemon](scheduling.md).

## Exit Behavior & Piping

`-e` mode writes the final answer to **stdout** and diagnostics/traces to
**stderr**, so you can compose Scoot into shell pipelines:

```sh
answer=$(scoot -e "print today's date in ISO 8601")
scoot --trace -e "audit open ports" 2> trace.log
```
