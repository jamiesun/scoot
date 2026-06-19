# Skills

Scoot skills are local directories that add task-specific instructions without
adding a privileged execution path.

## Directory Shape

```text
my-skill/
  SKILL.md
  scripts/
  references/
```

Only `SKILL.md` is required. `scripts/` and `references/` are optional and are
still subject to the normal tool policy gates when used.

## Search Paths

Skills are discovered from these locations, in priority order (earlier wins on
name collision):

1. `<cwd>/.agents/skills` — project-local, travels with the repository.
2. `~/.agents/skills` — cross-agent user-level skills, only when `[skills] include_agents_skills = true`.
3. `~/.scoot/skills` — Scoot's own user-level skill directory.
4. Any `extra_paths` declared in `[skills]` of the config.

`scoot skills` prints the resolved search paths and everything discovered.

## Activation

Discovery injects only each skill's `name` + `description` (progressive
disclosure keeps the context small). When a skill is relevant, the model reads
its `SKILL.md` with the native **`skill` action** — `{"name":"<skill>"}` (or
`{"name":"<skill>","path":"references/x.md"}` for other resources in the skill
directory).

Reading a skill is a native, read-only agent capability and is **not** subject
to the execution policy: it works even in `readonly` mode (which otherwise
blocks `bash`). Reads are confined to the skill's own directory — absolute paths,
`..` escapes, and symlinks that resolve outside the skill directory are all
rejected — and are still audited as tool calls.

## Front Matter

`SKILL.md` starts with YAML-style front matter:

```yaml
---
name: metadata
description: Demonstrates review metadata for a local Scoot skill.
capabilities: [instructions, references]
allowed_tools: [file_read, grep, glob]
scope: workflow
---
```

Required fields:

- `name`: ASCII letters, digits, `.`, `_`, and `-`, up to 64 bytes.
- `description`: a short, non-empty summary used during skill discovery.

Optional review metadata:

- `capabilities`: inline list using `instructions`, `scripts`, and
  `references`.
- `allowed_tools`: inline list of expected built-in tool actions:
  `bash`, `file_read`, `file_write`, `file_edit`, `grep`, `glob`,
  `outline`, `http_request`, `skill`, `recall`, and `parallel`.
- `scope`: one of `general`, `project`, `repository`, `domain`, or `workflow`.

Compatibility fields such as `scoot_version`, `compatibility`, and
`requires_scoot` are intentionally rejected until Scoot defines version gates.

## Commands

Validate one skill:

```sh
scoot skills check path/to/my-skill
```

Validate configured skill search paths:

```sh
scoot skills check
```

Package a skill for review:

```sh
scoot skills pack path/to/my-skill my-skill.scoot-skill.tar
```

The package includes a `.scoot-skill.json` manifest containing metadata, file
entries, size information, and the policy note that skill instructions and
scripts do not bypass Scoot policy gates.

## Policy Boundary

Skill metadata is declarative. `allowed_tools` describes expected tool use for
reviewers; it does not grant permissions.

Reading a skill's instructions and resources is a native, read-only capability
and bypasses the policy gate by design (so skills remain usable in `readonly`).
Everything a skill then tells the model to *do* — `bash`, file writes, network
requests, running `scripts/` — still goes through the same global policy checks
as ordinary model tool calls. Reading the skill is free; acting on it is gated.

### What this means for the `readonly` read surface

`readonly` normally confines reads to the project working directory via
`policy.evaluateReadPath` (no absolute paths, no `..`, no common sensitive path
fragments). The `skill` action is the one deliberate exception: because it is
policy-exempt, it can read **any file under a registered skill directory**, in
addition to the `evaluateReadPath`-gated project reads. The registered skill
directories are the same four search roots listed above:

1. `<cwd>/.agents/skills`
2. `~/.agents/skills` when `[skills] include_agents_skills = true`
3. `~/.scoot/skills`
4. any `extra_paths` declared in `[skills]`

Reads through the `skill` action remain confined to the matched skill's own
directory (absolute paths, `..`, and symlinks resolving outside the directory are
rejected). The practical implication for unattended / `readonly` runs: **only
install skills you trust.** A malicious or compromised skill package can expose
the contents of its own directory to the model even under `readonly` — this is an
intended part of the read boundary, not a bypass, so do not treat `readonly` as a
sandbox against untrusted skills.
