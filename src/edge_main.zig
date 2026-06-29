//! Standalone scoot-edge companion binary.
//!
//! E1 posture: optional report-only messenger. This file intentionally does not
//! import `src/internal.zig` and does not link into the core `scoot` executable.
//! It drives Scoot only through public process interfaces such as
//! `scoot daemon status --json`.
const std = @import("std");
const build_options = @import("build_options");
const proc = @import("tools/proc.zig");

const usage =
    \\scoot-edge - optional report-only Scoot fleet messenger (E1 skeleton)
    \\
    \\Usage:
    \\  scoot-edge status [options]      print one status heartbeat envelope as NDJSON
    \\  scoot-edge post-once [options]   POST one status heartbeat to an HTTPS endpoint
    \\
    \\Options:
    \\  --node-id <id>          stable node id (default: hostname when available, else "local")
    \\  --scoot-bin <path>      scoot executable to launch (default: scoot)
    \\  --scoot-home <dir>      pass --scoot-home to the child scoot process
    \\  --center-url <https>    exact HTTPS telemetry endpoint for post-once
    \\  --token-env <name>      env var containing the per-node bearer token (default: SCOOT_EDGE_TOKEN)
    \\  --timeout-ms <N>        hard timeout for child/network operations (default: 30000)
    \\  --allow-insecure-http   allow http:// center URLs for local/dev testing only
    \\  -h, --help             show this help
    \\  -v, --version          show version
    \\
    \\No outbound network happens in `status`; `post-once` requires HTTPS and a non-empty token
    \\unless --allow-insecure-http is explicitly set for local/dev testing.
    \\
;

const Command = enum { status, post_once };

const default_timeout_ms: u64 = 30_000;

const Options = struct {
    command: Command = .status,
    node_id: ?[]const u8 = null,
    scoot_bin: []const u8 = "scoot",
    scoot_home: ?[]const u8 = null,
    center_url: ?[]const u8 = null,
    token_env: []const u8 = "SCOOT_EDGE_TOKEN",
    timeout_ms: u64 = default_timeout_ms,
    allow_insecure_http: bool = false,
};

const DaemonSummary = struct {
    state: []const u8,
    clean_prev_stop: bool,
    since: ?i64,
};

const AuditStats = struct {
    run: usize = 0,
    tool_call: usize = 0,
    policy_deny: usize = 0,
    system_error: usize = 0,
};

const StatusBody = struct {
    scoot_version: []const u8,
    edge_version: []const u8,
    daemon: DaemonSummary,
    policy_ceiling: []const u8 = "readonly",
    audit_stats: AuditStats = .{},
};

const StatusEnvelope = struct {
    v: u32 = 1,
    type: []const u8 = "status",
    node_id: []const u8,
    sent_ts: i64,
    body: StatusBody,
};

const StatePartial = struct {
    status: []const u8 = "unknown",
    started_at_unix: i64 = 0,
    updated_at_unix: i64 = 0,
    stopped_at_unix: ?i64 = null,
};

const DaemonStatusPartial = struct {
    state: ?StatePartial = null,
    liveness: []const u8 = "unknown",
};

const ChildOutput = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    timed_out: bool = false,
};

const FetchResult = struct {
    status: u16 = 0,
    body: []const u8 = "",
    timed_out: bool = false,
    err: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(out, args) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    const envelope = try collectStatusEnvelope(arena, io, env, opts);
    var payload: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(envelope, .{}, &payload.writer);
    try payload.writer.writeByte('\n');

    switch (opts.command) {
        .status => try out.writeAll(payload.writer.buffered()),
        .post_once => {
            const center_url = opts.center_url orelse {
                try err_out.writeAll("error: post-once requires --center-url <https://...>\n");
                die(err_out, 2);
            };
            if (!centerUrlAllowed(center_url, opts.allow_insecure_http)) {
                try err_out.writeAll("error: --center-url must use https://; http:// is allowed only with --allow-insecure-http for local/dev testing\n");
                die(err_out, 2);
            }
            const token = env.get(opts.token_env) orelse {
                try err_out.print("error: token env var {s} is not set or empty\n", .{opts.token_env});
                die(err_out, 2);
            };
            if (token.len == 0) {
                try err_out.print("error: token env var {s} is not set or empty\n", .{opts.token_env});
                die(err_out, 2);
            }
            const res = try postJson(arena, io, center_url, token, payload.writer.buffered(), opts.timeout_ms);
            if (res.timed_out) {
                try err_out.writeAll("error: telemetry POST timed out\n");
                die(err_out, 1);
            }
            if (res.err) |e| {
                try err_out.print("error: telemetry POST failed: {s}\n", .{e});
                die(err_out, 1);
            }
            if (res.status < 200 or res.status >= 300) {
                try err_out.print("error: telemetry POST returned HTTP {d}\n", .{res.status});
                die(err_out, 1);
            }
            try out.print("posted status node_id={s} status={d}\n", .{ envelope.node_id, res.status });
        },
    }
}

fn parseArgs(out: *std.Io.Writer, args: []const []const u8) !Options {
    var opts: Options = .{};
    var i: usize = 1;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
        if (std.mem.eql(u8, args[i], "status")) {
            opts.command = .status;
        } else if (std.mem.eql(u8, args[i], "post-once")) {
            opts.command = .post_once;
        } else {
            try out.print("error: unknown command '{s}'\n\n", .{args[i]});
            try out.writeAll(usage);
            die(out, 2);
        }
        i += 1;
    }
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            return error.HelpShown;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try out.print("scoot-edge {s}\n", .{build_options.version});
            return error.HelpShown;
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            opts.node_id = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--scoot-bin")) {
            opts.scoot_bin = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--scoot-home")) {
            opts.scoot_home = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--center-url")) {
            opts.center_url = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            opts.token_env = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            const raw = try nextArg(out, args, &i, arg);
            opts.timeout_ms = std.fmt.parseInt(u64, raw, 10) catch {
                try out.print("error: --timeout-ms must be a non-negative integer: '{s}'\n", .{raw});
                die(out, 2);
            };
        } else if (std.mem.eql(u8, arg, "--allow-insecure-http")) {
            opts.allow_insecure_http = true;
        } else {
            try out.print("error: unknown argument '{s}'\n\n", .{arg});
            try out.writeAll(usage);
            die(out, 2);
        }
    }
    return opts;
}

fn nextArg(out: *std.Io.Writer, args: []const []const u8, i: *usize, name: []const u8) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len or args[i.*].len == 0) {
        try out.print("error: {s} requires a value\n", .{name});
        die(out, 2);
    }
    return args[i.*];
}

fn collectStatusEnvelope(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
) !StatusEnvelope {
    const daemon_json = try runScootDaemonStatus(arena, io, opts);
    const scoot_version = try runScootVersion(arena, io, opts);
    const node_id = if (opts.node_id) |id| id else try defaultNodeId(arena, env);
    return .{
        .node_id = node_id,
        .sent_ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .body = .{
            .scoot_version = scoot_version,
            .edge_version = build_options.version,
            .daemon = try summarizeDaemonStatus(arena, daemon_json),
        },
    };
}

fn runScootDaemonStatus(arena: std.mem.Allocator, io: std.Io, opts: Options) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, opts.scoot_bin);
    if (opts.scoot_home) |home| {
        try argv.append(arena, "--scoot-home");
        try argv.append(arena, home);
    }
    try argv.append(arena, "daemon");
    try argv.append(arena, "status");
    try argv.append(arena, "--json");
    const child = try runChild(arena, io, argv.items, opts.timeout_ms);
    if (child.timed_out) return error.ChildTimeout;
    if (child.exit_code != 0) return error.ChildFailed;
    return child.stdout;
}

fn runScootVersion(arena: std.mem.Allocator, io: std.Io, opts: Options) ![]const u8 {
    const argv = [_][]const u8{ opts.scoot_bin, "--version" };
    const child = try runChild(arena, io, &argv, opts.timeout_ms);
    if (child.timed_out or child.exit_code != 0) return "unknown";
    const trimmed = std.mem.trim(u8, child.stdout, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "scoot ")) return trimmed["scoot ".len..];
    return trimmed;
}

fn runChild(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8, timeout_ms: u64) !ChildOutput {
    const effective_timeout_ms = proc.effectiveTimeoutMs(timeout_ms, default_timeout_ms);
    const base: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(effective_timeout_ms)),
    } };
    const timeout = base.toDeadline(io);
    const res = std.process.run(arena, io, .{
        .argv = argv,
        .timeout = timeout,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.Timeout => return .{ .stdout = "", .stderr = "", .exit_code = -1, .timed_out = true },
        else => return err,
    };
    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = termToCode(res.term),
    };
}

fn summarizeDaemonStatus(arena: std.mem.Allocator, bytes: []const u8) !DaemonSummary {
    const parsed = std.json.parseFromSliceLeaky(DaemonStatusPartial, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .state = "unknown", .clean_prev_stop = false, .since = null };
    const state = parsed.state orelse return .{ .state = "unknown", .clean_prev_stop = true, .since = null };
    const stale_running = std.mem.eql(u8, state.status, "running") and std.mem.eql(u8, parsed.liveness, "dead");
    const since = if (state.stopped_at_unix) |t| t else if (state.started_at_unix != 0) state.started_at_unix else state.updated_at_unix;
    return .{
        .state = state.status,
        .clean_prev_stop = !stale_running,
        .since = since,
    };
}

fn defaultNodeId(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("SCOOT_EDGE_NODE_ID")) |id| if (id.len != 0) return id;
    if (env.get("HOSTNAME")) |h| if (h.len != 0) return h;
    return arena.dupe(u8, "local");
}

fn postJson(arena: std.mem.Allocator, io: std.Io, url: []const u8, token: []const u8, payload: []const u8, timeout_ms: u64) !FetchResult {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    var resp: std.Io.Writer.Allocating = .init(arena);
    return fetchWithTimeout(io, &client, url, auth, payload, &resp, timeout_ms);
}

fn centerUrlAllowed(url: []const u8, allow_insecure_http: bool) bool {
    return std.mem.startsWith(u8, url, "https://") or
        (allow_insecure_http and std.mem.startsWith(u8, url, "http://"));
}

fn fetchWithTimeout(
    io: std.Io,
    client: *std.http.Client,
    url: []const u8,
    auth: []const u8,
    payload: []const u8,
    resp: *std.Io.Writer.Allocating,
    timeout_ms: u64,
) FetchResult {
    const effective_timeout_ms = proc.effectiveTimeoutMs(timeout_ms, default_timeout_ms);

    const Outcome = union(enum) { done: FetchResult, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.done, doPost, .{ client, url, auth, payload, resp }) catch |err| return .{ .err = @errorName(err) };
    sel.concurrent(.timed_out, sleepDeadline, .{ io, effective_timeout_ms }) catch |err| {
        sel.cancelDiscard();
        return .{ .err = @errorName(err) };
    };
    const winner = sel.await() catch |err| {
        sel.cancelDiscard();
        return .{ .err = @errorName(err) };
    };
    sel.cancelDiscard();
    return switch (winner) {
        .done => |r| r,
        .timed_out => .{ .timed_out = true },
    };
}

fn doPost(client: *std.http.Client, url: []const u8, auth: []const u8, payload: []const u8, resp: *std.Io.Writer.Allocating) FetchResult {
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{
            .content_type = .{ .override = "application/x-ndjson" },
            .authorization = .{ .override = auth },
        },
        .response_writer = &resp.writer,
    }) catch |e| return .{ .err = @errorName(e) };
    return .{ .status = @intFromEnum(result.status), .body = resp.writer.buffered() };
}

fn sleepDeadline(io: std.Io, timeout_ms: u64) void {
    const d: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    };
    d.sleep(io) catch {};
}

fn termToCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        else => -1,
    };
}

fn die(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

test "summarizeDaemonStatus maps daemon JSON to E1 heartbeat daemon summary" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\{"format":"scoot.daemon.status.v1","state":{"status":"running","pid":12,"started_at_unix":10,"updated_at_unix":11,"schedule_enabled":true,"jobs":1,"poll_ms":1000},"pid_file":12,"liveness":"alive","probed_pid":12}
    ;
    const got = try summarizeDaemonStatus(arena, src);
    try std.testing.expectEqualStrings("running", got.state);
    try std.testing.expect(got.clean_prev_stop);
    try std.testing.expectEqual(@as(?i64, 10), got.since);
}

test "summarizeDaemonStatus flags stale running daemon" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\{"state":{"status":"running","started_at_unix":10,"updated_at_unix":11},"liveness":"dead"}
    ;
    const got = try summarizeDaemonStatus(arena, src);
    try std.testing.expectEqualStrings("running", got.state);
    try std.testing.expect(!got.clean_prev_stop);
}

test "post-once requires HTTPS URL by parser-level convention" {
    try std.testing.expect(centerUrlAllowed("https://center.example/telemetry", false));
    try std.testing.expect(centerUrlAllowed("https://center.example/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("http://localhost:8080/telemetry", false));
    try std.testing.expect(centerUrlAllowed("http://localhost:8080/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("ftp://center.example/telemetry", true));
}

test {
    std.testing.refAllDecls(@This());
}
