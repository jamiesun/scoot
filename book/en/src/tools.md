# Built-in Tools

Every turn, the model must emit exactly one JSON step:

```json
{ "thought": "one-line reasoning", "action": "<action>", "action_input": "<input>" }
```

`action` must be one of the twelve built-in actions below — Scoot never executes
free-form text. Each tool runs inside a sandbox with a **hard timeout**
(`tools.timeout_ms`, default 30 s) and its output is returned to the model as the
next *observation* (clipped to keep the context small). Whether a given action is
allowed depends on the active [execution policy](policy.md).

The structured tools (`file_*`, `grep`, `glob`, `http_request`) need **no
external commands**, so they behave identically on minimal/embedded systems.
Prefer them over shelling out.

## Action Summary

| Action | Purpose | `action_input` | Read-only |
| --- | --- | --- | --- |
| `bash` | Run a POSIX shell command | command string | no |
| `file_read` | Read a file | `{"path":...}` | yes |
| `file_write` | Overwrite/create a file | `{"path":...,"content":...}` | no |
| `file_edit` | Replace an exact text span | `{"path":...,"old":...,"new":...}` | no |
| `grep` | Regex search within a file | `{"pattern":...,"path":...}` | yes |
| `glob` | List files by glob pattern | `{"pattern":...,"root":"."}` | yes |
| `outline` | Structural skeleton of a file | `{"path":...}` | yes |
| `http_request` | One HTTP/HTTPS request | `{"method":...,"url":...,"body":...}` | depends on method |
| `skill` | Read a loaded skill's files | `{"name":...,"path":"SKILL.md"}` | yes (native) |
| `recall` | Search the current session transcript archive | `{"query":...}` or `{"seq":...}` | yes (native) |
| `parallel` | 1–4 concurrent read-only calls | `{"calls":[...]}` | yes |
| `final` | Return the answer and stop | answer text | — |

---

## `bash`

Runs one shell command in a hard-timeout sandbox under POSIX `sh` (`/bin/sh`).
`action_input` is the raw command string; its combined output becomes the next
observation.

- Use **portable POSIX syntax only** — avoid bash-isms like `[[ ]]`, arrays,
  brace expansion `{1..10}`, or `$'...'`.
- stdout and stderr are each captured up to 1 MiB; the observation is clipped.
- Intended for non-interactive, self-terminating commands. **Denied entirely in
  `readonly` mode** and screened for catastrophic commands in `guarded` mode.

Prefer the structured tools for files, search, and HTTP — `bash` is for
everything else.

## `file_read`

```json
{ "path": "src/main.zig" }
```

Reads a file (up to 1 MiB) and returns its content. The observation is clipped
to ~8 KB so large files don't flood the context; read targeted ranges or use
`grep` for big files. Allowed in every policy mode.

## `file_write`

```json
{ "path": "notes.txt", "content": "full new file contents" }
```

Overwrites the file (creating it if absent) with the **complete** new content.
This is a mutating action: **denied in `readonly`**, and in `guarded` mode it can
be confined to the project root via `confine_writes`. See [Policy](policy.md).

## `file_edit`

```json
{ "path": "README.md", "old": "exact unique text", "new": "replacement text" }
```

Replaces one exact text span. **`old` must occur exactly once** in the file — if
you're unsure, `file_read` first to see the precise text. Ambiguous or missing
matches fail cleanly with no change. Same policy treatment as `file_write`.

## `grep`

```json
{ "pattern": "fn main", "path": "src/main.zig" }
```

Line-by-line regex search within a single file; returns matching line numbers and
text. Supported regex subset: `.` `^` `$` `*` `+` `?` `[]` `()` `|` `\d` `\w`
`\s`. **Not** supported: capture-group backreferences, lookaround, lazy
quantifiers. Read-only; allowed in every mode.

Add an optional `context` to also return the **N lines around each hit** (like
`grep -C`), so you can understand a match without a follow-up whole-file read:

```json
{ "pattern": "fn main", "path": "src/main.zig", "context": 3 }
```

Hit lines are marked `lineno:text`, context lines `lineno-text`; adjacent/overlapping
hits are merged and blocks separated by `--`. `context` is clamped to `0..20`.

## `glob`

```json
{ "pattern": "src/**/*.zig", "root": "." }
```

Lists file paths matching a glob under `root` (default `.`). `*` `?` `[]` do not
cross `/`; `**` spans directory levels. Returned paths can be fed directly to
`file_read` or `grep`. Read-only; allowed in every mode.

## `outline`

```json
{ "path": "src/agent.zig" }
```

Returns a compact **structural skeleton** of one file — function and type
signatures, plus Markdown headings — each with its line number, instead of the
whole file. Use it to map an unfamiliar file first, then `file_read` with
`offset`/`limit` to window into the parts you actually need; this avoids dumping
large files into context.

Language handling is a **zero-dependency line heuristic** (no AST / external
parser, keeping Scoot a single self-contained binary): Zig and Markdown use
precise rules; every other language falls back to a keyword-led heuristic
(`def`/`class`/`func`/`function`/`struct`/`type`/`interface`/…), which is
best-effort and may miss type-led definitions (e.g. C/C++). Output is capped at
400 entries (then marked truncated). Read-only; allowed in every mode.

## `http_request`

```json
{ "method": "GET", "url": "https://example.com/api", "body": "optional" }
```

Makes one HTTP/HTTPS request with a hard timeout (never hangs). `method` is one
of `GET`/`POST`/`PUT`/`DELETE`/`HEAD`/`PATCH`; HTTPS is negotiated automatically
(see `backend.ca_file` for custom roots). The response status and body (up to
1 MiB, observation clipped) are returned.

Policy treatment splits by method: read-style (`GET`/`HEAD`) vs write-style
(everything else). **`readonly` blocks network mutations**; `guarded` can block
internal/metadata hosts via `block_internal_http`. See [Policy](policy.md).

## `skill`

```json
{ "name": "demo", "path": "SKILL.md" }
```

Reads a file from a **loaded skill's** directory — `path` defaults to `SKILL.md`,
or point it at another resource like `references/guide.md`. This is a **native,
read-only capability that bypasses the execution policy by design**, so skills
remain usable even in `readonly` (where `bash` is denied).

Safety lives in execution, not policy: reads are confined to the named skill's
directory (absolute paths and `..` rejected), the name must be in the loaded set
(unknown names return a recoverable observation listing what's available), and
every read is audited. Content is returned up to ~32 KB. See [Skills](skills.md).

## `recall`

```json
{ "query": "old error text", "limit": 8 }
```

```json
{ "seq": 12, "context": 2 }
```

Searches the **current session's complete transcript archive** and returns exact
JSONL-style message lines with `seq`, `role`, and `content`. This is native
read-only capability, so it remains available in `readonly` mode.

Use it when context compaction has kept only a summary but the model needs an
earlier exact observation, command, or user instruction. `query` does literal
substring matching; `seq` is 1-based and can include a small surrounding
`context`. `limit` is capped to keep the recall result bounded.

## `parallel`

```json
{ "calls": [
  { "action": "file_read", "input": "{\"path\":\"README.md\"}" },
  { "action": "grep", "input": "{\"pattern\":\"Scoot\",\"path\":\"AGENT.md\"}" }
] }
```

Runs **1–4 independent read-only calls** concurrently, preserving observation
order. Only `file_read`, `grep`, `glob`, `outline`, and HTTP `GET`/`HEAD` are
permitted — `bash`, writes, `skill`, `recall`, and nested `parallel` are
rejected. Every child call still routes through the normal policy gate. Use it
to fan out independent reads in one turn.

## `final`

`action_input` is the answer text for the user. Emitting `final` ends the ReACT
loop. In `-e` mode this text is what's printed to stdout.

## Observations & Truncation

Tool output is fed back as an observation, but each is **clipped** to bound
context growth (roughly: `bash` ~2 KB, `file_read`/`http_request` ~8 KB,
`parallel` ~12 KB, `skill` ~32 KB, `recall` ~16 KB). For large data, narrow your
reads — use `grep`, globbed paths, targeted ranges, or a tighter `recall` query
instead of dumping whole files.
