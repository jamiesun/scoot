//! Runtime configuration. By default, loads from ~/.scoot/config.json and falls
//! back to built-in defaults when absent. State stays strictly local, and secrets
//! are not inlined by default; see secret.zig.
const std = @import("std");
const Environ = std.process.Environ;
const paths = @import("paths.zig");
const secret = @import("secret.zig");
const schedule = @import("schedule.zig");
const policy = @import("policy.zig");
const tomlmod = @import("toml.zig");
const mcp_tool = @import("tools/mcp.zig");

pub const default_context_budget_bytes: usize = 80_000;

/// LLM backend configuration. Only OpenAI-compatible protocol is supported.
pub const Backend = struct {
    base_url: []const u8 = "http://127.0.0.1:11434/v1",
    model: []const u8 = "qwen2.5",
    /// Hard timeout for one backend Responses API call. 0 disables the deadline.
    timeout_ms: u64 = 120_000,
    /// Environment variable name used to read the token. Plaintext is not stored here.
    api_key_env: []const u8 = "OPENAI_API_KEY",
    /// Token file path; null uses ~/.scoot/token.
    api_key_file: ?[]const u8 = null,
    /// Credential command, such as `pass show openai`; null disables it.
    api_key_cmd: ?[]const u8 = null,
    /// Absolute custom CA bundle path (PEM); null means scan system roots.
    /// Trimmed or embedded Linux often lacks system certs, so firmware can ship
    /// a CA bundle and point here.
    ca_file: ?[]const u8 = null,
    /// Dynamic extra request-body fields passed through into the top-level
    /// model request JSON. This supports backend-specific or newly added fields
    /// without a Zig field for each one, such as Azure `service_tier`,
    /// reasoning-model `reasoning_effort`, or `top_p`. Only JSON objects are
    /// accepted; non-objects are ignored. Plaintext secrets are forbidden here.
    extra_body: ?std.json.Value = null,
    /// Whether to ask the backend to persist responses server-side via the
    /// Responses API `store` flag (issue #110). Off by default to keep model
    /// context local and auditable; transport stays stateless either way.
    store: bool = false,
};

/// Cognitive engine configuration.
pub const Agent = struct {
    max_turns: u32 = 32,
    /// Default cognitive mode: goal or plan.
    default_mode: []const u8 = "goal",
    /// Context compaction strategy: extractive by default, or old drop marker.
    compactor: []const u8 = "extractive",
    /// Context budget in bytes. When accumulated prompt history exceeds this,
    /// compactor first folds history, keeping system, original task, and recent
    /// turns (compressor.zig / issue #71) so run can continue. Only if the
    /// compacted history still exceeds budget does the next backend call
    /// fail-fast (issue #28). 0 explicitly disables the budget, leaving only
    /// max_turns. Bytes are a rough token-size proxy with conservative headroom.
    context_budget_bytes: usize = default_context_budget_bytes,
};

/// Tool sandbox configuration.
pub const Tools = struct {
    /// Tool-call hard timeout in milliseconds.
    timeout_ms: u64 = 30_000,
    /// Execution policy mode: guarded by default, readonly fail-closed allowlist,
    /// or unrestricted. See policy.zig. Unattended scenarios should use readonly.
    policy: []const u8 = "guarded",
    /// Default-on hardening, only active in guarded: confines
    /// file_write/file_edit to the project root and rejects absolute paths, `..`
    /// escapes, and shell expansion (issue #32). readonly already denies writes.
    confine_writes: bool = true,
    /// Default-on hardening, only active in guarded: rejects http_request to
    /// loopback, private, link-local, and cloud metadata addresses to narrow SSRF
    /// and exfiltration surface (issues #32 / #50). Legitimate agent HTTP rarely
    /// needs these addresses, so the friction is low. Set false explicitly for
    /// intended internal access. readonly already denies networking.
    block_internal_http: bool = true,
};

/// Skill mechanism configuration.
pub const Skills = struct {
    enabled: bool = true,
    /// Whether to load project-local skills from <cwd>/.agents/skills. Disabled
    /// by default because repository-carried skill instructions are untrusted.
    include_project_skills: bool = false,
    /// Whether to load cross-agent user skills from ~/.agents/skills. Disabled
    /// by default to avoid global skills polluting this agent.
    include_agents_skills: bool = false,
    /// Extra skill search paths; defaults already include ~/.scoot/skills.
    extra_paths: []const []const u8 = &.{},
};

pub const McpServer = mcp_tool.Server;

/// External MCP servers callable through the `mcp_call` meta-action. Servers
/// fail closed: a call is denied unless the server exists and `allowed_tools`
/// explicitly includes the requested tool.
pub const Mcp = struct {
    servers: []const McpServer = &.{},
};

/// Audit log configuration.
pub const Audit = struct {
    /// Log level: debug / info / warn / error.
    level: []const u8 = "info",
    /// Whether to write audit logs under ~/.scoot/logs.
    to_file: bool = true,
};

/// Config mirror for one scheduled job. The trigger is represented by three
/// mutually exclusive optional fields for JSON friendliness; exactly one must
/// be set.
pub const JobConfig = struct {
    id: []const u8,
    goal: []const u8 = "",
    /// Fixed interval in seconds.
    every_sec: ?u64 = null,
    /// Fixed Unix timestamp in seconds.
    at_unix: ?i64 = null,
    /// Cron expression.
    cron: ?[]const u8 = null,
    /// Execution policy: readonly by default for unattended safety, or
    /// unrestricted at user's risk with auditing. guarded is corrected to
    /// readonly at execution via schedule.Job.effectiveMode.
    mode: []const u8 = "readonly",

    /// Collapses mutually exclusive optional trigger fields into schedule.Trigger.
    /// Exactly one field must be set; otherwise returns null.
    pub fn trigger(jc: JobConfig) ?schedule.Trigger {
        var n: usize = 0;
        var t: schedule.Trigger = undefined;
        if (jc.every_sec) |s| {
            n += 1;
            t = .{ .every_sec = s };
        }
        if (jc.at_unix) |a| {
            n += 1;
            t = .{ .at_unix = a };
        }
        if (jc.cron) |c| {
            if (!schedule.cronValid(c)) return null;
            n += 1;
            t = .{ .cron = c };
        }
        return if (n == 1) t else null;
    }

    /// Converts to a schedulable schedule.Job. Invalid triggers return null so
    /// callers can skip and warn. mode parses through policy.Mode.fromString;
    /// unknown values fall back to guarded, then effectiveMode corrects to readonly.
    pub fn toJob(jc: JobConfig) ?schedule.Job {
        const trig = jc.trigger() orelse return null;
        return .{
            .id = jc.id,
            .trigger = trig,
            .goal = jc.goal,
            .mode = policy.Mode.fromString(jc.mode),
        };
    }
};

/// Scheduling configuration. Disabled by default; unattended autonomous runs
/// must be explicitly enabled.
pub const Schedule = struct {
    enabled: bool = false,
    /// Daemon loop polling interval in milliseconds.
    poll_ms: u64 = 1000,
    jobs: []const JobConfig = &.{},
};

/// Serializable mirror of config.json: persisted configuration sections only,
/// excluding runtime paths. Each section has defaults, so missing sections/fields
/// naturally merge back to defaults.
const FileConfig = struct {
    backend: Backend = .{},
    agent: Agent = .{},
    tools: Tools = .{},
    skills: Skills = .{},
    mcp: Mcp = .{},
    audit: Audit = .{},
    schedule: Schedule = .{},
};

/// Config file size cap: 1 MiB, far above typical config files.
const config_read_limit: std.Io.Limit = .limited(1 << 20);

/// Config load diagnostics: report parse locations and silently dropped misspelled
/// keys to upper layers such as CLI for actionable warnings (issues #45, #46).
/// On failure, this is populated before returning the error.
pub const LoadReport = struct {
    /// TOML parse failure position, filled only for TOML InvalidToml paths.
    toml_diag: ?tomlmod.Diagnostic = null,
    /// Unknown config keys as dotted paths, collected because ignore_unknown_fields
    /// silently drops them and falls back to defaults.
    unknown_keys: []const []const u8 = &.{},
    /// Keys that Scoot used to recognize but has removed, as dotted paths. Surfaced
    /// separately from misspellings so upgrade warnings can be clear (issue #110).
    deprecated_keys: []const []const u8 = &.{},
    /// SCOOT_* env overrides ignored due to invalid types, with variable and reason.
    env_warnings: []const []const u8 = &.{},
};

/// Collects keys in the parsed config tree not recognized by FileConfig, as
/// dotted paths. Misspelled keys such as `[tools] polcy` are silently dropped by
/// std.json ignore_unknown_fields and fall back to defaults; for security keys
/// such as policy or api_key_env this can quietly become less safe, so warn.
fn collectUnknownKeys(arena: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (value == .object) try checkObjectKeys(FileConfig, arena, value.object, "", &list);
    return list.items;
}

/// Config keys removed by Scoot, kept here so an upgrade surfaces a clear
/// "removed" warning instead of a misleading "check spelling" one (issue #110).
const removed_keys = [_][]const u8{ "backend.api", "backend.prompt_cache" };

fn isRemovedKey(k: []const u8) bool {
    for (removed_keys) |r| if (std.mem.eql(u8, k, r)) return true;
    return false;
}

/// Splits collected unknown keys into genuinely unknown (likely misspellings) and
/// deprecated/removed keys, recording each into the report.
fn classifyUnknownKeys(arena: std.mem.Allocator, all: []const []const u8, r: *LoadReport) std.mem.Allocator.Error!void {
    var unknown: std.ArrayList([]const u8) = .empty;
    var deprecated: std.ArrayList([]const u8) = .empty;
    for (all) |k| {
        if (isRemovedKey(k)) try deprecated.append(arena, k) else try unknown.append(arena, k);
    }
    r.unknown_keys = unknown.items;
    r.deprecated_keys = deprecated.items;
}

fn checkObjectKeys(
    comptime T: type,
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    prefix: []const u8,
    list: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const fields = @typeInfo(T).@"struct".fields;
    var it = obj.iterator();
    keyloop: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        inline for (fields) |f| {
            if (std.mem.eql(u8, f.name, key)) {
                try checkFieldKeys(f.type, arena, entry.value_ptr.*, try joinKey(arena, prefix, key), list);
                continue :keyloop;
            }
        }
        try list.append(arena, try joinKey(arena, prefix, key));
    }
}

fn checkFieldKeys(
    comptime FT: type,
    arena: std.mem.Allocator,
    value: std.json.Value,
    path: []const u8,
    list: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const T = switch (@typeInfo(FT)) {
        .optional => |o| o.child,
        else => FT,
    };
    if (T == std.json.Value) return; // Free-form field, e.g. extra_body.
    switch (@typeInfo(T)) {
        .@"struct" => if (value == .object) try checkObjectKeys(T, arena, value.object, path, list),
        .pointer => |ptr| {
            const child_is_struct = switch (@typeInfo(ptr.child)) {
                .@"struct" => true,
                else => false,
            };
            if (ptr.size == .slice and child_is_struct and value == .array) {
                for (value.array.items) |item| try checkFieldKeys(ptr.child, arena, item, path, list);
            }
        },
        else => {},
    }
}

fn joinKey(arena: std.mem.Allocator, prefix: []const u8, key: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return arena.dupe(u8, key);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, key });
}

/// Reads an env var; empty string is treated as unset to avoid empty overrides.
fn envVal(env: *const Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// Loose bool parser: true/false case-insensitively, or 1/0.
fn parseEnvBool(s: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

fn warnEnv(
    warnings: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
    name: []const u8,
    reason: []const u8,
) std.mem.Allocator.Error!void {
    try warnings.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ name, reason }));
}

fn overrideEnvBool(
    env: *const Environ.Map,
    name: []const u8,
    out: *bool,
    warnings: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const v = envVal(env, name) orelse return;
    if (parseEnvBool(v)) |b| out.* = b else try warnEnv(warnings, arena, name, "must be true/false (or 1/0); ignored");
}

fn overrideEnvInt(
    comptime T: type,
    env: *const Environ.Map,
    name: []const u8,
    out: *T,
    warnings: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const v = envVal(env, name) orelse return;
    out.* = std.fmt.parseInt(T, v, 10) catch {
        try warnEnv(warnings, arena, name, "must be a non-negative integer; ignored");
        return;
    };
}

fn oneOf(s: []const u8, allowed: []const []const u8) bool {
    for (allowed) |item| {
        if (std.mem.eql(u8, s, item)) return true;
    }
    return false;
}

fn overrideEnvEnumString(
    env: *const Environ.Map,
    name: []const u8,
    out: *[]const u8,
    allowed: []const []const u8,
    warnings: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const v = envVal(env, name) orelse return;
    if (oneOf(v, allowed)) {
        out.* = try arena.dupe(u8, v);
        return;
    }
    try warnEnv(warnings, arena, name, "is not a supported value; ignored");
}

/// Parses config.json text into FileConfig. Blank content falls back to defaults;
/// unknown fields are ignored for forward compatibility; malformed JSON returns
/// error.InvalidConfig. Strings and arrays are allocated in arena.
fn parseFileConfig(arena: std.mem.Allocator, bytes: []const u8, report: ?*LoadReport) !FileConfig {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return .{};
    const fc = std.json.parseFromSliceLeaky(FileConfig, arena, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    // Diagnostics only: parse again as Value to collect unknown keys best-effort.
    if (report) |r| {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{})) |value| {
            try classifyUnknownKeys(arena, try collectUnknownKeys(arena, value), r);
        } else |_| {}
    }
    return fc;
}

/// Parses config.toml text into FileConfig. The local TOML subset parser first
/// produces a std.json.Value tree, then std.json.parseFromValueLeaky reuses the
/// same type mapping, defaults, section merge behavior, and extra_body passthrough
/// as JSON. Blank content falls back to defaults; malformed TOML or type mismatch
/// returns error.InvalidConfig so bad config is visible.
fn parseTomlConfig(arena: std.mem.Allocator, bytes: []const u8, report: ?*LoadReport) !FileConfig {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return .{};
    var diag: tomlmod.Diagnostic = undefined;
    const value = tomlmod.parseDiag(arena, bytes, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidToml => {
            if (report) |r| r.toml_diag = diag; // Report failing line/column.
            return error.InvalidConfig;
        },
    };
    if (report) |r| try classifyUnknownKeys(arena, try collectUnknownKeys(arena, value), r); // Report misspelled/removed keys.
    return std.json.parseFromValueLeaky(FileConfig, arena, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
}

pub const Config = struct {
    backend: Backend = .{},
    agent: Agent = .{},
    tools: Tools = .{},
    skills: Skills = .{},
    mcp: Mcp = .{},
    audit: Audit = .{},
    schedule: Schedule = .{},
    /// Resolved runtime directories.
    dirs: paths.Paths,
    /// Actual loaded config path, with config.toml preferred over config.json.
    /// If both are missing, this is the recommended config.toml path for display.
    active_config_file: []const u8 = "",

    /// Loads config from ~/.scoot/: config.toml first, then config.json, then
    /// defaults. `io` reads files and `env` resolves runtime directories.
    /// Missing files silently fall back; malformed present files return
    /// error.InvalidConfig so bad config is visible.
    pub fn load(arena: std.mem.Allocator, io: std.Io, env: *const Environ.Map) !Config {
        const dirs = try paths.Paths.resolve(arena, env);
        return loadFromDirs(arena, io, dirs, null);
    }

    /// Loads config after runtime directories are resolved, letting CLI report
    /// path/config errors separately. Priority: config.toml for readability, then
    /// config.json for compatibility. Non-null `report` receives parse diagnostics
    /// and unknown keys for warnings (issues #45, #46).
    pub fn loadFromDirs(arena: std.mem.Allocator, io: std.Io, dirs: paths.Paths, report: ?*LoadReport) !Config {
        const cwd = std.Io.Dir.cwd();
        // 1. Prefer TOML.
        if (cwd.readFileAlloc(io, dirs.config_toml_file, arena, config_read_limit)) |bytes| {
            const fc = try parseTomlConfig(arena, bytes, report);
            return fromFile(fc, dirs, dirs.config_toml_file);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        // 2. Fall back to JSON.
        if (cwd.readFileAlloc(io, dirs.config_file, arena, config_read_limit)) |bytes| {
            const fc = try parseFileConfig(arena, bytes, report);
            return fromFile(fc, dirs, dirs.config_file);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        // 3. Both missing: defaults; active path points to recommended TOML.
        return .{ .dirs = dirs, .active_config_file = dirs.config_toml_file };
    }

    /// Loads from an explicit config file while using the given runtime
    /// directories for token/skills/logs/state. `.toml` uses TOML; others use JSON.
    pub fn loadFromFile(arena: std.mem.Allocator, io: std.Io, dirs: paths.Paths, file: []const u8, report: ?*LoadReport) !Config {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, arena, config_read_limit);
        const fc = if (std.mem.endsWith(u8, file, ".toml"))
            try parseTomlConfig(arena, bytes, report)
        else
            try parseFileConfig(arena, bytes, report);
        return fromFile(fc, dirs, file);
    }

    fn fromFile(fc: FileConfig, dirs: paths.Paths, active: []const u8) Config {
        return .{
            .backend = fc.backend,
            .agent = fc.agent,
            .tools = fc.tools,
            .skills = fc.skills,
            .mcp = fc.mcp,
            .audit = fc.audit,
            .schedule = fc.schedule,
            .dirs = dirs,
            .active_config_file = active,
        };
    }

    /// Applies SCOOT_* env overrides on top of loaded config. Priority:
    /// SCOOT_* env > config file > built-in defaults. This supports zero-config
    /// CI/GitHub Actions runs by passing backend URL, model, policy, etc. via env
    /// with `SCOOT_HOME=$(mktemp -d)`. Secrets are still read only through the env
    /// variable named by backend.api_key_env, default OPENAI_API_KEY; plaintext
    /// secrets are never read here. Invalid typed values are ignored and recorded
    /// in `report.env_warnings` so upper layers can warn on stderr.
    pub fn applyEnvOverrides(
        self: *Config,
        arena: std.mem.Allocator,
        env: *const Environ.Map,
        report: ?*LoadReport,
    ) std.mem.Allocator.Error!void {
        var warnings: std.ArrayList([]const u8) = .empty;

        // Backend, excluding plaintext secrets.
        if (envVal(env, "SCOOT_BACKEND_BASE_URL")) |v| self.backend.base_url = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_MODEL")) |v| self.backend.model = try arena.dupe(u8, v);
        try overrideEnvInt(u64, env, "SCOOT_BACKEND_TIMEOUT_MS", &self.backend.timeout_ms, &warnings, arena);
        if (envVal(env, "SCOOT_BACKEND_API_KEY_ENV")) |v| self.backend.api_key_env = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_API_KEY_FILE")) |v| self.backend.api_key_file = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_API_KEY_CMD")) |v| self.backend.api_key_cmd = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_CA_FILE")) |v| self.backend.ca_file = try arena.dupe(u8, v);
        try overrideEnvBool(env, "SCOOT_BACKEND_STORE", &self.backend.store, &warnings, arena);
        if (envVal(env, "SCOOT_BACKEND_EXTRA_BODY")) |v| {
            if (std.json.parseFromSliceLeaky(std.json.Value, arena, v, .{})) |parsed| {
                if (parsed == .object)
                    self.backend.extra_body = parsed
                else
                    try warnEnv(&warnings, arena, "SCOOT_BACKEND_EXTRA_BODY", "must be a JSON object; ignored");
            } else |_| {
                try warnEnv(&warnings, arena, "SCOOT_BACKEND_EXTRA_BODY", "JSON parse failed; ignoring value");
            }
        }

        // Agent.
        try overrideEnvEnumString(env, "SCOOT_AGENT_DEFAULT_MODE", &self.agent.default_mode, &.{ "goal", "plan" }, &warnings, arena);
        try overrideEnvEnumString(env, "SCOOT_AGENT_COMPACTOR", &self.agent.compactor, &.{ "drop", "extractive" }, &warnings, arena);
        try overrideEnvInt(u32, env, "SCOOT_AGENT_MAX_TURNS", &self.agent.max_turns, &warnings, arena);
        try overrideEnvInt(usize, env, "SCOOT_AGENT_CONTEXT_BUDGET_BYTES", &self.agent.context_budget_bytes, &warnings, arena);

        // Tools.
        try overrideEnvEnumString(env, "SCOOT_TOOLS_POLICY", &self.tools.policy, &.{ "guarded", "readonly", "unrestricted", "yolo" }, &warnings, arena);
        try overrideEnvInt(u64, env, "SCOOT_TOOLS_TIMEOUT_MS", &self.tools.timeout_ms, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_TOOLS_CONFINE_WRITES", &self.tools.confine_writes, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_TOOLS_BLOCK_INTERNAL_HTTP", &self.tools.block_internal_http, &warnings, arena);

        // Skills.
        try overrideEnvBool(env, "SCOOT_SKILLS_ENABLED", &self.skills.enabled, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_SKILLS_INCLUDE_PROJECT_SKILLS", &self.skills.include_project_skills, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_SKILLS_INCLUDE_AGENTS_SKILLS", &self.skills.include_agents_skills, &warnings, arena);

        // Audit.
        try overrideEnvEnumString(env, "SCOOT_AUDIT_LEVEL", &self.audit.level, &.{ "debug", "info", "warn", "error" }, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_AUDIT_TO_FILE", &self.audit.to_file, &warnings, arena);

        if (report) |r| r.env_warnings = warnings.items;
    }

    /// Resolves API token from configured sources: env > file > cmd. Plaintext is
    /// never stored in config.
    pub fn resolveToken(
        self: Config,
        arena: std.mem.Allocator,
        io: std.Io,
        env: *const Environ.Map,
    ) !secret.Secret {
        var srcs: std.ArrayList(secret.Source) = .empty;
        try srcs.append(arena, .{ .env = self.backend.api_key_env });
        try srcs.append(arena, .{ .file = self.backend.api_key_file orelse self.dirs.token_file });
        if (self.backend.api_key_cmd) |cmd| try srcs.append(arena, .{ .command = cmd });
        return secret.resolve(arena, io, env, srcs.items);
    }

    /// All skill search paths in priority order. First wins because
    /// `Registry.discover` deduplicates by name. This matches other agent tools:
    ///   1. `<cwd>/.agents/skills`: optional project-local directory when
    ///      include_project_skills=true, resolved relative to process cwd.
    ///   2. `~/.agents/skills`: optional cross-agent user directory when
    ///      include_agents_skills=true.
    ///   3. `~/.scoot/skills`: Scoot's own user-level directory.
    ///   4. Explicit `extra_paths` from config.
    pub fn skillPaths(self: Config, arena: std.mem.Allocator) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        if (self.skills.include_project_skills) try list.append(arena, ".agents/skills");
        if (self.skills.include_agents_skills) {
            if (self.dirs.agents_skills_dir) |d| try list.append(arena, d);
        }
        try list.append(arena, self.dirs.skills_dir);
        for (self.skills.extra_paths) |p| try list.append(arena, p);
        return list.items;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "skillPaths: project and ~/.agents skills are opt-in" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dirs = try paths.Paths.fromHome(arena, "/home/u/.scoot");
    dirs.agents_skills_dir = "/home/u/.agents/skills";
    const cfg_default: Config = .{ .dirs = dirs, .skills = .{ .enabled = true, .extra_paths = &.{"/opt/extra/skills"} } };
    const got_default = try cfg_default.skillPaths(arena);
    try std.testing.expectEqual(@as(usize, 2), got_default.len);
    try std.testing.expectEqualStrings("/home/u/.scoot/skills", got_default[0]);
    try std.testing.expectEqualStrings("/opt/extra/skills", got_default[1]);

    const cfg: Config = .{ .dirs = dirs, .skills = .{ .enabled = true, .include_project_skills = true, .include_agents_skills = true, .extra_paths = &.{"/opt/extra/skills"} } };
    const got = try cfg.skillPaths(arena);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings(".agents/skills", got[0]);
    try std.testing.expectEqualStrings("/home/u/.agents/skills", got[1]);
    try std.testing.expectEqualStrings("/home/u/.scoot/skills", got[2]);
    try std.testing.expectEqualStrings("/opt/extra/skills", got[3]);

    // Unknown $HOME: skip the ~/.agents layer even when enabled; cwd stays first.
    var cfg2: Config = .{
        .dirs = try paths.Paths.fromHome(arena, "/home/u/.scoot"),
        .skills = .{ .include_project_skills = true, .include_agents_skills = true },
    };
    cfg2.dirs.agents_skills_dir = null;
    const got2 = try cfg2.skillPaths(arena);
    try std.testing.expectEqual(@as(usize, 2), got2.len);
    try std.testing.expectEqualStrings(".agents/skills", got2[0]);
    try std.testing.expectEqualStrings("/home/u/.scoot/skills", got2[1]);
}

test "parseTomlConfig: TOML to FileConfig with extra_body passthrough and per-section merge" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# Scoot config (TOML, more readable)
        \\[backend]
        \\base_url = "https://x.azure.com/openai/v1"
        \\model = "gpt-5.5"
        \\timeout_ms = 90000
        \\store = true
        \\api_key_env = "WJT_AZURE_OPENAI_API_KEY"
        \\
        \\[backend.extra_body]
        \\service_tier = "priority"
        \\reasoning_effort = "high"
        \\
        \\[tools]
        \\policy = "guarded"
        \\
        \\[skills]
        \\include_project_skills = true
        \\include_agents_skills = true
    ;
    const fc = try parseTomlConfig(arena.allocator(), src, null);
    try std.testing.expectEqualStrings("https://x.azure.com/openai/v1", fc.backend.base_url);
    try std.testing.expectEqualStrings("gpt-5.5", fc.backend.model);
    try std.testing.expectEqual(@as(u64, 90_000), fc.backend.timeout_ms);
    try std.testing.expectEqual(true, fc.backend.store);
    try std.testing.expectEqualStrings("WJT_AZURE_OPENAI_API_KEY", fc.backend.api_key_env);
    try std.testing.expectEqualStrings("guarded", fc.tools.policy);
    try std.testing.expectEqual(true, fc.skills.include_project_skills);
    try std.testing.expectEqual(true, fc.skills.include_agents_skills);
    // Unspecified sections fall back to defaults.
    try std.testing.expectEqual(@as(u32, 32), fc.agent.max_turns);
    try std.testing.expectEqualStrings("extractive", fc.agent.compactor);
    try std.testing.expectEqual(@as(usize, default_context_budget_bytes), fc.agent.context_budget_bytes);
    // extra_body passes through as a std.json.Value object.
    try std.testing.expect(fc.backend.extra_body != null);
    const eb = fc.backend.extra_body.?.object;
    try std.testing.expectEqualStrings("priority", eb.get("service_tier").?.string);
    try std.testing.expectEqualStrings("high", eb.get("reasoning_effort").?.string);
}

test "parseTomlConfig: array of tables schedule.jobs maps correctly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[schedule]
        \\enabled = true
        \\
        \\[[schedule.jobs]]
        \\id = "disk"
        \\goal = "check disk"
        \\every_sec = 300
    ;
    const fc = try parseTomlConfig(arena.allocator(), src, null);
    try std.testing.expectEqual(true, fc.schedule.enabled);
    try std.testing.expectEqual(@as(usize, 1), fc.schedule.jobs.len);
    try std.testing.expectEqualStrings("disk", fc.schedule.jobs[0].id);
    try std.testing.expectEqual(@as(?u64, 300), fc.schedule.jobs[0].every_sec);
}

test "parseTomlConfig: array of tables mcp.servers maps transport seam" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[[mcp.servers]]
        \\name = "fake"
        \\transport = "stdio"
        \\command = "/bin/sh"
        \\args = ["server.sh"]
        \\allowed_tools = ["echo"]
        \\env = [{ name = "FAKE_MODE", value = "test" }]
        \\policy = "readonly"
        \\
        \\[[mcp.servers]]
        \\name = "remote"
        \\transport = "http"
        \\url = "https://mcp.example.test/mcp"
        \\allowed_tools = ["lookup"]
    ;
    const fc = try parseTomlConfig(arena.allocator(), src, null);
    try std.testing.expectEqual(@as(usize, 2), fc.mcp.servers.len);
    try std.testing.expectEqualStrings("fake", fc.mcp.servers[0].name);
    try std.testing.expectEqualStrings("stdio", fc.mcp.servers[0].transport);
    try std.testing.expectEqualStrings("/bin/sh", fc.mcp.servers[0].command);
    try std.testing.expectEqualStrings("server.sh", fc.mcp.servers[0].args[0]);
    try std.testing.expectEqualStrings("echo", fc.mcp.servers[0].allowed_tools[0]);
    try std.testing.expectEqualStrings("FAKE_MODE", fc.mcp.servers[0].env[0].name);
    try std.testing.expectEqualStrings("http", fc.mcp.servers[1].transport);
    try std.testing.expectEqualStrings("https://mcp.example.test/mcp", fc.mcp.servers[1].url.?);
}

test "parseTomlConfig: blank falls back to defaults; malformed returns InvalidConfig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseTomlConfig(arena.allocator(), "\n# comments only\n", null);
    try std.testing.expectEqualStrings("qwen2.5", fc.backend.model);
    try std.testing.expectError(error.InvalidConfig, parseTomlConfig(arena.allocator(), "a = 2020-01-01", null));
}

test "parseTomlConfig: misspelled keys are collected for warnings and defaulted(issue #45)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[tools]
        \\polcy = "readonly"
        \\
        \\[backend]
        \\modle = "x"
        \\base_url = "https://h/v1"
    ;
    var report: LoadReport = .{};
    const fc = try parseTomlConfig(arena.allocator(), src, &report);
    // Misspelled keys are ignored: policy quietly falls back to guarded.
    try std.testing.expectEqualStrings("guarded", fc.tools.policy);
    try std.testing.expectEqualStrings("https://h/v1", fc.backend.base_url);
    try std.testing.expectEqual(@as(usize, 2), report.unknown_keys.len);
    var saw_polcy = false;
    var saw_modle = false;
    for (report.unknown_keys) |k| {
        if (std.mem.eql(u8, k, "tools.polcy")) saw_polcy = true;
        if (std.mem.eql(u8, k, "backend.modle")) saw_modle = true;
    }
    try std.testing.expect(saw_polcy and saw_modle);
}

test "parseConfig: removed keys api/prompt_cache report as deprecated, not unknown(issue #110)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[backend]
        \\base_url = "https://h/v1"
        \\api = "responses"
        \\prompt_cache = "anthropic"
        \\modle = "x"
    ;
    var report: LoadReport = .{};
    const fc = try parseTomlConfig(arena.allocator(), src, &report);
    // Removed keys are ignored without changing behavior.
    try std.testing.expectEqualStrings("https://h/v1", fc.backend.base_url);
    // api/prompt_cache are surfaced as deprecated; the misspelling stays unknown.
    try std.testing.expectEqual(@as(usize, 2), report.deprecated_keys.len);
    try std.testing.expectEqual(@as(usize, 1), report.unknown_keys.len);
    try std.testing.expectEqualStrings("backend.modle", report.unknown_keys[0]);
    var saw_api = false;
    var saw_cache = false;
    for (report.deprecated_keys) |k| {
        if (std.mem.eql(u8, k, "backend.api")) saw_api = true;
        if (std.mem.eql(u8, k, "backend.prompt_cache")) saw_cache = true;
    }
    try std.testing.expect(saw_api and saw_cache);
}

test "parseTomlConfig: valid keys and free-form extra_body/array-of-tables content do not warn(issue #45)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[backend]
        \\model = "m"
        \\
        \\[backend.extra_body]
        \\service_tier = "priority"
        \\anything_here = 1
        \\
        \\[[schedule.jobs]]
        \\id = "j1"
        \\every_sec = 60
    ;
    var report: LoadReport = .{};
    _ = try parseTomlConfig(arena.allocator(), src, &report);
    try std.testing.expectEqual(@as(usize, 0), report.unknown_keys.len);
}

test "parseFileConfig: blank content falls back to defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "  \n\t ", null);
    try std.testing.expectEqualStrings("qwen2.5", fc.backend.model);
    try std.testing.expectEqual(@as(u32, 32), fc.agent.max_turns);
    try std.testing.expectEqualStrings("extractive", fc.agent.compactor);
    try std.testing.expectEqual(@as(usize, default_context_budget_bytes), fc.agent.context_budget_bytes);
    try std.testing.expectEqual(@as(u64, 30_000), fc.tools.timeout_ms);
}

test "parseFileConfig: empty object falls back to defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "{}", null);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1", fc.backend.base_url);
    try std.testing.expectEqual(false, fc.backend.store);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", fc.backend.api_key_env);
}

test "parseFileConfig: backend.extra_body passes through arbitrary JSON object" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{ "backend": { "extra_body": { "service_tier": "priority", "reasoning_effort": "high" } } }
    ;
    const fc = try parseFileConfig(arena.allocator(), json, null);
    try std.testing.expect(fc.backend.extra_body != null);
    try std.testing.expect(fc.backend.extra_body.? == .object);
    const tier = fc.backend.extra_body.?.object.get("service_tier").?;
    try std.testing.expectEqualStrings("priority", tier.string);
    const effort = fc.backend.extra_body.?.object.get("reasoning_effort").?;
    try std.testing.expectEqualStrings("high", effort.string);
}

test "parseFileConfig: unspecified extra_body -> null with no default extra fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "{\"backend\":{\"model\":\"m\"}}", null);
    try std.testing.expect(fc.backend.extra_body == null);
}

test "parseFileConfig: merges by section and field, preserving unspecified defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{
        \\  "backend": { "model": "llama3.1", "base_url": "http://10.0.0.2:1234/v1" },
        \\  "agent": { "max_turns": 8 },
        \\  "tools": { "timeout_ms": 5000 }
        \\}
    ;
    const fc = try parseFileConfig(arena.allocator(), json, null);
    try std.testing.expectEqualStrings("llama3.1", fc.backend.model);
    try std.testing.expectEqualStrings("http://10.0.0.2:1234/v1", fc.backend.base_url);
    // Unspecified -> default.
    try std.testing.expectEqualStrings("OPENAI_API_KEY", fc.backend.api_key_env);
    try std.testing.expectEqual(@as(u32, 8), fc.agent.max_turns);
    try std.testing.expectEqualStrings("goal", fc.agent.default_mode);
    try std.testing.expectEqualStrings("extractive", fc.agent.compactor);
    try std.testing.expectEqual(@as(usize, default_context_budget_bytes), fc.agent.context_budget_bytes);
    try std.testing.expectEqual(@as(u64, 5000), fc.tools.timeout_ms);
}

test "parseFileConfig: agent compactor is configurable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(),
        \\{ "agent": { "compactor": "extractive", "context_budget_bytes": 120000 } }
    , null);
    try std.testing.expectEqualStrings("extractive", fc.agent.compactor);
    try std.testing.expectEqual(@as(usize, 120000), fc.agent.context_budget_bytes);
}

test "parseFileConfig: context_budget_bytes can be set to 0 to disable budget" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(),
        \\{ "agent": { "context_budget_bytes": 0 } }
    , null);
    try std.testing.expectEqual(@as(usize, 0), fc.agent.context_budget_bytes);
    try std.testing.expectEqualStrings("extractive", fc.agent.compactor);
}

test "parseFileConfig: optional token source and extra skill paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{
        \\  "backend": { "api_key_cmd": "pass show openai" },
        \\  "skills": { "extra_paths": ["/opt/scoot/skills", "./skills"] }
        \\}
    ;
    const fc = try parseFileConfig(arena.allocator(), json, null);
    try std.testing.expect(fc.backend.api_key_cmd != null);
    try std.testing.expectEqualStrings("pass show openai", fc.backend.api_key_cmd.?);
    try std.testing.expect(fc.backend.api_key_file == null);
    try std.testing.expectEqual(@as(usize, 2), fc.skills.extra_paths.len);
    try std.testing.expectEqualStrings("/opt/scoot/skills", fc.skills.extra_paths[0]);
}

test "parseFileConfig: unknown fields are ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(),
        \\{ "backend": { "model": "m" }, "future_key": 123, "nested": { "x": true } }
    , null);
    try std.testing.expectEqualStrings("m", fc.backend.model);
}

test "parseFileConfig: malformed JSON returns InvalidConfig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidConfig, parseFileConfig(arena.allocator(), "{ not json", null));
    try std.testing.expectError(error.InvalidConfig, parseFileConfig(arena.allocator(),
        \\{ "agent": { "max_turns": "not-a-number" } }
    , null));
}

test "parseFileConfig: schedule section defaults to disabled" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "{}", null);
    try std.testing.expect(!fc.schedule.enabled);
    try std.testing.expectEqual(@as(u64, 1000), fc.schedule.poll_ms);
    try std.testing.expectEqual(@as(usize, 0), fc.schedule.jobs.len);
}

test "parseFileConfig: schedule jobs parse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{
        \\  "schedule": {
        \\    "enabled": true,
        \\    "poll_ms": 500,
        \\    "jobs": [
        \\      { "id": "heartbeat", "goal": "check disk", "every_sec": 60 },
        \\      { "id": "once", "goal": "one-shot", "at_unix": 99999, "mode": "unrestricted" }
        \\    ]
        \\  }
        \\}
    ;
    const fc = try parseFileConfig(arena.allocator(), json, null);
    try std.testing.expect(fc.schedule.enabled);
    try std.testing.expectEqual(@as(u64, 500), fc.schedule.poll_ms);
    try std.testing.expectEqual(@as(usize, 2), fc.schedule.jobs.len);
    try std.testing.expectEqualStrings("heartbeat", fc.schedule.jobs[0].id);
    try std.testing.expectEqualStrings("readonly", fc.schedule.jobs[0].mode); // Default.
    try std.testing.expectEqualStrings("unrestricted", fc.schedule.jobs[1].mode);
}

test "JobConfig.toJob: trigger validation and policy correction" {
    // Exactly one trigger -> valid.
    const ok = JobConfig{ .id = "a", .every_sec = 30 };
    const job = ok.toJob().?;
    try std.testing.expectEqual(policy.Mode.readonly, job.mode); // Default readonly.

    // guarded config is corrected to readonly by effectiveMode.
    const guarded = JobConfig{ .id = "g", .every_sec = 30, .mode = "guarded" };
    try std.testing.expectEqual(policy.Mode.guarded, guarded.toJob().?.mode); // Original preserved.
    try std.testing.expectEqual(policy.Mode.readonly, guarded.toJob().?.effectiveMode()); // Execution correction.

    // Zero triggers -> invalid.
    const none = JobConfig{ .id = "n" };
    try std.testing.expect(none.toJob() == null);

    // Multiple triggers -> invalid.
    const multi = JobConfig{ .id = "m", .every_sec = 30, .at_unix = 100 };
    try std.testing.expect(multi.toJob() == null);

    // Invalid cron syntax -> invalid job, avoiding silent never-fire loading.
    const bad_cron = JobConfig{ .id = "c", .cron = "60 * * * *" };
    try std.testing.expect(bad_cron.toJob() == null);
}

test "applyEnvOverrides: string fields override backend and tools" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_BACKEND_BASE_URL", "https://example.test/v1");
    try map.put("SCOOT_BACKEND_MODEL", "gpt-override");
    try map.put("SCOOT_BACKEND_TIMEOUT_MS", "4321");
    try map.put("SCOOT_BACKEND_STORE", "true");
    try map.put("SCOOT_TOOLS_POLICY", "readonly");

    var cfg: Config = .{ .dirs = undefined };
    var report: LoadReport = .{};
    try cfg.applyEnvOverrides(arena.allocator(), &map, &report);

    try std.testing.expectEqualStrings("https://example.test/v1", cfg.backend.base_url);
    try std.testing.expectEqualStrings("gpt-override", cfg.backend.model);
    try std.testing.expectEqual(@as(u64, 4321), cfg.backend.timeout_ms);
    try std.testing.expectEqual(true, cfg.backend.store);
    try std.testing.expectEqualStrings("readonly", cfg.tools.policy);
    try std.testing.expectEqual(@as(usize, 0), report.env_warnings.len);
}

test "applyEnvOverrides: invalid enum string warns and keeps original value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_AGENT_DEFAULT_MODE", "pla");
    try map.put("SCOOT_AGENT_COMPACTOR", "semantic");
    try map.put("SCOOT_TOOLS_POLICY", "readonyl");
    try map.put("SCOOT_AUDIT_LEVEL", "verbose");

    var cfg: Config = .{ .dirs = undefined };
    var report: LoadReport = .{};
    try cfg.applyEnvOverrides(arena.allocator(), &map, &report);

    try std.testing.expectEqualStrings("goal", cfg.agent.default_mode);
    try std.testing.expectEqualStrings("extractive", cfg.agent.compactor);
    try std.testing.expectEqualStrings("guarded", cfg.tools.policy);
    try std.testing.expectEqualStrings("info", cfg.audit.level);
    try std.testing.expectEqual(@as(usize, 4), report.env_warnings.len);
    var saw_compactor = false;
    var saw_audit = false;
    var saw_tools_policy = false;
    for (report.env_warnings) |w| {
        if (std.mem.indexOf(u8, w, "SCOOT_AGENT_COMPACTOR") != null) saw_compactor = true;
        if (std.mem.indexOf(u8, w, "SCOOT_AUDIT_LEVEL") != null) saw_audit = true;
        if (std.mem.indexOf(u8, w, "SCOOT_TOOLS_POLICY") != null) saw_tools_policy = true;
    }
    try std.testing.expect(saw_compactor and saw_audit and saw_tools_policy);
}

test "applyEnvOverrides: integer/bool fields parse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_AGENT_MAX_TURNS", "7");
    try map.put("SCOOT_AGENT_COMPACTOR", "extractive");
    try map.put("SCOOT_BACKEND_TIMEOUT_MS", "9876");
    try map.put("SCOOT_TOOLS_TIMEOUT_MS", "1234");
    try map.put("SCOOT_TOOLS_CONFINE_WRITES", "true");
    try map.put("SCOOT_TOOLS_BLOCK_INTERNAL_HTTP", "0");
    try map.put("SCOOT_SKILLS_ENABLED", "FALSE");
    try map.put("SCOOT_SKILLS_INCLUDE_PROJECT_SKILLS", "1");
    try map.put("SCOOT_SKILLS_INCLUDE_AGENTS_SKILLS", "1");

    var cfg: Config = .{ .dirs = undefined };
    try cfg.applyEnvOverrides(arena.allocator(), &map, null);

    try std.testing.expectEqual(@as(u32, 7), cfg.agent.max_turns);
    try std.testing.expectEqualStrings("extractive", cfg.agent.compactor);
    try std.testing.expectEqual(@as(u64, 9876), cfg.backend.timeout_ms);
    try std.testing.expectEqual(@as(u64, 1234), cfg.tools.timeout_ms);
    try std.testing.expectEqual(true, cfg.tools.confine_writes);
    try std.testing.expectEqual(false, cfg.tools.block_internal_http);
    try std.testing.expectEqual(false, cfg.skills.enabled);
    try std.testing.expectEqual(true, cfg.skills.include_project_skills);
    try std.testing.expectEqual(true, cfg.skills.include_agents_skills);
}

test "applyEnvOverrides: invalid integer/bool is ignored with warning and original value remains" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_AGENT_MAX_TURNS", "abc");
    try map.put("SCOOT_SKILLS_ENABLED", "maybe");

    var cfg: Config = .{ .dirs = undefined };
    var report: LoadReport = .{};
    try cfg.applyEnvOverrides(arena.allocator(), &map, &report);

    try std.testing.expectEqual(@as(u32, 32), cfg.agent.max_turns); // Default retained.
    try std.testing.expectEqual(@as(usize, default_context_budget_bytes), cfg.agent.context_budget_bytes);
    try std.testing.expectEqual(true, cfg.skills.enabled); // Default retained.
    try std.testing.expectEqual(@as(usize, 2), report.env_warnings.len);
}

test "applyEnvOverrides: empty string is treated as unset and does not override defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_BACKEND_MODEL", "");

    var cfg: Config = .{ .dirs = undefined };
    try cfg.applyEnvOverrides(arena.allocator(), &map, null);

    try std.testing.expectEqualStrings("qwen2.5", cfg.backend.model); // Default retained.
}

test "applyEnvOverrides: extra_body accepts JSON object and rejects non-object" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    {
        var map: std.process.Environ.Map = .init(std.testing.allocator);
        defer map.deinit();
        try map.put("SCOOT_BACKEND_EXTRA_BODY", "{\"temperature\":0.2}");
        var cfg: Config = .{ .dirs = undefined };
        var report: LoadReport = .{};
        try cfg.applyEnvOverrides(arena.allocator(), &map, &report);
        try std.testing.expect(cfg.backend.extra_body != null);
        try std.testing.expect(cfg.backend.extra_body.? == .object);
        try std.testing.expectEqual(@as(usize, 0), report.env_warnings.len);
    }
    {
        var map: std.process.Environ.Map = .init(std.testing.allocator);
        defer map.deinit();
        try map.put("SCOOT_BACKEND_EXTRA_BODY", "[1,2,3]");
        var cfg: Config = .{ .dirs = undefined };
        var report: LoadReport = .{};
        try cfg.applyEnvOverrides(arena.allocator(), &map, &report);
        try std.testing.expect(cfg.backend.extra_body == null); // Non-object rejected.
        try std.testing.expectEqual(@as(usize, 1), report.env_warnings.len);
    }
}

test "applyEnvOverrides: api_key_env override remains indirect and does not read plaintext secret" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_BACKEND_API_KEY_ENV", "LLM_KEY");

    var cfg: Config = .{ .dirs = undefined };
    try cfg.applyEnvOverrides(arena.allocator(), &map, null);

    try std.testing.expectEqualStrings("LLM_KEY", cfg.backend.api_key_env);
}
