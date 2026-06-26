//! Stable embedding API for the `scoot` package.
//!
//! The public surface is intentionally a narrow lifecycle facade:
//! `Runtime` + `start` / `run` / `stop` + `version`.

const std = @import("std");
const agent = @import("agent.zig");
const audit = @import("audit.zig");
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

pub const RunResult = struct {
    session_id: []const u8,
    reply: []const u8,
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
    if (cfg.agent.max_turns == 0) return error.InvalidAgentConfig;

    const token_value = if (cfg.resolveToken(arena, io, options.env)) |secret|
        secret.value
    else |err| switch (err) {
        error.NoApiKey => "",
        else => return err,
    };
    const token = try arena.dupe(u8, token_value);

    state.client = llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
    state.client.ca_file = cfg.backend.ca_file;
    state.client.timeout_ms = cfg.backend.timeout_ms;
    state.client.extra_body = cfg.backend.extra_body;
    state.client.model_ctx.store = cfg.backend.store;

    state.agent_template = agent.Agent.initClient(&state.client);
    state.agent_template.max_turns = cfg.agent.max_turns;
    state.agent_template.tool_timeout_ms = cfg.tools.timeout_ms;
    state.agent_template.policy_mode = policy.Mode.fromString(cfg.tools.policy);
    state.agent_template.ca_file = cfg.backend.ca_file;
    state.agent_template.env = options.env;
    state.agent_template.context_budget_bytes = cfg.agent.context_budget_bytes;
    state.agent_template.compactor = try cfg.resolveCompressor(arena);
    state.agent_template.confine_writes = cfg.tools.confine_writes;
    state.agent_template.block_internal_http = cfg.tools.block_internal_http;
    state.agent_template.mcp_servers = cfg.mcp.servers;
    state.dirs = cfg.dirs;
    state.skill_paths = if (cfg.skills.enabled) try cfg.skillPaths(arena) else &.{};

    return @ptrCast(state);
}

/// Run one goal, equivalent in shape to CLI `-e`.
///
/// The returned slice is owned by the runtime and remains valid until `stop`.
pub fn run(rt: *Runtime, goal: []const u8) ![]const u8 {
    return (try runDetailed(rt, goal)).reply;
}

/// Run one goal and return protocol-friendly metadata for internal callers.
///
/// Returned slices are owned by the runtime and remain valid until `stop`.
pub fn runDetailed(rt: *Runtime, goal: []const u8) !RunResult {
    const state: *RuntimeState = @ptrCast(@alignCast(rt));
    const runtime_arena = state.arena_state.allocator();
    var run_arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer run_arena_state.deinit();
    const arena = run_arena_state.allocator();

    var sess = session.Session.init(try runtimeSessionId(arena, state.io, state.run_seq));
    state.run_seq += 1;
    defer sess.deinit(arena);
    try sess.append(arena, .system, agent.system_prompt);
    const refs = injectSkills(arena, state.io, state.skill_paths, &sess);

    var ag = state.agent_template;
    ag.skills = refs;
    var sink: ApiAuditSink = .{};
    sink.open(arena, state.io, state.dirs.logs_dir, sess.id);
    defer sink.close(state.io);
    ag.audit = sink.loggerPtr();

    try sess.append(arena, .user, goal);
    if (ag.audit) |lg| lg.log(.run, goal) catch {};
    const reply = ag.run(arena, &sess) catch |err| {
        if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
        sess.persist(state.io, state.dirs.sessions_dir) catch {};
        return err;
    };
    const owned_reply = try runtime_arena.dupe(u8, reply);
    const owned_session_id = try runtime_arena.dupe(u8, sess.id);
    sess.persist(state.io, state.dirs.sessions_dir) catch {};
    return .{
        .session_id = owned_session_id,
        .reply = owned_reply,
    };
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

const ApiAuditSink = struct {
    file: ?std.Io.File = null,
    fw: std.Io.File.Writer = undefined,
    logger: audit.Logger = undefined,
    buf: [4096]u8 = undefined,

    fn open(self: *ApiAuditSink, arena: std.mem.Allocator, io: std.Io, logs_dir: []const u8, session_id: []const u8) void {
        const path = std.fmt.allocPrint(arena, "{s}/audit.jsonl", .{logs_dir}) catch return;
        _ = audit.rotateFileIfTooLarge(io, arena, path, audit.default_max_jsonl_bytes) catch false;
        const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return;
        self.file = f;
        f.setPermissions(io, std.Io.File.Permissions.fromMode(0o600)) catch {};
        self.fw = f.writer(io, &self.buf);
        if (f.stat(io)) |st| {
            self.fw.seekTo(st.size) catch {};
        } else |_| {}
        self.logger = audit.Logger.init(&self.fw.interface, io);
        self.logger.setContext(session_id, null);
    }

    fn loggerPtr(self: *ApiAuditSink) ?*audit.Logger {
        return if (self.file != null) &self.logger else null;
    }

    fn close(self: *ApiAuditSink, io: std.Io) void {
        if (self.file) |f| {
            self.fw.interface.flush() catch {};
            f.close(io);
        }
    }
};

const TestBrain = struct {
    steps: []const []const u8,
    idx: usize = 0,
};

fn scriptedComplete(
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    messages: []const llm.Message,
    opts: llm.ChatOptions,
) anyerror!llm.Completion {
    _ = messages;
    _ = opts;
    const self: *TestBrain = @ptrCast(@alignCast(ctx));
    if (self.idx >= self.steps.len) return error.ScriptExhausted;
    const content = self.steps[self.idx];
    self.idx += 1;
    return .{ .content = try arena.dupe(u8, content), .finish_reason = "stop" };
}

test "embedded run writes session-correlated audit and keeps replies valid until stop" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const home = "/tmp/scoot_api_embed_audit_test";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    const rt = try start(gpa, io, .{ .env = &env, .scoot_home = home });
    defer stop(rt);

    var brain = TestBrain{ .steps = &.{
        "{\"thought\":\"first\",\"action\":\"final\",\"action_input\":\"one-ok\"}",
        "{\"thought\":\"second\",\"action\":\"final\",\"action_input\":\"two-ok\"}",
    } };
    const state: *RuntimeState = @ptrCast(@alignCast(rt));
    state.agent_template.complete_ctx = &brain;
    state.agent_template.complete_fn = scriptedComplete;
    state.agent_template.max_turns = 2;
    state.skill_paths = &.{};

    const r1 = try run(rt, "first goal");
    const r2 = try run(rt, "second goal");
    try std.testing.expectEqualStrings("one-ok", r1);
    try std.testing.expectEqualStrings("two-ok", r2);
    try std.testing.expectEqual(@as(usize, 2), brain.idx);

    const log_path = home ++ "/logs/audit.jsonl";
    const log = try cwd.readFileAlloc(io, log_path, gpa, .limited(64 * 1024));
    defer gpa.free(log);

    const Event = struct {
        seq: u64,
        ts: i64,
        session_id: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
        kind: []const u8,
        msg: []const u8,
    };
    var first_sid_buf: [128]u8 = undefined;
    var second_sid_buf: [128]u8 = undefined;
    var first_sid_len: usize = 0;
    var second_sid_len: usize = 0;
    var run_count: usize = 0;
    var final_count: usize = 0;

    var it = std.mem.tokenizeScalar(u8, log, '\n');
    while (it.next()) |line| {
        const parsed = try std.json.parseFromSlice(Event, gpa, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const sid = parsed.value.session_id orelse return error.MissingSessionId;
        try std.testing.expect(std.mem.startsWith(u8, sid, "embed-"));
        if (std.mem.eql(u8, parsed.value.kind, "run")) {
            run_count += 1;
            if (first_sid_len == 0) {
                try std.testing.expect(sid.len <= first_sid_buf.len);
                @memcpy(first_sid_buf[0..sid.len], sid);
                first_sid_len = sid.len;
            } else {
                try std.testing.expect(sid.len <= second_sid_buf.len);
                @memcpy(second_sid_buf[0..sid.len], sid);
                second_sid_len = sid.len;
            }
        } else if (std.mem.eql(u8, parsed.value.kind, "final")) {
            final_count += 1;
        }
        _ = parsed.value.seq;
        _ = parsed.value.ts;
        _ = parsed.value.run_id;
        _ = parsed.value.msg;
    }

    try std.testing.expectEqual(@as(usize, 2), run_count);
    try std.testing.expectEqual(@as(usize, 2), final_count);
    try std.testing.expect(first_sid_len > 0);
    try std.testing.expect(second_sid_len > 0);
    const first_sid = first_sid_buf[0..first_sid_len];
    const second_sid = second_sid_buf[0..second_sid_len];
    try std.testing.expect(!std.mem.eql(u8, first_sid, second_sid));

    const first_session = try std.fmt.allocPrint(gpa, "{s}/state/sessions/{s}.jsonl", .{ home, first_sid });
    defer gpa.free(first_session);
    const second_session = try std.fmt.allocPrint(gpa, "{s}/state/sessions/{s}.jsonl", .{ home, second_sid });
    defer gpa.free(second_session);
    try std.testing.expect(fileExists(io, first_session));
    try std.testing.expect(fileExists(io, second_session));
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}
