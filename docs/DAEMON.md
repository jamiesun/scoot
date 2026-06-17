# Daemon Lifecycle

Scoot's daemon mode is a foreground long-running process for scheduled jobs. It
does not fork into the background; use a supervisor such as `systemd`, `launchd`,
`tmux`, or a shell job when background ownership is needed.

## Commands

```sh
scoot daemon status
scoot daemon run
scoot daemon run --ticks 3
scoot daemon stop
```

`daemon run` requires `schedule.enabled=true`. It loads valid `schedule.jobs`,
writes lifecycle state under the Scoot runtime directory, installs SIGTERM/SIGINT
handlers, and runs the same unattended schedule loop as `schedule run`.

`daemon status` prints the last recorded daemon state. It reports Scoot's own
state file and pid file; it does not probe process liveness.

`daemon stop` reads `state/daemon.pid` and sends SIGTERM. The running daemon
finishes the current tick, writes a stopped state, and removes the pid file. If a
job is already executing, the signal is recorded and the loop exits after that
job returns.

## Runtime Files

```text
~/.scoot/
  logs/audit.jsonl
  state/daemon.json
  state/daemon.pid
  state/sessions/
```

`state/daemon.json` records:

- lifecycle format version,
- status: `running` or `stopped`,
- pid,
- start/update/stop timestamps,
- stop reason,
- schedule job count and poll interval,
- a note that scheduled jobs still use the normal policy gates.

`state/daemon.pid` exists while `daemon run` is active and is removed on normal
shutdown. If the process crashes, the next `daemon run` detects that the previous
state was still `running` and prints a restart-recovery warning before writing a
new state.

## Recovery Contract

Scoot does not resume an in-progress model turn after process death. Recovery is
intentionally conservative:

- completed sessions remain in `state/sessions/`,
- audit events already flushed remain in `logs/audit.jsonl`,
- scheduled `at_unix` and `every_sec` runtime memory resets on restart,
- config remains the source of truth for which jobs exist,
- a stale `running` daemon state is treated as evidence of an unclean previous
  stop and is overwritten by the new daemon run.

## Safety And Resource Boundaries

Scheduled jobs keep the existing unattended safety rule: `guarded` is coerced to
effective `readonly`; `unrestricted` must be explicit in the job config. Skill
instructions and scripts do not bypass policy gates.

Each scheduled job uses a resettable scratch arena and writes session/audit state
at job boundaries. Log and session files are append-only in this release; users
should rotate or prune `logs/` and `state/sessions/` externally for long-running
deployments until built-in retention policy is added.
