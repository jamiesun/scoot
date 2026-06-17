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
  `http_request`, and `parallel`.
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
reviewers; it does not grant permissions. Runtime execution still goes through
the same global policy checks as ordinary model tool calls.
