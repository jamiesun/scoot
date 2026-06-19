# AGENT.md

Engineering guidance for AI agents and contributors working in this repository.

Read this file before making changes. Then read the roadmap:

- English: [docs/ROADMAP.md](docs/ROADMAP.md)
- Chinese: [docs/ROADMAP.zh.md](docs/ROADMAP.zh.md)

The roadmap is the source of product intent and non-goals. This file is the implementation handbook.

## Documentation Language Policy

All project documentation updates must be synchronized in both English and Chinese.

- Root documentation is English by default.
- Chinese project documentation lives under `docs/` with `.zh.md` suffixes.
- Code comments, code strings, and test descriptions default to English.
- Future GitHub issues and pull requests default to English.
- If you update `AGENT.md`, update [docs/AGENT.zh.md](docs/AGENT.zh.md).
- If you update `README.md`, update [docs/README.zh.md](docs/README.zh.md).
- If you update [docs/ROADMAP.md](docs/ROADMAP.md), update [docs/ROADMAP.zh.md](docs/ROADMAP.zh.md).
- mdBook content under `book/en` and `book/zh` must stay consistent enough that navigation, scope, commands, and safety rules match across languages.

## One-Line Project Positioning

Scoot is a lightweight AI agent daemon and CLI written in pure Zig 0.16+. It is local-first, defensive, auditable, and intentionally small. Its core loop is ReACT: a model emits structured steps, Scoot validates them, applies execution policy, runs built-in tools, records audit events, and feeds observations back until a final answer is produced.

The project already has the core pillars in place:

- ReACT execution for `scoot -e` and the default REPL.
- Built-in tools: `bash`, `file_read`, `file_write`, `file_edit`, `grep`, `glob`, `outline`, and `http_request`.
- Execution policy: `guarded`, `readonly`, and `unrestricted`.
- Local skill discovery with progressive disclosure.
- Scheduled unattended jobs with effective `readonly` mode by default.
- Local config, sessions, audit logs, and secret loading from env/file/command.

## Common Commands

```sh
zig build
zig build run -- --version
zig build test
zig build -Doptimize=ReleaseSmall
zig build -Doptimize=ReleaseSafe
```

After changing any `.zig` file, run at least:

```sh
zig build
zig build test
```

For documentation:

```sh
mdbook build book/en
mdbook build book/zh
mkdir -p site
cp book/site-index.html site/index.html
```

## Code Map

| Path | Responsibility |
| --- | --- |
| `src/main.zig` | CLI entrypoint: argument parsing, REPL, one-shot eval, config, skills, schedule |
| `src/root.zig` | Library root and public subsystem exports |
| `src/paths.zig` | Runtime directory resolution: `~/.scoot` or `SCOOT_HOME` |
| `src/config.zig` | Structured config: backend, agent, tools, skills, audit, schedule |
| `src/toml.zig` | Zero-dependency TOML subset parser |
| `src/secret.zig` | Secret loading from env, 0600 token file, or credential command |
| `src/llm.zig` | OpenAI-compatible Responses API (`/v1/responses`) client with strict JSON schema output |
| `src/jsonio.zig` | Shared JSON string escaping |
| `src/skill.zig` | Skill discovery and progressive disclosure |
| `src/session.zig` | Short-term session message storage and JSONL persistence |
| `src/agent.zig` | ReACT loop, action parsing, tool execution, observation feedback |
| `src/schedule.zig` | `every`, `at`, and 5-field UTC `cron` schedule triggers |
| `src/audit.zig` | JSONL audit events |
| `src/policy.zig` | Execution policy gate |
| `src/tools/*.zig` | Built-in tools and execution sandbox |
| `build.zig`, `build.zig.zon` | Zig build graph and package manifest |

When adding a subsystem, add a file under `src/` and export it from `src/root.zig` with `pub const name = @import("name.zig");` so it participates in the test graph.

## Zig 0.16 Habits

This repository targets Zig 0.16+. Do not copy old 0.11-0.14 idioms.

- Entrypoint: `pub fn main(init: std.process.Init) !void`.
- Process allocator: `const arena = init.arena.allocator();`.
- Args: `const args = try init.minimal.args.toSlice(arena);`.
- I/O uses `init.io`; pass `std.Io` explicitly into filesystem and process helpers.
- `std.ArrayList(T)` is unmanaged: initialize with `.empty`, and pass the allocator to methods.
- Environment variables come from `init.environ_map.get("KEY")`.
- Each module should include `test { std.testing.refAllDecls(@This()); }`.

## Memory Discipline

Long-running stability matters more than feature count.

- Use per-turn arenas for temporary ReACT work.
- Keep session history in a longer-lived backing allocator.
- Do not allocate per-turn JSON, request, or response scratch data in long-lived storage.
- Add explicit `deinit` only where ownership is not naturally process-scoped or arena-scoped.

## Runtime, Config, Secrets, And Skills

- Runtime state belongs under `~/.scoot/`, or under `SCOOT_HOME` when overridden.
- Config files are `config.toml` first, `config.json` second.
- Never add inline plaintext API keys to config.
- Secret priority is env, then 0600 token file, then credential command.
- Skill directories contain `SKILL.md` with front matter. Discovery reads only name and description; full instructions are loaded only when relevant. Search order: `<cwd>/.agents/skills` > optional `~/.agents/skills` (`skills.include_agents_skills=true`) > `~/.scoot/skills` > configured `extra_paths`.
- Reading a skill's instructions/resources is a native, read-only capability (the `skill` action), confined to the skill directory and audited, and is intentionally not policy-gated — so skills stay usable in `readonly`. Skill *scripts and commands* get no special privileges: they run through the same tool sandbox and policy gates as normal actions.
- Sessions are short-term memory only. Do not introduce vector databases or long-term semantic memory without first revisiting the roadmap.

## Hard Rules

Changing these boundaries requires an explicit roadmap-level decision.

1. No GUI, web UI, tray app, or desktop app.
2. Only the OpenAI-compatible Responses API (`/v1/responses`) shape is supported. Do not add Chat Completions or provider-specific protocol glue.
3. No complex cloud sync. State stays local.
4. Never execute unvalidated model output.
5. Do not trade the small single-binary design for feature count.
6. Every subprocess and network path must have a hard timeout.
7. Secrets must never be compiled in, committed, printed, or written to audit logs.
8. Skill *execution* must not bypass the registered tool sandbox. (Reading a skill's instructions/resources is a native read-only capability, confined to the skill directory and audited, and is intentionally outside the policy gate.)
9. Documentation changes must be bilingual.

## Extension Workflow

1. Check [docs/ROADMAP.md](docs/ROADMAP.md) before adding capability.
2. Identify whether the work extends an existing subsystem or needs a new one.
3. Add focused tests with the smallest behavioral surface that proves the change.
4. Validate inputs before executing external effects.
5. Run `zig build` and `zig build test`.
6. Update English and Chinese documentation together.

## Style

- Keep changes scoped. Do not refactor unrelated files.
- Prefer existing local abstractions over new architecture.
- Comments, code strings, and test descriptions should default to English; comments explain intent and boundary, not obvious code.
- If code and docs conflict, runnable code and tests are the immediate source of truth, then docs must be corrected in both languages.
