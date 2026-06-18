# Skills

A **skill** is a local directory of task-specific instructions that extends what
the agent knows how to do — **without** adding a privileged execution path. The
canonical reference (front-matter fields, packaging, validation rules) is
[`docs/SKILLS.md`](https://github.com/jamiesun/scoot/blob/main/docs/SKILLS.md); this page is the practical overview.

## What A Skill Looks Like

```text
my-skill/
  SKILL.md          # required: front matter + instructions
  scripts/          # optional helper scripts
  references/       # optional reference material
```

Only `SKILL.md` is required. `scripts/` and `references/` are optional, and when
*used* they go through the normal tool policy gates like any other action.

`SKILL.md` begins with YAML-style front matter:

```yaml
---
name: metadata
description: Demonstrates review metadata for a local Scoot skill.
capabilities: [instructions, references]
allowed_tools: [file_read, grep, glob]
scope: workflow
---

# Instructions

...the full operating instructions the model loads on demand...
```

- **`name`** (required): ASCII letters, digits, `.`, `_`, `-`, up to 64 bytes.
- **`description`** (required): short, non-empty summary used during discovery.
- **`capabilities` / `allowed_tools` / `scope`** (optional): declarative *review*
  metadata. `allowed_tools` documents expected tool use for a reviewer — it does
  **not** grant any permission.

Compatibility fields like `scoot_version` / `requires_scoot` are intentionally
rejected until Scoot defines version gates.

## Search Paths

Skills are discovered in **priority order** (earlier wins on a name collision):

1. `<cwd>/.agents/skills` — project-local, travels with the repository.
2. `~/.agents/skills` — cross-agent user-level skills, only when `[skills] include_agents_skills = true`.
3. `~/.scoot/skills` — Scoot's own user-level directory.
4. any `extra_paths` from `[skills]` in your config.

`scoot skills` prints the resolved paths and everything discovered. Configure
extra locations via [`[skills]`](configuration.md#skills).

## Progressive Disclosure

To keep the context small, discovery injects only each skill's `name` +
`description`. The full `SKILL.md` body is **never** preloaded. When a skill is
relevant, the model loads it on demand with the native **`skill` action**:

```json
{ "name": "my-skill" }                                  // reads SKILL.md
{ "name": "my-skill", "path": "references/guide.md" }   // reads another file
```

## Reading Is Native; Acting Is Gated

This is the core security property:

- **Reading a skill is free.** The `skill` action is a native, read-only
  capability that **bypasses the execution policy by design**, so skills work
  even in `readonly` (where `bash` is denied). Reads are confined to the skill's
  own directory (absolute paths, `..`, and symlinks that resolve outside the
  directory are rejected), unknown names return a
  recoverable observation, and every read is audited.
- **Acting on a skill is gated.** Everything the skill then tells the model to
  *do* — run `bash`, write files, make network requests, execute `scripts/` —
  goes through the **same** policy checks as any ordinary tool call. A skill gets
  no special privileges.

See [Execution Policy & Security](policy.md) for the gate, and the [Agent
Guide](agent.md) for the iron rule.

## Commands

```sh
scoot skills                          # list discovered skills + search paths
scoot skills check path/to/my-skill   # validate one skill (no scripts run)
scoot skills check                    # validate all configured search paths
scoot skills pack path/to/my-skill my-skill.scoot-skill.tar
```

`skills check` validates structure without executing anything. `skills pack`
exports a tar with a `.scoot-skill.json` review manifest (metadata, file entries,
sizes, and a policy note that skill scripts do not bypass the policy gate while
reading instructions is a native confined read).

Starter templates: [`docs/examples/skills/minimal`](https://github.com/jamiesun/scoot/blob/main/docs/examples/skills/minimal/SKILL.md)
and [`docs/examples/skills/metadata`](https://github.com/jamiesun/scoot/blob/main/docs/examples/skills/metadata/SKILL.md).
