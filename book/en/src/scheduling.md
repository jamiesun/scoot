# Scheduling & Daemon

Scoot can run **unattended** scheduled jobs through a foreground daemon loop.
Autonomy is **off by default** — you must explicitly enable it. The full
lifecycle/recovery reference is [`docs/DAEMON.md`](https://github.com/jamiesun/scoot/blob/main/docs/DAEMON.md).

## Enable Scheduling

```toml
[schedule]
enabled = true
poll_ms = 1000

[[schedule.jobs]]
id = "disk-check"
goal = "Inspect disk usage and summarize anomalies"
every_sec = 300
mode = "readonly"
```

Each job needs **exactly one** trigger:

| Trigger | Meaning |
| --- | --- |
| `every_sec` | Fire on a fixed interval (seconds). |
| `at_unix` | Fire once at a fixed Unix-time instant. |
| `cron` | Fire on a 5-field UTC cron expression. |

A job with zero or multiple triggers is invalid and skipped with a warning. See
[Configuration → `[[schedule.jobs]]`](configuration.md#schedulejobs) for every
field.

## Unattended Safety

Scheduled jobs enforce safety **structurally**, not by convention:

- a job's `mode` defaults to `readonly`;
- a `guarded` job is **coerced to effective `readonly`** at execution time;
- `unrestricted` only takes effect if you set it explicitly, accepting the
  unattended write/network risk.

This means an unattended job cannot accidentally write or hit the network unless
you deliberately opted in. See [Execution Policy & Security](policy.md).

## Running The Scheduler

```sh
scoot schedule list             # show jobs and whether each is ACTIVE/INACTIVE
scoot schedule run              # run the loop in the foreground
scoot schedule run --ticks 1    # run exactly one poll cycle, then exit
```

`--ticks N` is handy for testing and cron-driven one-shot invocation: it polls
`N` times and exits (`0` = run forever).

## Daemon Mode

`daemon` is the long-running foreground process for scheduled jobs. It does
**not** fork into the background — pair it with `systemd`, `launchd`, `tmux`, or
a shell job for background ownership.

```sh
scoot daemon run                # foreground; requires schedule.enabled = true
scoot daemon run --ticks 3      # run three poll cycles then exit
scoot daemon status             # print the last recorded daemon state
scoot daemon stop               # SIGTERM a running daemon
```

`daemon run` loads valid jobs, writes lifecycle state, installs SIGTERM/SIGINT
handlers, and runs the same loop as `schedule run`. On `stop`, the daemon
finishes the current tick, writes a stopped state, and removes its pid file.

### Lifecycle Files

```text
~/.scoot/
  logs/audit.jsonl       # audit events
  state/daemon.json      # status, pid, timestamps, stop reason, job count, poll interval
  state/daemon.pid       # present while running; removed on clean shutdown
  state/sessions/        # per-run session transcripts
```

If the process crashes, the next `daemon run` notices the previous state was
still `running` and prints a restart-recovery warning before writing a fresh
state.

### Recovery Contract

Recovery is intentionally conservative — Scoot does **not** resume an in-progress
model turn after process death:

- completed sessions remain in `state/sessions/`;
- already-flushed audit events remain in `logs/audit.jsonl`;
- `every_sec` / `at_unix` runtime timers reset on restart;
- config remains the source of truth for which jobs exist;
- a stale `running` state is treated as an unclean stop and overwritten.

## Example: a systemd unit

```ini
[Unit]
Description=Scoot daemon
After=network-online.target

[Service]
ExecStart=/usr/local/bin/scoot daemon run
Restart=on-failure
Environment=SCOOT_HOME=%h/.scoot

[Install]
WantedBy=default.target
```

Log and session files are append-only in this release; rotate or prune `logs/`
and `state/sessions/` externally for long-running deployments.
