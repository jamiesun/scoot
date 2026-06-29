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

- Opt-in PreToolUse-style **policy hook** at the unified `guard()` chokepoint
  (`[tools.policy_hook]`). After built-in checks allow an action, an external
  Wasm policy package (manifest kind `policy`, compute-only) may further restrict
  it — allow→deny only, never relaxing a built-in deny. Fail-closed on any
  failure/timeout/invalid output, audited, and reflected by `scoot policy check`.
  Default off (#136).

## [0.5.0] - 2026-06-27

### Added

- Added a committed `playground/` test environment that exercises full action
  coverage end-to-end against a real backend (#161).
- `scoot-wasm` now executes floating-point Wasm (W4): f32/f64 arithmetic
  (add/sub/mul/div), unary ops (abs/neg/ceil/floor/trunc/nearest/sqrt),
  min/max/copysign, ordered comparisons, int/float conversions, and both
  trapping (`iNN.trunc_fMM_s/u`) and saturating (`iNN.trunc_sat_fMM_s/u`)
  truncation, alongside the already-supported bulk `memory.copy`/`memory.fill`.
  NaN results are canonicalized for deterministic output across hosts, while
  abs/neg/copysign preserve exact bit patterns; `nearest` rounds ties to even
  and the zero sign is preserved. The static type validator now type-checks the
  float opcodes too, so float modules load and run end-to-end. A robustness
  suite now feeds truncated, byte-corrupted, and random/hostile module bytes
  through the loader and asserts every input yields a structured load error or
  trap instead of crashing. Full spec-conformant validation beyond the
  supported subset remains a later phase (#100).
- Added a native `wasm_tool` Agent action for compute-only local Wasm packages.
  It validates the package boundary, requires `entry = "_start"` plus
  `policy.toml` granting only `compute`, and runs the configured `scoot-wasm`
  host argv directly instead of giving the model a broad `bash` command.
  With the default host config, Scoot now prefers a sibling `scoot-wasm` next to
  the running `scoot` binary before falling back to PATH.
- Added a copyable Wasm compressor plugin template, a deterministic redactor
  compressor example, and `scripts/check-wasm-examples.sh` to build, validate,
  and smoke-test the example packages.
- `scoot-wasm` now performs a W3 static function-body type validation pass for
  the current host subset before execution. It checks operand/control stack
  shapes, block/loop/if signatures, branch labels, direct and indirect call
  signatures, local/global access, memory/table presence, and immutable globals,
  so malformed type/index errors fail module loading instead of reaching the
  interpreter. Full spec-conformant validation beyond the supported subset is
  still a later phase (#100).
- `scoot-wasm` now runs `wasm32-wasi` command modules over a minimal WASI
  preview1 subset (W2): `scoot-wasm wasi <module.wasm> [args...]` instantiates
  the module, runs `_start`, pipes this process's stdin to fd 0, forwards the
  module's stdout/stderr, and exits with its `proc_exit` status. The exposed
  surface is a pure data-transform sandbox: the only channels are stdin
  (`fd_read`, fd 0), stdout/stderr (`fd_write`, fd 1/2), argv (`args_*`), and
  `proc_exit`. No environment, clock, randomness, filesystem, or network is
  exposed — `environ_*`, `clock_time_get`, `random_get`, and every other WASI
  import trap by construction, so a plugin's output is a pure function of its
  (stdin, argv). Out-of-bounds guest pointers return EFAULT and non-stdio fds
  return EBADF. This is the intended subprocess host for external compression
  plugins (#100).
- `scoot-wasm` now executes integer Wasm functions (W1): a dependency-free Zig
  stack machine with structured control flow (block/loop/if/else/br/br_if/
  br_table/return/call/call_indirect), i32/i64 arithmetic, a bounds-checked
  64 KiB-page linear memory (load/store, memory.size/grow), globals, a funcref
  table, and active data/element segments. Every fault is a structured trap
  (unreachable, divide-by-zero, integer overflow, out-of-bounds memory/table,
  indirect-call type mismatch) bounded by fuel, call-depth, and memory-page
  limits. Invoke with `scoot-wasm run <module.wasm> <export> [int args...]`.
  The engine is compiled only into the standalone `scoot-wasm` binary
  (`-Dwasm-host=true`); the zero-dependency core never links it. Full
  spec-conformant validation beyond the supported subset remains a later
  phase (#100).
- Release workflow now publishes a separate `scoot-wasm-<target>.tar.gz` archive
  (plus `.sha256`) for every target, built in the same job via
  `-Dwasm-host=true`. The optional standalone Wasm compute-unit host is now a
  downloadable artifact, not a build-from-source-only binary.
- Added a Homebrew tap publish job (`brew install jamiesun/tap/scoot` and
  `brew install jamiesun/tap/scoot-wasm`). The `scoot-wasm` formula depends on
  `scoot`, so installing the host also installs the agent; the default
  `wasm_host` then resolves `scoot-wasm` from `PATH`. The job no-ops unless a
  `HOMEBREW_TAP_TOKEN` secret is set, mirroring the optional Docker Hub publish.

### Changed

- Release archives now ship a single `ReleaseSafe` flavor per target instead of
  both `ReleaseSafe` and `ReleaseSmall`. Users who need a smaller binary compile
  from source with `-Doptimize=ReleaseSmall`; the published release notes carry a
  permanent footer documenting this and the optional Wasm host.

### Removed

- Dropped the `-small` (`ReleaseSmall`) release artifacts and the installer's
  `SCOOT_INSTALL_FLAVOR` variable. `install.sh` now downloads the single
  published flavor.
- Narrowed the Wasm plugin sandbox to stdin/stdout/stderr/argv as a new hard
  rule: no filesystem, network, clock, or randomness authority (#164).

### Documentation

- Rewrote the README to be human-friendly and concept-first, and refreshed the
  infographic with an isometric hero image (#160, #165).
- Removed the redundant README language link and translated remaining Chinese
  comments and strings to English (#146, #153).

## [0.4.0] - 2026-06-26

### Added

- Embedded runs now emit session-correlated audit events and write per-session
  JSONL state, making API-driven runs replayable and easier to inspect (#140).
- Added read-only session and audit commands: `scoot sessions list`,
  `scoot session show <id>`, and `scoot audit show <session-id>` (#141).
- Added the foreground `scoot serve` stdio NDJSON protocol with `run`,
  `session.list`, `session.get`, and `audit.query` methods for local app-server
  integrations (#142).

### Changed

- Hardened the serve and daemon lifecycle: stdio `run` uses request-scoped
  result allocation and default retry semantics, and `daemon stop` only signals
  a process when the pid matches the recorded running daemon state (#143).

## [0.3.0] - 2026-06-23

### Added

- Docker releases now publish multi-platform Linux images for `linux/amd64`,
  `linux/arm64`, and `linux/arm/v7` to GHCR, with optional Docker Hub publishing
  when Docker Hub credentials are configured. The default image uses a minimal
  BusyBox/musl runtime and matching Alpine runtime tags use an `-alpine` suffix.
- `scoot setup` interactive command generates a config directory in a few
  prompts (config dir with overwrite confirmation, backend `base_url`/`model`,
  token source via env/0600 file/command, `max_turns`, policy), creates the
  runtime tree, and writes `config.toml` without ever inlining the token —
  the fast path for provisioning multiple isolated instances on one host.
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
- Client-side MCP support through a guarded `mcp_call` meta-action and
  `[[mcp.servers]]` config. The client now supports stdio, Streamable HTTP, and
  legacy SSE transports behind the same config and policy seam, including
  per-server header authentication via environment-backed values (#103).
- External context compressor plugins can now be selected with
  `agent.compactor = "plugin:<name>"` and configured under
  `[agent.compactor_plugin.<name>]`. Packages reuse the `wasm_tool` descriptor
  boundary with `kind = "compressor"` and run as bounded subprocesses with
  extractive/drop fallback (#98).

### Changed

- Scoot now speaks only the OpenAI Responses API (`/v1/responses`): leading
  system messages map to the top-level `instructions` field, the rest become the
  `input` array, and transport is stateless by default (full `input` resent each
  turn) so local context compaction stays in control. Requires a Responses-capable
  backend such as Ollama >= 0.13.3, vLLM, or OpenAI (#110).
- Guarded mode now confines file writes to the project root by default, wraps
  tool observations in an explicit untrusted-data boundary, and requires an
  opt-in for repository-carried `<cwd>/.agents/skills` (#113).
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
- Catastrophic shell-command detection now also catches whitespace-obfuscated
  fork-bomb patterns (#113).
- GitHub workflows now pin action references to commit SHAs and verify the
  downloaded Zig toolchain tarball checksum before extraction (#113).
- MCP stdio tests now use per-process temp directories, so the parallel
  `zig build test` artifacts no longer race on shared `/tmp` paths (#122).
- MCP SSE transport now enforces a single cumulative timeout across the entire
  session (connection setup, `receiveHead`, every POST, and every event read) so
  a server that accepts the connection but never sends headers, or that dribbles
  one event just before each per-event deadline, can no longer hang the agent
  indefinitely (#123).
- MCP remote header values sourced from environment variables (`value_env`) are
  now checked for CR/LF, closing a header-injection gap where the literal
  `value` and `prefix` were validated but the resolved env value was not (#124).
- MCP stdio transport now bounds the child-process stdin write with the
  configured timeout. Previously a server that never drained its stdin blocked
  the write forever once the OS pipe buffer filled with the model-controlled
  request, and the `defer child.kill` cleanup could never run (#125).
- `zig build test` now runs its three test artifacts sequentially instead of
  in parallel, so tests that share hardcoded `/tmp/scoot_*` paths across
  binaries no longer race (one binary's `deleteTree` removing a file another is
  mid-`exec` on); compilation still parallelizes (#127).

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

[Unreleased]: https://github.com/jamiesun/scoot/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/jamiesun/scoot/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/jamiesun/scoot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jamiesun/scoot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jamiesun/scoot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jamiesun/scoot/compare/v0.0.2...v0.1.0
