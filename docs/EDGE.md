# scoot-edge: Optional Fleet Agent Boundary

Chinese version: [EDGE.zh.md](EDGE.zh.md)

Status: **E1 substantially implemented; E2 job dispatch implemented; E3
packaging partially implemented.** The E0 boundary has been signed off and a
standalone, opt-in `scoot-edge` companion now exists behind `zig build
-Dedge=true`. It can emit one report-only status heartbeat locally, `post-once`
that heartbeat to an HTTPS endpoint with a per-node bearer token, and **`run` a
continuous heartbeat loop** that dials out on a fixed interval with bounded
jittered backoff on transient failure (never crashing the loop, never opening a
listener). The heartbeat can carry an **opt-in, advisory `node` capability
descriptor** (`--report-capabilities`) for capability-aware routing. A deliberately
named `--allow-insecure-http` switch exists only for local/dev loopback testing
against a plain-HTTP center; non-loopback HTTP is rejected even with the switch, and
production remains HTTPS-only. `scoot-edge dispatch` (also reachable via `run
--enable-jobs`) now polls a `GET` job lease, executes 0..N jobs through
`scoot --unattended -e "<goal>"` with cwd confined to `edge.job_root`, and reports
`job_event`s back with a bounded, idempotent, provenance-logged apply (#186).
It is published like `scoot-wasm`: a separate `scoot-edge-<target>.tar.gz`
release archive, a Homebrew formula, and an opt-in `SCOOT_INSTALL_EDGE` flag
for `install.sh` — never installed by default. Audit-body shipping remains
intentionally unimplemented and gated by the prerequisites below.

## The idea in plain terms

Today every Scoot install is an island. To see what one is doing or hand it a
task, you SSH in by hand. `scoot-edge` is a small **messenger** you can put next to
each Scoot so a central console can reach the whole fleet.

```text
        Management center (your future console)
          ^      ^      ^
          |      |      |   messenger calls out and reports up
        edge   edge   edge
          |      |      |
        scoot  scoot  scoot      your machines
```

Three plain-language promises hold the whole design together:

1. **The messenger only dials out; the center can never dial in.** Your machine
   opens no new port, so installing `scoot-edge` adds nothing for an attacker to
   knock on.
2. **The messenger only does two things, and it can't overstep.** It *reports*
   health and audit logs upward (upload only, never written back), and it can
   *accept a task* phrased as a plain goal. The center hands over a goal as data,
   not a command — Scoot still reviews it exactly as if you typed it locally. The
   center cannot make your machine run a raw shell command.
3. **The center's power has a ceiling, and you set it.** By default a
   center-sent task is read-only — it can look but not touch. Allowing more is a
   local opt-in on your machine. The center can never raise its own ceiling.

One honest caveat sits behind promise 3: *read-only* means a task cannot change
your machine, but whatever it reads can still flow up to the center — that is the
whole point of handing it a task, and the result (stdout, session, audit) is shipped
back. So a read-only task is a **read-and-report** channel, not a sealed sandbox.
Point an edge only at a center you would trust to read whatever that task can read.

The rest of this document is the precise contract behind those three promises.

## Positioning

`scoot-edge` is an **optional, standalone, not-installed-by-default** companion
binary that lets a remote management center observe and (opt-in) dispatch tasks to
a Scoot instance, **without linking into or changing the local-first core**.

It follows the exact same posture as the standalone `scoot-wasm` host: a separately
compiled target, never imported by core, invoked only at the process boundary. If
you do not install `scoot-edge`, Scoot stays exactly as it is today — fully local,
no outbound connection, no listener, no new trusted surface.

| Aspect | scoot-wasm (precedent) | scoot-edge |
| --- | --- | --- |
| In core binary | No, standalone | No, standalone |
| Default installed | No | No |
| Coupling to scoot | host argv boundary only | public launch interfaces only |
| Effect on core when absent | none | none |

## Deployment assumption

`scoot-edge` is designed for a **lightweight VPC-internal deployment**, not for the
open internet. The management center is reachable on a private network. This keeps
the protocol intentionally small (simple HTTP verbs plus NDJSON shapes over TLS, no
heavy RPC stack),
while the security weight is carried by the **authority model**, not by the
transport.

The VPC assumption does **not** weaken the local authority ceiling: even a fully
trusted network is treated as untrusted for privilege purposes (defense in depth).

## Topology

- **The edge dials outbound to the center. The center is the server.** The edge
  opens **no inbound listener**. This is the standard fleet-agent pattern and is
  required for cross-NAT, non-container fleets. It also means installing
  `scoot-edge` adds no inbound trusted surface to the host.
- The center never needs to know each edge's address and never reverse-connects.

## Transport and authentication

- **HTTPS is mandatory, even on an internal network.** Transport is encrypted with
  server-side TLS: the edge verifies the center's certificate. This is **not mTLS** —
  client identity is carried by a token (below), not a client certificate, which
  keeps certificate management to a single server cert. The E1 `post-once`
  command has an explicit `--allow-insecure-http` escape hatch for local/dev
  loopback testing only; non-loopback `http://` URLs are rejected even with the
  switch. It is not a production transport mode.
- **Per-node bearer token.** Each edge node carries its **own** token, sent as
  `Authorization: Bearer <token>`. Per-node (not fleet-shared) tokens let the center
  identify, rate-limit, and revoke a single node without rotating the whole fleet.
- **Token sources follow the existing secret machinery:** environment variable,
  then a `0600` token file, then a credential command. The token is **never compiled
  into the binary, never committed, never printed, and never written to any audit
  log** (constraint 7).
- **Framing is NDJSON** (one JSON object per line), consistent with `scoot serve`
  and the audit JSONL format. No gRPC, no protobuf, no WebSocket framing.

## Message envelope

Every wire message shares one envelope:

```json
{"v":1,"type":"status|audit_batch|job|job_event","node_id":"n-7a3","sent_ts":1719600000000,"body":{}}
```

- `v` pins the protocol version.
- `node_id` is the stable node identity (configured, and correlated to the token).
- `sent_ts` is Unix milliseconds, aligned with the audit `ts` field.

## Phase E1 — report-only telemetry (append-only)

The edge ships two record kinds. Both are **append-only** (only ever added to, never
edited or replayed back) and are **never re-applied
to local state**.

### status (heartbeat)

Source: `daemon status`, audit counts, and the local config policy.

```json
{"v":1,"type":"status","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "scoot_version":"...","edge_version":"...",
  "daemon":{"state":"running","clean_prev_stop":true,"since":1719500000000},
  "policy_ceiling":"readonly",
  "audit_stats":{"run":12,"tool_call":40,"policy_deny":1,"system_error":0}
}}
```

- `policy_ceiling` is exactly the local `edge.max_job_policy` — the ceiling for
  center-dispatched jobs, not the interactive or per-run mode. With no E2 configured
  it reports the default `readonly`.
- `audit_stats` is derived: the edge tallies it by scanning `logs/*.jsonl`, since
  `audit.Stats` is in-memory per `Logger` and is not persisted.

### node descriptor (identity and capability, opt-in)

The bare heartbeat above is liveness only. Capability-aware dispatch needs to know
what a node *is for*, so the status body may carry an optional `node` descriptor — on
the same fail-closed terms as audit shipping: **off by default**
(`edge.report_capabilities`), because a capability / skill list is also a fleet-recon
surface, and **advisory, never authority**.

```json
"node":{
  "labels":["role:db","env:prod","focus:log-triage"],
  "os":"linux","arch":"x86_64",
  "capabilities":{
    "max_job_policy":"readonly",
    "tools":["file_read","grep","glob","http_request"],
    "skills":["log-triage","cert-check"]
  }
}
```

- **Advertising is not authority.** The descriptor only helps the center *decide what
  to send*; execution is still gated by the local `policy_ceiling`. Claiming a
  capability never expands what the edge will do, and over- or under-claiming degrades
  to a job reject, never to unsafe execution.
- **Three sources.** `labels` is operator-declared local config (`edge.labels`) for
  routing intent the center cannot infer; `os` / `arch` / `tools` / `max_job_policy`
  are auto-derived local facts; `skills` reuses the existing skill manifest —
  installed skill *names* are the node's self-describing focus signal (skill
  instructions are never shipped).
- **Default off, opt-in richer.** Bare status ships liveness only; anything that
  leaves the host beyond liveness — audit bodies, capability / identity metadata — is
  an explicit local opt-in.

### audit_batch (append-only log shipping)

Source: read-only `logs/*.jsonl`.

**Shipping audit off-box is a data-movement decision, not a no-op.** Constraint 7
is enforced for *known* secret values: the resolved backend token and the value of
any ambient env var whose name looks secret-bearing are redacted out of `msg`
bodies before they are ever written to `logs/audit.jsonl` (issue #189). It does
**not** guarantee that audit `msg` bodies are free of *all* sensitive content.
`observation` and `tool_call` events still carry tool output verbatim beyond known
secret values: `file_read` file contents, `bash` command output, and
`http_request` response bodies may hold sensitive data Scoot has no way to
recognize as a secret. So `audit_batch` relocates whatever a run observed to the
center. The edge therefore treats audit shipping as fail-closed:

- `edge.ship_audit` defaults to **off**. Without it, telemetry is the `status`
  heartbeat only (counts, never bodies).
- When enabled, `edge.audit_ship_kinds` is an explicit allowlist of event kinds,
  defaulting to the low-content kinds (`run`, `final`, `policy_deny`, `system_error`)
  and **excluding `observation` by default**.
- An optional `edge.audit_redact` pattern set is applied in the edge before send; a
  redaction failure drops the record rather than shipping it raw.

```json
{"v":1,"type":"audit_batch","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "cursor":{"file_gen":3,"byte_from":40960,"byte_to":61440,"seq_to":149},
  "events":[]
}}
```

- **Idempotency cursor** (so the same data is never counted twice). Audit `seq` is
  monotonic *per Logger instance* and restarts at 0 after rotation, so `seq` alone is
  not a safe dedup key. The cursor is `{file_gen, byte_offset}` (a monotonic rotation
  generation plus byte offset), with `seq` as a secondary correlation. The center
  stores append-only; replaying the same range is a no-op. This yields at-least-once
  delivery with idempotent apply.
- **`file_gen` now exists in core** (issue #187), closing the hard E1
  prerequisite this section used to block on. `src/audit.zig`'s
  `rotateGenerational` replaces the old single-backup `audit.jsonl → audit.jsonl.1`
  (which deleted the prior `.1` on every rotation, permanently losing the middle
  range if a node rotated twice between edge polls). Each rotation now retires
  the active file to a monotonically numbered `audit.jsonl.<gen>`, with the
  generation counter persisted in a `audit.jsonl.gen` sidecar so it survives
  process restarts. Up to `[audit].max_retained_generations` (default 8) retired
  generations are kept; only once that cap is exceeded is the oldest evicted —
  and the eviction is durably recorded as `{gap_from, gap_to, ts}` in
  `audit.jsonl.gaps.jsonl` (readable via `scoot doctor`, which warns if any gap
  was ever recorded) rather than silently disappearing.
- **This is a core retention prerequisite, not audit shipping itself.** The
  byte-offset side of the cursor (`byte_from`/`byte_to`/`seq_to` above) and the
  wire-level `audit_gap` marker are still E1 shipping work that does not exist
  yet — `edge.ship_audit` / `edge.audit_ship_kinds` / `edge.audit_redact` are
  aspirational config keys with no implementation in `src/edge_main.zig` today.
  What #187 removes is the *reason* shipping could never be at-least-once: core
  no longer destroys a rotated generation before something had a chance to read
  it, and any generation that is eventually evicted by the cap leaves a durable
  trail instead of a silent hole.
- **Audit shipping itself stays unimplemented and therefore off.** Landing the
  retention prerequisite does not turn `audit_batch` on; there is still no
  `edge.ship_audit` config, dial-out path, or ack protocol in `src/edge_main.zig`.
  This keeps E1's eventual delivery promise honest instead of advertising
  at-least-once before the shipping code itself exists.
- In a VPC deployment, E1 may stay as simple periodic `POST /telemetry`. The edge
  does not need long-polling until E2 introduces job dispatch.

## Phase E2 — schema'd, idempotent job dispatch

**Implemented (#186).** `scoot-edge dispatch` runs one lease-poll-and-execute cycle;
`scoot-edge run --enable-jobs` folds the same cycle into the heartbeat loop. Both
require `--job-root` and `--lease-url` (validated by the same config gate as
`--center-url`/token: missing or insecure values die with exit `2`, never silently
no-op). The center dispatches jobs over a `GET` lease the edge requests outbound:

```
GET /jobs/lease?node=n-7a3&capacity=2
Authorization: Bearer <token>
→ 200, NDJSON body, 0..N job envelopes
```

```json
{"v":1,"type":"job","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "job_id":"j-91","idem_key":"...","kind":"run",
  "goal":"summarize today's audit anomalies",
  "requested_policy":"readonly","deadline_ts":1719600060000,"max_retries":0
}}
```

The center routes by matching a job against the node's last-known `node` descriptor
(its `capabilities` and `labels`); the edge does not negotiate capabilities on the
wire. A job the node cannot satisfy is rejected with `no_matching_capability`, so a
capability mismatch degrades to a reject, never to unsafe execution.

The entire security model lives in these rules:

| Rule | Mechanism | Constraint preserved |
| --- | --- | --- |
| `kind` is a closed enum, currently only `run` | The edge treats `goal` as **opaque data** handed to `scoot -e`. It never synthesizes shell or `eval` from the wire. | Never execute unvalidated model output |
| Policy can only be lowered, never raised | `effective = correctUnattended(privilegeMin(requested, local edge.max_job_policy))`. Privilege order is the explicit lattice `readonly ⊑ guarded ⊑ unrestricted` — **not** the `Mode` enum's declaration order, so a numeric `@min` would invert it. `correctUnattended` maps `guarded → readonly` because edge jobs are unattended. `edge.max_job_policy` is a **local-only** knob defaulting to `readonly`; the wire can never raise it. | Local config/policy is the ceiling |
| Idempotent apply (the same job sent twice runs only once) | The edge keeps a bounded, persistent `idem_key` set under `~/.scoot/edge/`. A redelivered job acks the prior result instead of re-running. | At-least-once, idempotent apply |
| Full provenance | Each dispatched job is recorded in an edge-side `logs/edge-audit.jsonl` (who dispatched it, `idem_key`, `effective_policy`, correlated `session_id`), joined to Scoot's own run audit via `session_id`. | Full provenance auditing |
| Confined working directory | The edge launches the child with cwd pinned to `edge.job_root` (a dedicated, empty-by-default directory), never the host root or `$HOME`. Because `readonly` read confinement is **cwd-relative** (`evaluateReadPath`), this is what makes `readonly` mean *this directory* instead of *the whole filesystem*. | Local config/policy is the ceiling |

**The clamp is now a real primitive — `scoot --unattended -e "<goal>"`.** Previously
`scoot -e` ran at the *local config* policy (`cfg.tools.policy`) and, unlike a
scheduled job, got **no** unattended `guarded → readonly` correction (that lives in
`schedule.zig`'s `effectiveMode`, which the plain one-shot path never called). So a
naive `scoot -e "<goal>"` on a host whose local default is `guarded` would run with
shell, write, and network allowed — not `readonly`. That gap is now closed: passing
`--unattended` makes the child compute
`effective = correctUnattended(privilegeMin(requested, edge.max_job_policy))`
**inside the child against local config**, so argv can only ever *lower* policy. A
buggy or center-influenced edge passing `--policy unrestricted` on the command line
is clamped down to the local ceiling and ignored. The edge launches E2 jobs through
this clamp (`scoot --unattended -e "<goal>"`); the shared `correctUnattended` lattice in
`policy.zig` is the single source of truth for both the scheduler and the one-shot.

Job lifecycle is reported back over the same append-only telemetry channel:

```json
{"v":1,"type":"job_event","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "job_id":"j-91","phase":"accepted|running|done|failed|rejected",
  "session_id":"...","effective_policy":"readonly",
  "reject_reason":"policy_ceiling|bad_schema|at_capacity|no_matching_capability"
}}
```

## Authority model (the decision that needs sign-off)

| Phase | What the center can do | Risk | Recommendation |
| --- | --- | --- | --- |
| E1 report-only | `status` heartbeat by default; audit-log shipping only when explicitly enabled | lower, but audit shipping moves observation data (file contents, command output) off-box | ship `status` first; core rotation is now shipping-aware (#187), but keep audit shipping off until the E1 dial-out/ack path itself is built |
| E2 job-dispatch | dispatch tasks the edge launches via Scoot | confused deputy (the edge could be used as someone else's tool) | only behind explicit config + policy ceiling |

**Signed-off defaults:**

- **Edge-dispatched jobs default to `readonly`, enforced by the clamp — not
  inherited automatically.** The scheduler's `guarded → readonly` correction lives in
  `schedule.zig` and does *not* apply to a plain `scoot -e`. The in-child unattended
  clamp now exists in core as `scoot --unattended -e "<goal>"` (it reads the local
  `edge.max_job_policy` ceiling, default `readonly`), so the readonly default is
  backed; E2 job dispatch wires through it.
- **Raising the ceiling requires explicit local opt-in, and the only meaningful
  raise is the big one.** For *unattended* jobs `guarded` collapses to `readonly`, so
  `edge.max_job_policy = guarded` buys nothing over `readonly`. The only setting that
  actually grants writes or network to edge jobs is `edge.max_job_policy =
  unrestricted` — a deliberate, fully-audited, local-signoff jump with no safe middle
  tier. The center can never exceed the local ceiling, and no wire field raises
  policy.

## Reliability primitives

- **Hard timeouts everywhere** (constraint 6): connect timeout, per-request timeout,
  long-poll hold limit, and per-job `deadline_ts`.
- **Bounded in-flight queue.** The edge advertises remaining `capacity` on lease; at
  capacity it applies backpressure (`at_capacity`) instead of overcommitting.
- **Reconnect** with bounded exponential backoff plus jitter and a cap.
- **Telemetry advances its cursor only after the center acks**, so it never loses or
  double-applies records.

## Interface contract with Scoot core

The edge drives Scoot **only through public launch interfaces and read-only logs**.
It must not import `src/internal.zig` and gets no special capability. The narrow
public package root (`src/root.zig`) stays the contract.

| Wire op | Public surface used |
| --- | --- |
| `status` | `daemon status` (and a future `--json` form), config read, skill discovery (names / descriptions only) |
| `audit_batch` | read-only `logs/*.jsonl` |
| `job kind=run` | child process `scoot --unattended -e "<goal>"` launched **through the unattended one-shot clamp** (ceiling enforced in-child against local `edge.max_job_policy`), with cwd pinned to `edge.job_root` |
| job result | child exit code + stdout + the resulting session / audit |

### Core prerequisites and improvements

Three of these are **blocking prerequisites**, not optional polish: the edge cannot
meet its own safety and delivery promises without them. They are still built as
separate, independently-useful core changes, but E1/E2 are gated on them.

1. **(E1 prerequisite)** Machine-readable status: `daemon status --json` /
   `doctor --json`. The `status` heartbeat must not depend on scraping
   human-readable text.
2. **(E2 prerequisite — the keystone) ✅ Done.** An unattended one-shot policy
   clamp so an edge-launched `scoot -e` is provably at or below the `readonly`
   ceiling, enforced in-child against local config. Shipped as
   `scoot --unattended -e "<goal>"` (with an optional `--policy <mode>` that can
   only *lower*), reading the local `edge.max_job_policy` ceiling (default
   `readonly`). The shared `correctUnattended`/`privilegeMin` lattice in
   `policy.zig` is the single source of truth for both the scheduler and the
   one-shot. This unblocks E2 job dispatch.
3. **(E1 prerequisite) ✅ Core retention done.** Shipping-aware, rotation-stable
   audit: a monotonic rotation generation, retaining rotated segments up to a
   bounded cap with an explicit gap record when the cap is exceeded. Landed as
   `rotateGenerational` in `src/audit.zig` (#187): the destructive single-backup
   `.1` rotation is gone from the real audit log, replaced by numbered
   `audit.jsonl.<gen>` segments tracked in a durable `.gen` sidecar, up to
   `[audit].max_retained_generations` (default `8`) kept, with any eviction
   durably recorded in `.gaps.jsonl` and surfaced by `scoot doctor`. Still
   missing before audit shipping itself can start: the byte-offset half of the
   cursor (`byte_from`/`byte_to`/`seq_to`), the wire-level `audit_gap` marker,
   and the `edge.ship_audit` dial-out path — none of which exist in
   `src/edge_main.zig` yet. Audit shipping stays disabled until those land.
4. **(Contract)** Keep the `serve` NDJSON method set stable as a contract;
   `scoot-edge` reuses its framing, not the channel.

## Non-goals (red lines, enforced in review)

- **No bidirectional state reconciliation.** The center never sends "your config /
  state should be X," and the edge never applies center state back to the host. This
  is the line that keeps `scoot-edge` from becoming complex cloud synchronization.
- **No inbound arbitrary-code channel.** `kind` is a closed enum; the goal is data
  that Scoot still validates through ReACT, the policy gate, and JSON schema.
- **The center cannot raise the local policy ceiling.** `edge.max_job_policy` is
  local-only; the default is `readonly`.
- **No GUI / web console.** The management-center UI is out of this repository's
  scope.
- **No internal linkage and no compiled-in or logged secrets.** Tokens come from
  env / `0600` file / credential command and never appear in audit.
- **No mesh / provider-specific transport.** HTTPS + NDJSON only.
- **No off-box shipping of audit bodies by default.** `status` counts ship;
  `observation` / `tool_call` bodies ship only behind explicit `edge.ship_audit` plus
  an allowlist, because they can carry file contents and command output. Read-only
  never means "nothing leaves the host."
- **No capability claim grants authority.** The `node` descriptor is declarative,
  advisory routing metadata; the local `policy_ceiling` still gates every job, and
  `edge.report_capabilities` is opt-in. Advertising a capability never widens what the
  edge will execute.

## Phasing

- **E0:** this boundary doc (bilingual) + roadmap amendment + authority-model
  sign-off. **Completed before code.**
- **E1:** `scoot-edge` skeleton (separate build target, default off) + `status`
  heartbeat over HTTPS. Implemented as `zig build -Dedge=true`: `scoot-edge status`
  prints one NDJSON status envelope gathered through `scoot daemon status --json`;
  `scoot-edge post-once` sends that envelope to a caller-provided HTTPS endpoint
  using a bearer token from an environment variable; and `scoot-edge run` repeats
  that POST on a `--interval-ms` cadence until stopped, with a bounded jittered
  exponential backoff on transient failure and an optional `--max-posts` bound for
  supervised/bounded runs (`--allow-insecure-http` is available only for local/dev
  loopback HTTP center testing). `run` shuts down cleanly (exit `0`) on SIGINT/SIGTERM
  after finishing the in-flight heartbeat, so a systemd/launchd stop is graceful rather
  than a hard kill; one-shot commands use stable exit codes (`0` ok, `1` dial-out POST
  failed, `2` config/usage error, `3` local-status collection failed). **Prerequisite
  #3 (core-side shipping-aware rotation) is done** — `src/audit.zig`'s
  `rotateGenerational` retains numbered `audit.jsonl.<gen>` segments bounded by
  `[audit].max_retained_generations`, with evictions past the cap durably recorded
  in `audit.jsonl.gaps.jsonl` (#187) — but audit-log **shipping itself remains
  unimplemented**, so it stays deferred within E1: there is still no dial-out path,
  ack protocol, or `edge.ship_audit` wiring in `src/edge_main.zig`. Until that lands,
  E1 ships counts, not bodies, and `edge.ship_audit` is off by default. The opt-in `node`
  capability descriptor (`--report-capabilities`, off by default; `--label` / `--skill` and the
  `SCOOT_EDGE_LABELS` / `SCOOT_EDGE_SKILLS` env vars feed it) may ride the heartbeat
  for later capability-aware routing — advisory only, never authority.
- **E2: ✅ Implemented (#186).** Schema'd, idempotent job dispatch behind explicit
  config + policy ceiling + provenance auditing. `scoot-edge dispatch` (one-shot) and
  `scoot-edge run --enable-jobs` (folded into the heartbeat loop) both require
  `--job-root` and `--lease-url`; either missing, or `--lease-url` not HTTPS (absent
  `--allow-insecure-http` for loopback dev), dies with exit `2` — the same
  fail-closed config gate as `--center-url`/token. Each cycle: `GET`s the lease,
  schema-validates every envelope (`validateJobEnvelope`; a job that fails to parse
  or fails validation is reported `rejected`/`bad_schema` with no execution),
  trims any excess beyond `--lease-capacity` to `at_capacity`, checks the bounded
  `idem.jsonl` store for a prior final outcome (a redelivered `idem_key` re-acks the
  stored result instead of re-running), and otherwise executes via
  `scoot --unattended -e "<goal>" --session-id job-<job_id>` with cwd confined to
  `--job-root`. Every phase transition (`accepted` → `done`/`failed`/`rejected`) is
  both POSTed as a `job_event` and appended to `logs/edge-audit.jsonl`, correlated by
  `session_id` to Scoot's own run audit. Edge jobs default `readonly`; the only raise
  is local `edge.max_job_policy = unrestricted`. Capability-aware routing consumes
  the E1 `node` descriptor; a job a node cannot satisfy rejects with
  `no_matching_capability` — a center-side decision, since capability matching
  happens before a job is ever dispatched to this node.
- **E3: partially implemented.** Packaging: `install.sh` gained an opt-in
  `SCOOT_INSTALL_EDGE` variable (still never installed by default), and the
  release workflow now builds, archives (`scoot-edge-<target>.tar.gz`), and
  publishes a `scoot-edge` Homebrew formula (`brew install
  jamiesun/tap/scoot-edge`, depending on `scoot`) alongside every tagged
  release, mirroring the existing `scoot-wasm` packaging. An apt package is
  not yet built — there is no apt packaging for any Scoot binary in this repo
  today, so it remains tracked as open scope rather than mirrored from an
  existing pattern. Reconnect/backpressure hardening is done: `run`'s bounded
  jittered exponential backoff already covers heartbeat *and* dispatch-cycle
  failures (a lease/telemetry error only affects that iteration, never
  crashes the loop), and `--lease-capacity` provides dispatch-side
  backpressure (`at_capacity`) the same way the heartbeat loop already
  backs off on transient failure.
