//! Stable embedding API for the `scoot` package.
//!
//! The public surface is intentionally a narrow lifecycle facade:
//! `Runtime` + `start` / `run` / `stop` + `version`.

const std = @import("std");
const agent = @import("agent.zig");
const compressor = @import("compressor.zig");
const config = @import("config.zig");
const llm = @import("llm.zig");
const paths = @import("paths.zig");
const policy = @import("policy.zig");
const session = @import("session.zig");
const skill = @import("skill.zig");

/// Semantic version. The single source of truth is `build.zig.zon`; release
/// builds may override it with `-Dversion=<tag>`.
pub const version = @import("build_options").version;

/// Opaque runtime handle. Its internals are not part of the public API.
pub const Runtime = opaque {};

/// Opaque configuration sources for `start`.
///
/// `env` is required so Scoot can resolve `HOME`/`SCOOT_HOME`, `SCOOT_*`
/// overrides, and token environment variables. `scoot_home` overrides the
/// runtime directory in the same spirit as the CLI's `--scoot-home`.
/// `config_file`, when set, loads that file instead of `<home>/config.toml`.
pub const Options = struct {
    env: *const std.process.Environ.Map,
    scoot_home: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
};

const RuntimeState = struct {
    gpa: std.mem.Allocator,
    arena_state: std.heap.ArenaAllocator,
    io: std.Io,
    client: llm.Client,
    agent_template: agent.Agent,
    dirs: paths.Paths,
    skill_paths: []const []const u8,
    run_seq: usize = 0,
};

/// Start a Scoot runtime from opaque configuration sources.
pub fn start(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Runtime {
    const state = try gpa.create(RuntimeState);
    errdefer gpa.destroy(state);
    state.* = .{
        .gpa = gpa,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .io = io,
        .client = undefined,
        .agent_template = undefined,
        .dirs = undefined,
        .skill_paths = &.{},
    };
    errdefer state.arena_state.deinit();
    const arena = state.arena_state.allocator();

    const dirs = if (options.scoot_home) |home|
        try paths.Paths.fromHome(arena, home)
    else
        try paths.Paths.resolve(arena, options.env);

    var report: config.LoadReport = .{};
    var cfg = if (options.config_file) |file|
        try config.Config.loadFromFile(arena, io, dirs, file, &report)
    else
        try config.Config.loadFromDirs(arena, io, dirs, &report);
    try cfg.applyEnvOverrides(arena, options.env, &report);
    try cfg.dirs.ensure(io);

    const token_value = if (cfg.resolveToken(arena, io, options.env)) |secret|
        secret.value
    else |err| switch (err) {
        error.NoApiKey => "",
        else => return err,
    };
    const token = try arena.dupe(u8, token_value);

    state.client = llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
    state.client.ca_file = cfg.backend.ca_file;
    state.client.extra_body = cfg.backend.extra_body;
    state.client.model_ctx.store = cfg.backend.store;

    state.agent_template = agent.Agent.initClient(&state.client);
    state.agent_template.max_turns = cfg.agent.max_turns;
    state.agent_template.tool_timeout_ms = cfg.tools.timeout_ms;
    state.agent_template.policy_mode = policy.Mode.fromString(cfg.tools.policy);
    state.agent_template.ca_file = cfg.backend.ca_file;
    state.agent_template.context_budget_bytes = cfg.agent.context_budget_bytes;
    state.agent_template.compactor = compressor.fromString(cfg.agent.compactor);
    state.agent_template.confine_writes = cfg.tools.confine_writes;
    state.agent_template.block_internal_http = cfg.tools.block_internal_http;
    state.dirs = cfg.dirs;
    state.skill_paths = if (cfg.skills.enabled) try cfg.skillPaths(arena) else &.{};

    return @ptrCast(state);
}

/// Run one goal, equivalent in shape to CLI `-e`.
///
/// The returned slice is owned by the runtime and remains valid until `stop`.
pub fn run(rt: *Runtime, goal: []const u8) ![]const u8 {
    const state: *RuntimeState = @ptrCast(@alignCast(rt));
    const arena = state.arena_state.allocator();

    var sess = session.Session.init(try runtimeSessionId(arena, state.io, state.run_seq));
    state.run_seq += 1;
    defer sess.deinit(arena);
    try sess.append(arena, .system, agent.system_prompt);
    const refs = injectSkills(arena, state.io, state.skill_paths, &sess);

    var ag = state.agent_template;
    ag.skills = refs;

    try sess.append(arena, .user, goal);
    const reply = try ag.run(arena, &sess);
    sess.persist(state.io, state.dirs.sessions_dir) catch {};
    return reply;
}

/// Stop the runtime and release all memory owned by it.
pub fn stop(rt: *Runtime) void {
    const state: *RuntimeState = @ptrCast(@alignCast(rt));
    const gpa = state.gpa;
    state.arena_state.deinit();
    gpa.destroy(state);
}

fn runtimeSessionId(arena: std.mem.Allocator, io: std.Io, seq: usize) ![]const u8 {
    const ts_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return std.fmt.allocPrint(arena, "embed-{d}-{d}", .{ ts_ms, seq });
}

fn injectSkills(arena: std.mem.Allocator, io: std.Io, search_paths: []const []const u8, sess: *session.Session) []const agent.SkillRef {
    var reg: skill.Registry = .{};
    reg.discoverAll(arena, io, search_paths) catch return &.{};
    if (reg.count() == 0) return &.{};
    const text = reg.manifest(arena) catch return &.{};
    sess.append(arena, .system, text) catch {};
    const refs = arena.alloc(agent.SkillRef, reg.count()) catch return &.{};
    for (reg.skills.items, 0..) |s, i| refs[i] = .{ .name = s.name, .dir = s.dir };
    return refs;
}
