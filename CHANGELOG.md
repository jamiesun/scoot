# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is the single source of truth in
[`build.zig.zon`](build.zig.zon); the release workflow turns the section for a
tag into the published GitHub release notes (see
[`.github/workflows/release.yml`](.github/workflows/release.yml)). Keep an
`Unreleased` section at the top and move its entries under a new `## [X.Y.Z]`
heading when cutting a release.

中文版本见 [docs/CHANGELOG.zh.md](docs/CHANGELOG.zh.md)。

## [Unreleased]

### Added

- Release workflow now publishes explicit `ReleaseSmall` assets with `-small`
  suffixes for every supported target.
- Installer supports `SCOOT_INSTALL_FLAVOR=small` to select the small release
  artifact instead of the default `ReleaseSafe` artifact.
- Native `recall` action can retrieve exact earlier messages from the current
  session transcript archive after active context compaction (#99).
- Stable embedding API surface now separates the public package root from the
  CLI/internal module and includes a compiled minimal embed example (#106).
- `backend.store` config key and `SCOOT_BACKEND_STORE` override to opt into
  Responses API server-side response persistence; defaults to off so Scoot
  stays stateless and local-first (#110).

### Changed

- Scoot now speaks only the OpenAI Responses API (`/v1/responses`): leading
  system messages map to the top-level `instructions` field, the rest become the
  `input` array, and transport is stateless by default (full `input` resent each
  turn) so local context compaction stays in control. Requires a Responses-capable
  backend such as Ollama >= 0.13.3, vLLM, or OpenAI (#110).
- Context compaction now goes through a `Compressor` strategy seam with `drop`
  retained as the smallest fallback strategy (#97).
- Added the built-in `extractive` compactor and `agent.compactor` /
  `SCOOT_AGENT_COMPACTOR` selection (#97).

### Removed

- OpenAI Chat Completions transport, the `backend.api` selector, and the
  `SCOOT_BACKEND_API` override; the Responses API is now the only transport.
  Configs that still set `api` are ignored with a one-line deprecation warning
  (#110).
- The `backend.prompt_cache` hint and `SCOOT_BACKEND_PROMPT_CACHE` override
  (with the Anthropic-style `cache_control` breakpoint); the `instructions`
  field is natively prompt-cached, so the manual hint is obsolete. Stale keys are
  ignored with a deprecation warning (#110).

### Fixed

- `-e` and REPL runs now get per-process session transcript ids instead of
  appending every run to shared `cli.jsonl` and `repl.jsonl` files (#95).
- Default agent configuration now enables a conservative context budget with
  `extractive` compaction, while `context_budget_bytes = 0` still explicitly
  disables the guard (#96).

## [0.2.0] - 2026-06-19

### Added

- `SCOOT_*` environment overrides for zero-config and CI runs (#67)
- Windowed `file_read` support with offset/limit line ranges (#78)
- Context compaction at the configured context budget instead of aborting the run (#81)
- Optional grep context lines around matches (#82)
- Config-gated prompt-cache breakpoint for stable model prompts (#84)
- Zero-dependency `outline` action for low-token file skeletons (#85)
- POSIX release installer that downloads, verifies, and installs the matching binary (#90)
- Run summaries on stderr after CLI/REPL runs, including event counts, tool calls, policy denies, backend status, and transcript path (#59)
- Minute-level 5-field UTC cron scheduling for `schedule.jobs` (#65)

### Changed

- `~/.agents/skills` discovery is now opt-in while project-local and Scoot-local skills remain enabled (#87)
- Repeated read-only observations are deduplicated within a run (#83)
- Agent observations are token-optimized by stripping ANSI, using head/tail windows, and enforcing token caps (#80)
- Per-turn thoughts are no longer persisted in run history (#79)
- Runtime directories and JSONL audit/session files now use owner-only permissions, and JSONL files rotate to `.1` at a bounded size (#60, #61)
- GitHub workflows now use Node 24-compatible actions and shell-based Zig setup (#63)
- `build_options` is imported by the executable root module as well as the library module (#64)
- `parseStep` now tolerates compatibility backends that wrap the step JSON in a Markdown code fence or emit multiple concatenated JSON objects, executing only the first step while keeping single-step ReACT semantics

### Fixed

- Language switching now lives in the mdBook navigation icon bar (#86)
- Invalid enum-like `SCOOT_*` overrides now warn and keep the previous value instead of silently changing policy/mode/level (#68)
- `confine_writes` now rejects a pre-existing symlink at the final write path component (#69)

### Documentation

- Added maintained changelogs and made release notes derive from them (#66)
- Improved README and user-guide structure, including installer docs, design philosophy, best-practice cases, and daemon/run-mode guidance (#90)
- Added Scoot logo and favicon assets, plus an animated documentation landing mark (#91)
- Folded the logo into the README/mdBook infographic and removed duplicate standalone logo blocks (#92)

## [0.1.0] - 2026-06-18

First feature release since `v0.0.2` (which only carried release-workflow plumbing).

### Added

- CLI trace output and `--trace` in the interactive REPL (#7, #48)
- Live "thinking"/"running" trace markers so `--trace` never looks frozen (#56)
- `doctor` and policy `check` commands (#10)
- `scoot` home override flag (#11)
- Skill validation, skill pack export, and skill review metadata (#15, #17, #21)
- Native skill reading with expanded skill search paths (#35)
- Bounded parallel read tools (#16)
- wasm tool package boundary (#20)
- Daemon lifecycle commands (#33)

### Fixed

- Readonly policy default hardening and constrained read paths (#13, #14)
- Retry transient eval backend failures (#18)
- Resolved all open issues #22–#54 (#34, #49, #55)
- Version is now derived from `build.zig.zon` instead of hardcoded; release builds embed the tag (#57)

### Documentation

- Polished homepage/license metadata, infographic, bilingual user guide (#6, #19, #36)

[Unreleased]: https://github.com/jamiesun/scoot/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jamiesun/scoot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jamiesun/scoot/compare/v0.0.2...v0.1.0
