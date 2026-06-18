# Execution Policy & Security

Scoot never lets unvalidated model output reach your system directly. Every tool
action passes through a **policy gate** before it runs. This page explains the
three modes, the decision model, the opt-in hardening, and — honestly — what the
policy does and does **not** protect you from.

## The Three Modes

Ordered from least to most restrictive: `unrestricted` < `guarded` < `readonly`.

| Mode | Shell (`bash`) | Local writes | Network | Local reads | Use when |
| --- | --- | --- | --- | --- | --- |
| `unrestricted` | allowed | allowed | allowed | allowed | You fully trust the goal; still audited. |
| `guarded` *(default)* | allowed except catastrophic | allowed | allowed | allowed | Interactive use with a human watching. |
| `readonly` | **denied** | **denied** | **denied** | allowed (confined) | Unattended/untrusted; fail-closed safety. |

Set the mode in config (`[tools] policy = "..."`) or test any action with
`scoot policy check`. Unknown values fall back to `guarded` (a bad config must
never *loosen* the gate). `yolo` is an alias for `unrestricted`.

## What Each Mode Does

### `guarded` — interactive tripwire

`guarded` is the default for interactive CLI/REPL use. It is **not a sandbox**.
It is a tripwire: a denylist of catastrophic shell commands. Ordinary work is
allowed so you can actually get things done with a human watching.

`bash` commands are normalized (whitespace collapsed, lowercased — defeating
tricks like `rm  -RF   /`) and rejected if they match a deliberately tight
catastrophic list, including:

- recursive root/home/`*` deletes (`rm -rf /`, `rm -rf ~`, `rm -rf *`, `--no-preserve-root`),
- disk/filesystem destroyers (`mkfs`, `dd ... of=/dev/...`, `> /dev/sd...`),
- pipe-to-shell remote execution (`| sh`, `| bash`),
- power-state changes (`shutdown`, `reboot`, `poweroff`, `halt`, `init 0/6`),
- a fork bomb, and reckless `chmod 777 /` / recursive `chown`.

Built-in tools (`file_*`, `grep`, `glob`, `http_request`) are allowed in
`guarded`; they have no "delete the whole disk" equivalent and are bounded by
their own path/size/timeout limits.

### `readonly` — fail-closed safety primitive

`readonly` is the **real** safety boundary and the structural prerequisite for
unattended jobs. It fail-closes:

- **`bash` is denied entirely** — shell composition is too broad to whitelist;
  use `file_read`/`grep`/`glob` instead.
- **All writes are denied** (`file_write`, `file_edit`).
- **All network is denied** — even read-style `GET`/`HEAD`, to prevent
  exfiltrating local data through a request URL.
- **Local reads are allowed but path-confined** (see below).
- Catastrophic shell patterns are still rejected on top of the blanket `bash`
  denial.

In `readonly`, local read paths are additionally checked: no absolute paths, no
`~`/`$VAR` expansion, no `..` escapes, and a refusal of common **sensitive
fragments** (`.env`, `.ssh`, `id_rsa`, `id_ed25519`, `.netrc`, `credentials`,
`secret`, `token`, …). This keeps reads inside the project working directory and
away from obvious secret files.

### `unrestricted` — no limit, still audited

No policy restriction at all (alias `yolo`). Every action is still written to the
audit log, but nothing is blocked. Use it only when you fully trust the goal.

## The `skill` Action Is Native

Reading a skill's instructions/resources via the [`skill` action](skills.md) is a
**native, read-only capability that intentionally bypasses the policy gate** —
so skills stay usable even in `readonly`. Safety is enforced in execution
(directory confinement, audited reads), not by policy. Everything a skill then
tells the model to *run* (shell, writes, network) goes through the normal gate.

Because it bypasses the gate, the `skill` action **widens the `readonly` read
surface**. Beyond the `evaluateReadPath`-gated reads above (project-cwd,
non-sensitive, no `..`/absolute), it can read **any file under any registered
skill directory**:

1. `<cwd>/.agents/skills`
2. `~/.agents/skills` when `[skills] include_agents_skills = true`
3. `~/.scoot/skills`
4. `extra_paths` declared in `[skills]`

Each read is still confined to the matched skill's own directory (absolute
paths, `..`, and symlinks that resolve outside that directory are rejected) and
audited. The practical consequence for unattended/`readonly` runs: **only
install skills you trust.** A tampered or malicious skill bundle can expose its
own directory contents to the model even under `readonly` — this is part of the
defined read boundary, not a bypass, so do not treat `readonly` as a sandbox
against untrusted skills.

## Opt-in Hardening (guarded only)

Two flags tighten `guarded` mode. Both default to `false` and apply **only in
`guarded`** (`readonly` already fail-closes writes and network).

### `confine_writes`

Keeps `file_write`/`file_edit` inside the project root: rejects absolute paths,
`..` escapes, and shell-style `~`/`$VAR` expansion. This blocks an untrusted
model from writing to e.g. `$HOME/.ssh/authorized_keys`. It does **not** reject
sensitive *names* — inside the project, the risk is location escape, not naming.

```toml
[tools]
policy = "guarded"
confine_writes = true
```

### `block_internal_http`

An SSRF guard: rejects `http_request` to loopback, private, link-local, and
cloud-metadata addresses. It is a **heuristic** over literal IP ranges and known
internal names — it does **not** resolve DNS, so DNS-rebinding can still bypass
it. For real network isolation use `readonly` or an external network sandbox.

```toml
[tools]
policy = "guarded"
block_internal_http = true
```

## Decision Model

Two complementary checks share the same `Mode` semantics:

- **Shell commands** (`bash`) are analyzed as strings: normalized, matched
  against the catastrophic denylist, then allowed (`guarded`) or denied
  (`readonly`).
- **Built-in tools** are classified by *capability* — `read`, `write`,
  `net_read`, `net_write` — because their semantics are statically known without
  parsing a command string. This is why the gate doesn't grow more complex as
  tools are added: a new read tool reuses the `read` decision. It also
  guarantees built-in tools **cannot bypass `readonly`**.

## Honest Threat Model

Read this before relying on Scoot in a hostile setting:

- **`guarded` is not a security boundary.** A denylist can always be worked
  around by a determined or adversarial prompt. Don't derive false confidence
  from it — it's there to catch *accidents* and obvious catastrophes with a human
  present.
- **`readonly` is the fail-closed primitive.** It denies shell, writes, and
  network by construction, and is what makes unattended execution defensible.
  Prefer it for any untrusted goal, scheduled job, or daemon.
- **Real isolation still needs the OS.** For strong guarantees, combine
  `readonly` with OS-level sandboxing (containers, seccomp, network namespaces,
  read-only mounts). Scoot's policy is defense-in-depth, not a jail.

## Scheduled Jobs Are Coerced

Unattended jobs enforce safety structurally: a job configured as `guarded` is
**coerced to effective `readonly`** at execution time. `unrestricted` must be
set explicitly in the job config if you accept the risk. See
[Scheduling & Daemon](scheduling.md).

## Inspecting Decisions

Use `policy check` to dry-run any action against any mode — nothing executes:

```sh
scoot policy check bash "rm -rf /"                  --mode guarded   # deny
scoot policy check bash "ls -la"                    --mode readonly  # deny
scoot policy check file_write '{"path":"/etc/x"}'   --mode readonly  # deny
scoot policy check file_read  '{"path":"README.md"}' --mode readonly # allow
scoot policy check http_request '{"method":"GET","url":"http://169.254.169.254/"}' --mode guarded
```
