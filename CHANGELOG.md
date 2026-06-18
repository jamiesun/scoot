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

- Run summaries on stderr after CLI/REPL runs, including event counts, tool calls, policy denies, backend status, and transcript path (#59)
- Minute-level 5-field UTC cron scheduling for `schedule.jobs` (#65)

### Changed

- Runtime directories and JSONL audit/session files now use owner-only permissions, and JSONL files rotate to `.1` at a bounded size (#60, #61)
- GitHub workflows now use Node 24-compatible actions and shell-based Zig setup (#63)
- `build_options` is imported by the executable root module as well as the library module (#64)

### Fixed

- Invalid enum-like `SCOOT_*` overrides now warn and keep the previous value instead of silently changing policy/mode/level (#68)
- `confine_writes` now rejects a pre-existing symlink at the final write path component (#69)

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

[Unreleased]: https://github.com/jamiesun/scoot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jamiesun/scoot/compare/v0.0.2...v0.1.0
