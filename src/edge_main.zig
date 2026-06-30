//! Standalone scoot-edge companion binary.
//!
//! E1 posture: optional report-only messenger. This file intentionally does not
//! import `src/internal.zig` and does not link into the core `scoot` executable.
//! It drives Scoot only through public process interfaces such as
//! `scoot daemon status --json`.
//!
//! E1 capabilities: one-shot `status` / `post-once`, plus a continuous `run`
//! heartbeat loop (periodic dial-out POST with bounded jittered backoff) and an
//! opt-in, advisory `node` capability descriptor for capability-aware routing.
//! The loop never opens a listener, only ever reports up, and shuts down cleanly
//! (exit 0) on SIGINT/SIGTERM so it is a well-behaved systemd/launchd service.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const proc = @import("tools/proc.zig");

const usage =
    \\scoot-edge - optional report-only Scoot fleet messenger (E1)
    \\
    \\Usage:
    \\  scoot-edge status [options]      print one status heartbeat envelope as NDJSON
    \\  scoot-edge post-once [options]   POST one status heartbeat to an HTTPS endpoint
    \\  scoot-edge run [options]         POST a status heartbeat on a fixed interval until stopped
    \\
    \\Options:
    \\  --node-id <id>          stable node id (default: hostname when available, else "local")
    \\  --scoot-bin <path>      scoot executable to launch (default: scoot)
    \\  --scoot-home <dir>      pass --scoot-home to the child scoot process
    \\  --center-url <https>    exact HTTPS telemetry endpoint for post-once/run
    \\  --token-env <name>      env var containing the per-node bearer token (default: SCOOT_EDGE_TOKEN)
    \\  --timeout-ms <N>        hard timeout for each child/network operation (default: 30000)
    \\  --interval-ms <N>       run: delay between heartbeats (default: 60000)
    \\  --max-posts <N>         run: stop after N successful heartbeats (default: 0 = unlimited)
    \\  --report-capabilities   attach an advisory node capability descriptor to the heartbeat (default: off)
    \\  --label <k:v>           operator routing label for the node descriptor (repeatable; also SCOOT_EDGE_LABELS)
    \\  --skill <name>          advertised skill name for the node descriptor (repeatable; also SCOOT_EDGE_SKILLS)
    \\  --allow-insecure-http   allow http:// loopback center URLs for local/dev testing only
    \\  -h, --help             show this help
    \\  -v, --version          show version
    \\
    \\No outbound network happens in `status`; `post-once` and `run` require HTTPS and a non-empty
    \\token unless --allow-insecure-http is explicitly set for local/dev loopback testing.
    \\`run` dials out only — it never opens a listener — and reports up only. It shuts down
    \\cleanly (exit 0) on SIGINT/SIGTERM, finishing the in-flight heartbeat first, so a supervisor
    \\(systemd/launchd) stop is graceful rather than a hard kill.
    \\
    \\Exit codes:
    \\  0  success (or a clean SIGINT/SIGTERM shutdown of `run`)
    \\  1  dial-out POST failed in post-once (network error, timeout, or non-2xx)
    \\  2  configuration/usage error (bad flag, or missing/invalid --center-url or token)
    \\  3  could not collect local status (the `scoot daemon status --json` child failed)
    \\
;

const Command = enum { status, post_once, run };

const default_timeout_ms: u64 = 30_000;
const default_interval_ms: u64 = 60_000;
/// Upper bound for transient-failure backoff so a long outage cannot push the
/// retry delay arbitrarily high.
const max_backoff_ms: u64 = 900_000;
/// Lower bound for transient-failure backoff. The steady-state interval is the
/// backoff base, so a tiny (or `0`-normalized) interval must not collapse the
/// retry delay to a busy-spin that hammers the center while it is down.
const min_backoff_ms: u64 = 1_000;
/// The center-dispatched job ceiling reported by the heartbeat. E2 job dispatch
/// (and any local `edge.max_job_policy` knob) does not exist yet, so this is the
/// documented default; advertising it never grants authority.
const default_max_job_policy = "readonly";

/// Stable process exit codes, documented in `usage` and EDGE.md so supervisors
/// and scripts can branch on them. `0` is success (including a clean `run`
/// shutdown on SIGINT/SIGTERM).
const exit_post_failed: u8 = 1;
const exit_config_error: u8 = 2;
const exit_collect_failed: u8 = 3;

/// Advisory, readonly-aligned built-in actions a node declares it is "for". This
/// is routing metadata only; the local policy ceiling still gates every job.
const advisory_readonly_tools = [_][]const u8{ "file_read", "grep", "glob", "outline", "http_request" };

const Options = struct {
    command: Command = .status,
    node_id: ?[]const u8 = null,
    scoot_bin: []const u8 = "scoot",
    scoot_home: ?[]const u8 = null,
    center_url: ?[]const u8 = null,
    token_env: []const u8 = "SCOOT_EDGE_TOKEN",
    timeout_ms: u64 = default_timeout_ms,
    interval_ms: u64 = default_interval_ms,
    max_posts: u64 = 0,
    report_capabilities: bool = false,
    labels: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
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

const NodeCapabilities = struct {
    max_job_policy: []const u8,
    tools: []const []const u8,
    skills: []const []const u8,
};

/// Opt-in, advisory node identity/capability descriptor (`--report-capabilities`).
/// Declarative routing metadata only — advertising a capability never widens what
/// the edge will execute; the local policy ceiling still gates every job.
const NodeDescriptor = struct {
    labels: []const []const u8,
    os: []const u8,
    arch: []const u8,
    capabilities: NodeCapabilities,
};

const StatusBody = struct {
    scoot_version: []const u8,
    edge_version: []const u8,
    daemon: DaemonSummary,
    policy_ceiling: []const u8 = "readonly",
    audit_stats: AuditStats = .{},
    node: ?NodeDescriptor = null,
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
    const opts = parseArgs(arena, out, args) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    switch (opts.command) {
        .status => {
            const envelope = try collectOrDie(arena, io, env, opts, err_out);
            try out.writeAll(try stringifyEnvelope(arena, envelope));
        },
        .post_once => {
            const ca = try requireCenterAndToken(err_out, env, opts);
            const envelope = try collectOrDie(arena, io, env, opts, err_out);
            const payload = try stringifyEnvelope(arena, envelope);
            const res = try postJson(arena, io, ca.url, ca.token, payload, opts.timeout_ms);
            if (res.timed_out) {
                try err_out.writeAll("error: telemetry POST timed out\n");
                die(err_out, exit_post_failed);
            }
            if (res.err) |e| {
                try err_out.print("error: telemetry POST failed: {s}\n", .{e});
                die(err_out, exit_post_failed);
            }
            if (res.status < 200 or res.status >= 300) {
                try err_out.print("error: telemetry POST returned HTTP {d}\n", .{res.status});
                die(err_out, exit_post_failed);
            }
            try out.print("posted status node_id={s} status={d}\n", .{ envelope.node_id, res.status });
        },
        .run => try runLoop(io, env, opts, out, err_out),
    }
}

/// Required HTTPS endpoint plus bearer token for any dial-out command. Exits with
/// code 2 (a configuration error) when either is missing or insecure.
const CenterAuth = struct { url: []const u8, token: []const u8 };

fn requireCenterAndToken(
    err_out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    opts: Options,
) !CenterAuth {
    const center_url = opts.center_url orelse {
        try err_out.writeAll("error: this command requires --center-url <https://...>\n");
        die(err_out, exit_config_error);
    };
    if (!centerUrlAllowed(center_url, opts.allow_insecure_http)) {
        try err_out.writeAll("error: --center-url must use https://; http:// is allowed only with --allow-insecure-http for local/dev loopback testing\n");
        die(err_out, exit_config_error);
    }
    const token = env.get(opts.token_env) orelse {
        try err_out.print("error: token env var {s} is not set or empty\n", .{opts.token_env});
        die(err_out, exit_config_error);
    };
    if (token.len == 0) {
        try err_out.print("error: token env var {s} is not set or empty\n", .{opts.token_env});
        die(err_out, exit_config_error);
    }
    return .{ .url = center_url, .token = token };
}

/// Collects the local status envelope for a one-shot command, translating a
/// failed/timed-out `scoot daemon status --json` child into a clean message and
/// the stable `exit_collect_failed` code instead of a raw error stack trace.
fn collectOrDie(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    err_out: *std.Io.Writer,
) !StatusEnvelope {
    return collectStatusEnvelope(arena, io, env, opts) catch |e| switch (e) {
        error.ChildTimeout => {
            try err_out.print(
                "error: timed out collecting local status (the '{s} daemon status --json' child exceeded {d}ms)\n",
                .{ opts.scoot_bin, proc.effectiveTimeoutMs(opts.timeout_ms, default_timeout_ms) },
            );
            die(err_out, exit_collect_failed);
        },
        error.ChildFailed => {
            try err_out.print(
                "error: could not collect local status; the '{s} daemon status --json' child failed (is scoot installed and on PATH?)\n",
                .{opts.scoot_bin},
            );
            die(err_out, exit_collect_failed);
        },
        error.ChildSpawnFailed => {
            try err_out.print(
                "error: could not run '{s}' (is scoot installed and on PATH?)\n",
                .{opts.scoot_bin},
            );
            die(err_out, exit_collect_failed);
        },
        else => return e,
    };
}

/// Set by the SIGINT/SIGTERM handler so an unbounded `run` loop finishes the
/// in-flight heartbeat and exits cleanly (status 0) instead of being hard-killed.
/// POSIX only; elsewhere the loop still relies on the supervisor's stop signal.
var stop_requested: std.atomic.Value(bool) = .init(false);

const stop_signals_supported = builtin.os.tag != .windows;

fn stopRequested() bool {
    return stop_requested.load(.monotonic);
}

fn installStopHandlers() void {
    if (comptime !stop_signals_supported) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleStop },
        .mask = std.posix.sigemptyset(),
        // SA_RESTART so an in-flight POST is not aborted with EINTR; the flag is
        // observed at the next loop / backoff-slice boundary instead.
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn handleStop(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

fn stringifyEnvelope(arena: std.mem.Allocator, envelope: StatusEnvelope) ![]const u8 {
    var payload: std.Io.Writer.Allocating = .init(arena);
    // Omit null optionals so a bare heartbeat (no `node` descriptor) stays byte-identical.
    try std.json.Stringify.value(envelope, .{ .emit_null_optional_fields = false }, &payload.writer);
    try payload.writer.writeByte('\n');
    return payload.writer.buffered();
}

/// Continuous report-only heartbeat loop. Each iteration uses a per-turn arena
/// that is reset between posts, so an unbounded run holds bounded memory. A
/// transient failure (collection, encode, network, non-2xx) never aborts the
/// loop: it is logged, the failure streak drives a bounded jittered backoff, and
/// the loop continues. SIGINT/SIGTERM requests a clean shutdown: the in-flight
/// heartbeat finishes, the loop breaks, and the process exits 0.
fn runLoop(
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !void {
    const ca = try requireCenterAndToken(err_out, env, opts);
    installStopHandlers();

    var iter_arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer iter_arena_state.deinit();

    var prng = std.Random.DefaultPrng.init(@bitCast(std.Io.Timestamp.now(io, .real).toMilliseconds()));
    const rand = prng.random();

    var successes: u64 = 0;
    var fail_streak: u32 = 0;
    while (!stopRequested()) {
        _ = iter_arena_state.reset(.retain_capacity);
        const iter = iter_arena_state.allocator();

        const failed = postOneHeartbeat(iter, io, env, opts, ca, out, err_out) catch |e| blk: {
            try err_out.print("warn: heartbeat failed: {s}; will retry\n", .{@errorName(e)});
            break :blk true;
        };
        out.flush() catch {};
        err_out.flush() catch {};

        if (failed) {
            fail_streak +|= 1;
        } else {
            fail_streak = 0;
            successes += 1;
            if (opts.max_posts != 0 and successes >= opts.max_posts) break;
        }

        const wait_ms = if (fail_streak == 0)
            opts.interval_ms
        else
            jitteredBackoffMs(rand, fail_streak, opts.interval_ms);
        interruptibleSleep(io, wait_ms);
    }
    if (stopRequested()) {
        err_out.writeAll("scoot-edge: stop signal received; exiting cleanly\n") catch {};
        err_out.flush() catch {};
    }
}

/// Collects and posts one heartbeat. Returns `true` on a transient (retryable)
/// failure and `false` on success. Only genuinely unexpected errors propagate.
fn postOneHeartbeat(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    ca: CenterAuth,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !bool {
    const envelope = collectStatusEnvelope(arena, io, env, opts) catch |e| {
        try err_out.print("warn: heartbeat collection failed: {s}; will retry\n", .{@errorName(e)});
        return true;
    };
    const payload = try stringifyEnvelope(arena, envelope);
    const res = postJson(arena, io, ca.url, ca.token, payload, opts.timeout_ms) catch |e| {
        try err_out.print("warn: heartbeat POST failed: {s}; will retry\n", .{@errorName(e)});
        return true;
    };
    if (res.timed_out) {
        try err_out.writeAll("warn: heartbeat POST timed out; will retry\n");
        return true;
    }
    if (res.err) |e| {
        try err_out.print("warn: heartbeat POST failed: {s}; will retry\n", .{e});
        return true;
    }
    if (res.status < 200 or res.status >= 300) {
        try err_out.print("warn: heartbeat POST returned HTTP {d}; will retry\n", .{res.status});
        return true;
    }
    try out.print("posted status node_id={s} status={d}\n", .{ envelope.node_id, res.status });
    return false;
}

/// Monotonic, overflow-safe exponential backoff ceiling for a 1-based attempt:
/// attempt 1 -> base, attempt 2 -> 2*base, ... clamped to `cap_ms`.
fn backoffCeilingMs(attempt: u32, base_ms: u64, cap_ms: u64) u64 {
    var v = @min(base_ms, cap_ms);
    var i: u32 = 1;
    while (i < attempt) : (i += 1) {
        if (v >= cap_ms) return cap_ms;
        v = if (v > cap_ms / 2) cap_ms else v * 2;
    }
    return v;
}

/// Full-jitter delay in `[min(base, ceiling), ceiling]` to avoid synchronized
/// fleet-wide retry storms against the center. The base is floored at
/// `min_backoff_ms` so a tiny steady-state interval still backs off on failure.
fn jitteredBackoffMs(rand: std.Random, attempt: u32, base_ms: u64) u64 {
    const effective_base = @max(base_ms, min_backoff_ms);
    const ceiling = backoffCeilingMs(attempt, effective_base, max_backoff_ms);
    const floor = @min(effective_base, ceiling);
    if (ceiling <= floor) return ceiling;
    return floor + rand.uintLessThan(u64, ceiling - floor + 1);
}

fn parseArgs(arena: std.mem.Allocator, out: *std.Io.Writer, args: []const []const u8) !Options {
    var opts: Options = .{};
    var labels: std.ArrayList([]const u8) = .empty;
    var skills: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
        if (std.mem.eql(u8, args[i], "status")) {
            opts.command = .status;
        } else if (std.mem.eql(u8, args[i], "post-once")) {
            opts.command = .post_once;
        } else if (std.mem.eql(u8, args[i], "run")) {
            opts.command = .run;
        } else {
            try out.print("error: unknown command '{s}'\n\n", .{args[i]});
            try out.writeAll(usage);
            die(out, exit_config_error);
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
            opts.timeout_ms = try parseU64Arg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            const parsed = try parseU64Arg(out, args, &i, arg);
            // 0 means "use the default" (consistent with --timeout-ms); it also
            // keeps the success-path loop from degenerating into a POST storm.
            opts.interval_ms = if (parsed == 0) default_interval_ms else parsed;
        } else if (std.mem.eql(u8, arg, "--max-posts")) {
            opts.max_posts = try parseU64Arg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--report-capabilities")) {
            opts.report_capabilities = true;
        } else if (std.mem.eql(u8, arg, "--label")) {
            try labels.append(arena, try nextArg(out, args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--skill")) {
            try skills.append(arena, try nextArg(out, args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--allow-insecure-http")) {
            opts.allow_insecure_http = true;
        } else {
            try out.print("error: unknown argument '{s}'\n\n", .{arg});
            try out.writeAll(usage);
            die(out, exit_config_error);
        }
    }
    opts.labels = labels.items;
    opts.skills = skills.items;
    return opts;
}

fn parseU64Arg(out: *std.Io.Writer, args: []const []const u8, i: *usize, name: []const u8) !u64 {
    const raw = try nextArg(out, args, i, name);
    return std.fmt.parseInt(u64, raw, 10) catch {
        try out.print("error: {s} must be a non-negative integer: '{s}'\n", .{ name, raw });
        die(out, exit_config_error);
    };
}

fn nextArg(out: *std.Io.Writer, args: []const []const u8, i: *usize, name: []const u8) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len or args[i.*].len == 0) {
        try out.print("error: {s} requires a value\n", .{name});
        die(out, exit_config_error);
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
            .node = if (opts.report_capabilities)
                try buildNodeDescriptor(arena, env, opts)
            else
                null,
        },
    };
}

fn buildNodeDescriptor(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    opts: Options,
) !NodeDescriptor {
    const labels = try mergeCsv(arena, opts.labels, env.get("SCOOT_EDGE_LABELS"));
    const skills = try mergeCsv(arena, opts.skills, env.get("SCOOT_EDGE_SKILLS"));
    return nodeDescriptorFrom(labels, skills);
}

fn nodeDescriptorFrom(labels: []const []const u8, skills: []const []const u8) NodeDescriptor {
    return .{
        .labels = labels,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .capabilities = .{
            .max_job_policy = default_max_job_policy,
            .tools = &advisory_readonly_tools,
            .skills = skills,
        },
    };
}

/// Merges flag-provided values with an optional comma-separated env override,
/// trimming and dropping empties. The result is advisory routing metadata.
fn mergeCsv(arena: std.mem.Allocator, base: []const []const u8, csv: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (base) |b| {
        const t = std.mem.trim(u8, b, " \t");
        if (t.len != 0) try list.append(arena, t);
    }
    if (csv) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " \t");
            if (t.len != 0) try list.append(arena, t);
        }
    }
    return list.items;
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
        error.OutOfMemory => return error.OutOfMemory,
        // The child could not be spawned at all (most often the scoot binary is
        // not installed or not on PATH). Surface it as a clean collection error.
        else => return error.ChildSpawnFailed,
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
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (!allow_insecure_http or !std.mem.startsWith(u8, url, "http://")) return false;
    const host = urlHost(url) orelse return false;
    return isLoopbackHost(host);
}

fn urlHost(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[sep + 3 ..];
    if (rest.len == 0) return null;
    var auth_end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            auth_end = i;
            break;
        }
    }
    var authority = rest[0..auth_end];
    if (authority.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        return authority[1..close];
    }
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| return authority[0..colon];
    return authority;
}

fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.eqlIgnoreCase(host, "localhost.")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    var parts = std.mem.splitScalar(u8, host, '.');
    const first = parts.next() orelse return false;
    if (!std.mem.eql(u8, first, "127")) return false;
    var n: usize = 1;
    while (parts.next()) |part| {
        n += 1;
        if (part.len == 0 or part.len > 3) return false;
        var value: u16 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return false;
            value = value * 10 + (c - '0');
        }
        if (value > 255) return false;
    }
    return n == 4;
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

/// Sleeps up to `total_ms`, waking promptly when a stop signal arrives so a
/// supervised `run` shuts down within a slice instead of a whole interval.
fn interruptibleSleep(io: std.Io, total_ms: u64) void {
    if (comptime !stop_signals_supported) return sleepDeadline(io, total_ms);
    const slice_ms: u64 = 200;
    var remaining = total_ms;
    while (remaining != 0) {
        if (stopRequested()) return;
        const chunk = @min(remaining, slice_ms);
        sleepDeadline(io, chunk);
        remaining -= chunk;
    }
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

test "post-once requires HTTPS or explicitly insecure loopback URL" {
    try std.testing.expect(centerUrlAllowed("https://center.example/telemetry", false));
    try std.testing.expect(centerUrlAllowed("https://center.example/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("http://localhost:8080/telemetry", false));
    try std.testing.expect(centerUrlAllowed("http://localhost:8080/telemetry", true));
    try std.testing.expect(centerUrlAllowed("http://127.0.0.1:8080/telemetry", true));
    try std.testing.expect(centerUrlAllowed("http://[::1]:8080/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("http://center.example/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("http://10.0.0.5/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("ftp://center.example/telemetry", true));
}

test "backoffCeilingMs grows exponentially and clamps to the cap" {
    try std.testing.expectEqual(@as(u64, 1000), backoffCeilingMs(1, 1000, 60_000));
    try std.testing.expectEqual(@as(u64, 2000), backoffCeilingMs(2, 1000, 60_000));
    try std.testing.expectEqual(@as(u64, 4000), backoffCeilingMs(3, 1000, 60_000));
    try std.testing.expectEqual(@as(u64, 8000), backoffCeilingMs(4, 1000, 60_000));
    // Eventually clamps to the cap and never exceeds it.
    try std.testing.expectEqual(@as(u64, 60_000), backoffCeilingMs(20, 1000, 60_000));
    try std.testing.expectEqual(@as(u64, 60_000), backoffCeilingMs(1000, 1000, 60_000));
    // attempt 0 degrades to the (capped) base without underflowing.
    try std.testing.expectEqual(@as(u64, 1000), backoffCeilingMs(0, 1000, 60_000));
    // A base already above the cap is clamped immediately.
    try std.testing.expectEqual(@as(u64, 5000), backoffCeilingMs(3, 9999, 5000));
}

test "jitteredBackoffMs stays within [base, ceiling] for every attempt" {
    var prng = std.Random.DefaultPrng.init(0xED9E_5EED);
    const rand = prng.random();
    var attempt: u32 = 1;
    while (attempt <= 40) : (attempt += 1) {
        const ceiling = backoffCeilingMs(attempt, 1000, max_backoff_ms);
        var trial: usize = 0;
        while (trial < 64) : (trial += 1) {
            const wait = jitteredBackoffMs(rand, attempt, 1000);
            try std.testing.expect(wait >= @min(@as(u64, 1000), ceiling));
            try std.testing.expect(wait <= ceiling);
        }
    }
}

test "jitteredBackoffMs floors a zero/tiny base so failures never busy-spin" {
    var prng = std.Random.DefaultPrng.init(0xB16B_00B5);
    const rand = prng.random();
    // A 0 base (e.g. an un-normalized interval) must still back off, not spin.
    var attempt: u32 = 1;
    while (attempt <= 8) : (attempt += 1) {
        try std.testing.expect(jitteredBackoffMs(rand, attempt, 0) >= min_backoff_ms);
        try std.testing.expect(jitteredBackoffMs(rand, attempt, 1) >= min_backoff_ms);
    }
}

test "mergeCsv combines flags and env, trims, and drops empties" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = [_][]const u8{ "role:db", "  ", "env:prod" };
    const merged = try mergeCsv(arena, &base, " focus:log-triage , , extra ");
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try std.testing.expectEqualStrings("role:db", merged[0]);
    try std.testing.expectEqualStrings("env:prod", merged[1]);
    try std.testing.expectEqualStrings("focus:log-triage", merged[2]);
    try std.testing.expectEqualStrings("extra", merged[3]);

    const none = try mergeCsv(arena, &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "nodeDescriptorFrom is advisory: readonly ceiling, derived os/arch, declared tools" {
    const labels = [_][]const u8{"role:db"};
    const skills = [_][]const u8{"log-triage"};
    const node = nodeDescriptorFrom(&labels, &skills);
    try std.testing.expectEqualStrings("readonly", node.capabilities.max_job_policy);
    try std.testing.expect(node.os.len != 0);
    try std.testing.expect(node.arch.len != 0);
    try std.testing.expectEqualStrings("file_read", node.capabilities.tools[0]);
    try std.testing.expectEqualStrings("role:db", node.labels[0]);
    try std.testing.expectEqualStrings("log-triage", node.capabilities.skills[0]);
}

test "parseArgs accepts the run command with loop and capability flags" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;

    const args = [_][]const u8{
        "scoot-edge",                       "run",
        "--interval-ms",                    "1500",
        "--max-posts",                      "3",
        "--report-capabilities",            "--label",
        "role:db",                          "--skill",
        "log-triage",                       "--center-url",
        "https://center.example/telemetry",
    };
    const opts = try parseArgs(arena, out, &args);
    try std.testing.expectEqual(Command.run, opts.command);
    try std.testing.expectEqual(@as(u64, 1500), opts.interval_ms);
    try std.testing.expectEqual(@as(u64, 3), opts.max_posts);
    try std.testing.expect(opts.report_capabilities);
    try std.testing.expectEqual(@as(usize, 1), opts.labels.len);
    try std.testing.expectEqualStrings("role:db", opts.labels[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.skills.len);
    try std.testing.expectEqualStrings("log-triage", opts.skills[0]);
}

test "parseArgs normalizes --interval-ms 0 to the default interval" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;

    const args = [_][]const u8{ "scoot-edge", "run", "--interval-ms", "0" };
    const opts = try parseArgs(arena, out, &args);
    try std.testing.expectEqual(default_interval_ms, opts.interval_ms);
}

test {
    std.testing.refAllDecls(@This());
}
