# Best Practice Cases

Scoot is most useful when it is treated as a small, auditable agent runtime, not
as a general automation platform. Good deployments keep three boundaries clear:

- who owns the trigger: a human, CI, cron/systemd timer, or `scoot daemon run`;
- what the agent may touch: `readonly`, `guarded`, or explicitly
  `unrestricted`;
- where secrets and state live: environment/file/command secrets, local JSONL
  sessions, and audit logs.

The seven cases below are the strongest fits.

## 1. GitHub Actions Review Helper

Use Scoot in CI when you want a read-only summary, release note draft, changelog
check, or documentation drift report. This is one of the best fits: CI already
owns the trigger, the checkout is ephemeral, and `readonly` prevents accidental
writes or network exfiltration through agent tools.

Use `scoot -e`, not `daemon run`.

```yaml
name: Scoot review

on:
  pull_request:
  workflow_dispatch:

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    env:
      SCOOT_HOME: ${{ runner.temp }}/scoot
      OPENAI_API_KEY: ${{ secrets.LLM_KEY }}
      SCOOT_BACKEND_API_KEY_ENV: OPENAI_API_KEY
      SCOOT_BACKEND_BASE_URL: https://api.openai.com/v1
      SCOOT_BACKEND_MODEL: gpt-4o-mini
      SCOOT_TOOLS_POLICY: readonly
      SCOOT_AUDIT_TO_FILE: "true"
    steps:
      - uses: actions/checkout@v4
      - name: Install Scoot
        run: |
          tar -xzf scoot-linux-amd64.tar.gz
          install -m755 scoot/scoot /usr/local/bin/scoot
      - name: Generate review brief
        run: |
          scoot -e "Review this checkout. Summarize behavior changes, risky files, and missing docs/tests. Do not modify files." \
            | tee scoot-review.md
      - uses: actions/upload-artifact@v4
        with:
          name: scoot-review
          path: |
            scoot-review.md
            ${{ runner.temp }}/scoot/logs/
            ${{ runner.temp }}/scoot/state/sessions/
```

Keep write-back to PR comments as a separate, explicit step if you add it later.
Scoot's job is to produce the analysis artifact; GitHub permissions should stay
least-privilege.

## 2. Unattended Operations Brief

Use this when you want a daily or hourly local report from logs, config files,
and pre-generated status snapshots. Scoot owns the schedule loop; `systemd` only
keeps the foreground process alive.

```toml
[schedule]
enabled = true
poll_ms = 1000

[[schedule.jobs]]
id = "ops-brief"
goal = "Inspect local logs, config files, and pre-generated status snapshots. Summarize anomalies and likely next checks. Do not write files or call the network."
cron = "0 8 * * *"
mode = "readonly"
```

```ini
[Unit]
Description=Scoot operations brief
After=network-online.target

[Service]
ExecStart=/usr/local/bin/scoot daemon run
Restart=on-failure
Environment=SCOOT_HOME=/var/lib/scoot

[Install]
WantedBy=multi-user.target
```

This is a good default unattended pattern because `guarded` jobs are coerced to
effective `readonly`, and `readonly` denies shell, writes, and network.
If you need command output such as `df`, `systemctl`, or vendor CLIs, run those
commands outside Scoot on a fixed schedule, write a plain-text status snapshot,
and let this readonly job inspect the snapshot.

## 3. RouterOS Or Container Probe

This is useful, but it is not a default-safe case. RouterOS and container probes
usually need network access, and scheduled `readonly` jobs deny network by
design. If you use Scoot here, isolate the environment first and make the
network permission deliberate.

Recommended shape:

- run Scoot inside a container, VM, or network namespace that can reach only the
  target management network;
- mount the filesystem read-only except for `SCOOT_HOME`;
- put RouterOS/API credentials in an environment variable, token file, or
  credential command, never in the goal;
- keep probe commands bounded with timeouts;
- set `mode = "unrestricted"` only for the specific probe job that needs
  network access.

```toml
[schedule]
enabled = true

[[schedule.jobs]]
id = "routeros-probe"
goal = "Run the existing read-only RouterOS/container probe script, interpret its output, and report anomalies. Do not change device configuration."
every_sec = 300
mode = "unrestricted"
```

The important point is that `unrestricted` is broad. Use operating-system and
network isolation to make the environment narrow before granting it.

## 4. Release And Changelog Preflight

Use `scoot -e` before cutting a release to inspect the checkout and generate a
human-readable preflight brief. This should usually be `readonly`.

```sh
SCOOT_TOOLS_POLICY=readonly \
scoot -e "Prepare a release preflight: summarize commits since the last tag, check README/changelog consistency, list risky changes, and identify missing release notes."
```

Good outputs include:

- changed user-facing behavior;
- docs that should be updated;
- likely test gaps;
- packaging or release-target concerns.

Keep the actual version bump, tag, and publish step outside this read-only
preflight unless you explicitly decide to run a separate guarded or unrestricted
release automation.

## 5. Configuration And Security Posture Audit

Use this when you want a regular check that Scoot's own runtime posture has not
drifted. The job should read config, run `doctor`, inspect permissions, and
explain weak settings.

```sh
scoot doctor
scoot policy check bash "rm -rf /" --mode guarded
scoot policy check http_request '{"method":"GET","url":"http://169.254.169.254/"}' --mode guarded
```

You can also schedule a local posture brief:

```toml
[[schedule.jobs]]
id = "scoot-posture"
goal = "Inspect Scoot config, doctor output, and runtime files. Report weak permissions, disabled hardening, unknown config keys, and risky scheduled jobs."
cron = "30 7 * * *"
mode = "readonly"
```

This catches configuration drift without giving the agent write access.

## 6. Edge Or NAS Health Watchdog

Scoot's small native deployment model fits low-resource hosts: NAS boxes, edge
Linux devices, lab machines, and small always-on servers. Use a local model
backend when possible and keep the job read-only. Because `readonly` denies
shell, feed Scoot logs and status snapshot files rather than asking it to run
system probes directly.

```toml
[backend]
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5"

[agent]
context_budget_bytes = 80000

[schedule]
enabled = true

[[schedule.jobs]]
id = "edge-health"
goal = "Inspect local logs, service files, and status snapshots. Summarize health risks for this edge host. Do not write files or call the network."
every_sec = 1800
mode = "readonly"
```

Set `ca_file` when the device lacks system root certificates and you must reach
an HTTPS backend.

## 7. Project-Local Runbook Skills

Use project-local skills for repeatable operational procedures: incident triage,
release checklist interpretation, data-retention review, or vendor-specific
diagnostics. Put the instructions in the repository so the runbook is reviewed
with code.

```text
.agents/skills/
  incident-triage/
    SKILL.md
    references/
      service-map.md
      escalation.md
```

```sh
scoot skills check .agents/skills/incident-triage
scoot -e "Use the incident-triage skill to inspect this checkout and prepare a triage brief."
```

Best practice:

- keep skill instructions specific and reviewable;
- avoid embedding secrets in skill files;
- prefer project-local skills over broad user-global skills for production
  work;
- remember that reading skill files works even in `readonly`, but any action the
  skill asks Scoot to run still goes through the normal policy gate.

## Selection Guide

| Need | Best mode |
| --- | --- |
| One immediate analysis | `scoot -e` |
| CI summary or PR/release preflight | `scoot -e` with `SCOOT_TOOLS_POLICY=readonly` |
| External scheduler owns timing | `scoot schedule run --ticks 1` |
| Scoot owns recurring local jobs | `scoot daemon run` under systemd/launchd |
| Network probe | Explicit `unrestricted` plus OS/network isolation |
| Untrusted or unattended local inspection | `readonly` |
