# Scheduling & Daemon

Scoot can run **unattended** scheduled jobs through a foreground daemon loop.
Autonomy is **off by default** — you must explicitly enable it. The full
lifecycle/recovery reference is [`docs/DAEMON.md`](https://github.com/jamiesun/scoot/blob/main/docs/DAEMON.md).

## Which Mode Should I Use?

Use this table before choosing between `-e`, `schedule run`, and `daemon run`:

| Mode | Reads jobs from config? | Runs forever by default? | Typical owner of timing | Best fit |
| --- | --- | --- | --- | --- |
| `scoot -e "<goal>"` | no | no | caller | One immediate human/scripted task. |
| `scoot schedule run --ticks 1` | yes | no | cron, systemd timer, CI | External scheduler triggers Scoot periodically. |
| `scoot schedule run` | yes | yes | current terminal/process manager | Simple foreground scheduler loop without daemon state files. |
| `scoot daemon run` | yes | yes | Scoot loop plus systemd/launchd/etc. supervision | Long-running unattended scheduler with pid/state/stop/status support. |

`-e` and scheduled execution are different entry points. `-e` runs the prompt
you pass on the command line immediately, using the normal configured tool
policy. Scheduled jobs come from `[[schedule.jobs]]`, are triggered by
`every_sec`, `at_unix`, or `cron`, and use the unattended safety rule: job mode
defaults to `readonly`, and `guarded` is coerced to effective `readonly`.

`systemd` is useful only when you want a process supervisor. With
`scoot daemon run`, Scoot owns the schedule loop while systemd owns startup,
restart, logs, environment, resource limits, and SIGTERM shutdown. If you want
systemd to own the timing too, use a systemd timer that invokes
`scoot schedule run --ticks 1`.

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
scoot daemon stop               # SIGTERM only when running state and pid agree
```

`daemon run` loads valid jobs, writes lifecycle state, installs SIGTERM/SIGINT
handlers, and runs the same loop as `schedule run`. On `stop`, Scoot only signals
when `state/daemon.json` says `running` and matches `state/daemon.pid`; otherwise
the pid file is treated as stale. A running daemon finishes the current tick,
writes a stopped state, and removes its pid file.

### One Daemon Per Runtime Directory

Daemon liveness is tracked per runtime directory through `state/daemon.json` and
`state/daemon.pid`. Starting `daemon run` while another daemon for the **same**
directory is still alive is refused, so two daemons can never share one schedule
and state tree:

```text
[scoot] refusing to start: detected daemon already running (pid=… started_at=…).
Run `scoot daemon stop` first.
```

The guard probes the recorded pid with signal `0`; a stale pid left by a crash is
treated as an unclean stop and recovered on the next run.

To run **several daemons on one host**, give each its own runtime directory and
they stay fully isolated — separate config, jobs, sessions, logs, and lifecycle
files:

```sh
scoot --scoot-home /opt/scoot/web   setup     # provision instance "web"
scoot --scoot-home /opt/scoot/batch setup     # provision instance "batch"

SCOOT_HOME=/opt/scoot/web   scoot daemon run &
SCOOT_HOME=/opt/scoot/batch scoot daemon run &
```

`scoot setup` is the quickest way to provision each directory. Because the
single-daemon guard is per directory, distinct homes never collide.

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
