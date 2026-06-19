# Design Philosophy

Scoot is intentionally conservative. It is not trying to be the most capable AI
automation platform; it is trying to be a small, local, inspectable agent runtime
that can safely touch real machines.

Some things that look like missing features are deliberate choices. A missing
GUI, a foreground daemon, strict `readonly` behavior, or the lack of
provider-specific protocol glue are not accidents; they keep the system small,
auditable, and predictable. Real bugs should still be reported, but requests
that cross the boundaries below require a project-level decision.

## What Scoot Optimizes For

Scoot optimizes for these properties, in this order:

1. **Safety and controllability.** Invalid or unsafe model output is rejected
   before it reaches the system.
2. **Auditability.** A run should be explainable after the fact: goal, model
   step, tool call, policy decision, observation, and final answer.
3. **Local-first operation.** Config, sessions, skills, logs, and daemon state
   live on the user's machine.
4. **Small deployment surface.** One native binary, plain text config, and few
   moving parts matter more than broad feature count.
5. **Long-running stability.** Daemon and scheduled workloads must stay bounded
   and recover conservatively.

When these goals conflict, Scoot prefers the earlier item. That means Scoot may
reject work that a more permissive agent would attempt.

## Goals

Scoot should be:

- **A terminal-native agent.** Use `-e`, REPL, schedule, and daemon modes from
  the shell.
- **A policy-gated local executor.** File, search, shell, HTTP, skill, and
  parallel actions are validated and routed through explicit policy decisions.
- **OpenAI-compatible at the boundary.** Local and hosted backends work as long
  as they speak the OpenAI-compatible `chat/completions` shape.
- **Useful on small machines.** The Zig implementation, low dependency count,
  explicit allocation, and cross-compilation story are meant to fit edge hosts,
  NAS boxes, lab machines, and small servers.
- **Extensible through instructions, not native plugins.** Skills add reviewed
  instruction bundles and resources without recompiling Scoot.
- **Safe enough for unattended read-only jobs.** Scheduled work defaults to
  `readonly`, and `guarded` is coerced to effective `readonly` when nobody is
  watching.

## Non-Goals

These are not backlog items; they are boundaries:

- **No GUI or web dashboard.** Scoot is a CLI and daemon, not a desktop app or
  browser console.
- **No provider-specific protocol sprawl.** Scoot does not grow one adapter per
  model vendor. Provider differences belong behind an OpenAI-compatible gateway.
- **No complex cloud sync.** Runtime state stays local; Scoot is not a hosted
  multi-device control plane.
- **No execution of unvalidated model output.** Free-form model text never
  becomes a shell command or tool call directly.
- **No native plugin runtime.** Skills are instructions and resources; they do
  not become dynamically loaded native code with new privileges.
- **No plaintext secret convenience.** Tokens do not belong in committed config,
  logs, audit output, or examples.
- **No pretending `guarded` is a sandbox.** `guarded` is an interactive tripwire.
  Use `readonly` and OS isolation for unattended or hostile contexts.

## Iron Laws

1. **Validate before effect.** Every model step is parsed and checked before any
   tool runs.
2. **Policy gates all effects.** Shell, writes, network, and native tool actions
   must pass the active policy.
3. **Timeout external work.** Subprocesses and network calls must not hang the
   agent indefinitely.
4. **Keep secrets out of text artifacts.** Config, logs, sessions, errors, and
   docs must not expose tokens.
5. **Prefer `readonly` for unattended work.** Scheduled `guarded` jobs are
   corrected to effective `readonly`.
6. **Skills do not grant privileges.** Reading a skill is native and read-only;
   anything it asks Scoot to run still goes through normal policy.
7. **Keep docs bilingual.** User-visible documentation changes must be reflected
   in English and Chinese.

## Apparent Limitations That Are Choices

| What you may notice | Why it exists |
| --- | --- |
| There is no GUI. | Text interfaces are scriptable, reviewable, and fit small hosts. |
| `daemon run` stays in the foreground. | Supervisors like systemd should own backgrounding, restart, logs, and shutdown. |
| `readonly` blocks shell and network. | A fail-closed unattended mode must prevent mutation and data exfiltration. |
| `guarded` is not advertised as secure isolation. | Denylists catch accidents; they are not a sandbox against adversarial goals. |
| There are no vendor-native tool-calling integrations. | The model boundary stays OpenAI-compatible and schema-driven. |
| Skills are local directories, not plugins. | Instructions can extend behavior without expanding the native trusted surface. |
| There is no vector-memory subsystem. | Local JSONL state and skills keep history inspectable and avoid heavy dependencies. |
| Network probes require explicit risk acceptance. | Probes can be useful, but they need OS/network isolation before broad permissions. |

The right question for a new feature is not "can Scoot do this?" It is "can
Scoot do this while staying local-first, auditable, small, and policy-gated?"
