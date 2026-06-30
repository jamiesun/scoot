//! Opt-in PostToolUse-style audit/observability hook (issue #137).
//!
//! After a tool action completes (allowed-and-executed, or denied by the policy
//! gate), an optional external hook may receive a structured event for an
//! external SIEM, analytics pipeline, or org audit engine. Like the PreToolUse
//! policy hook (`policy_hook.zig`), it reuses the same data-transform plugin
//! boundary as `wasm_tool.zig` and the compressor plugin (`manifest.toml` +
//! argv host template + realpath-validated package) rather than a raw
//! `/bin/sh` callout, so determinism and the small attack surface are preserved.
//!
//! Posture (deliberately observational and best-effort):
//!   - The hook is purely observational: it never gates execution and has no
//!     allow/deny return. Gating belongs to the PreToolUse policy hook (#136).
//!   - It fires AFTER the action, so it cannot change what already happened.
//!   - Delivery is best-effort, matching `audit.Logger` semantics where a write
//!     failure never blocks the task: any failure (missing/invalid package,
//!     wrong kind, non-compute capability, spawn failure, timeout, oversized
//!     output, non-zero exit) is counted and surfaced at flush, never fatal.
//!
//! Event schema (stable, reuses `audit.zig` field names; one JSON object + `\n`):
//!   {"version":1,"kind":"observation","session_id":"cli-...","action":"bash",
//!    "input":"<tool input>","observation":"<tool result>","mode":"guarded"}
//! `kind` is an `audit.EventKind` tag (`observation` for an executed tool,
//! `policy_deny` for a gated one). `session_id`/`kind` mirror the audit JSONL
//! shape; `action`/`input`/`observation`/`mode` add the PostToolUse context.
const std = @import("std");
const audit = @import("audit.zig");
const wasm_tool = @import("wasm_tool.zig");
const jsonio = @import("jsonio.zig");
const proc = @import("tools/proc.zig");

pub const default_timeout_ms: u64 = 30_000;
pub const manifest_kind = "audit";

/// Trusted runtime configuration for the audit hook. `package` is a local Wasm
/// tool package directory; `host` is the argv template ({package}/{entry}/
/// {component}) used to launch the data-transform sandbox. Empty `package`
/// means no hook is configured.
pub const HookConfig = struct {
    package: []const u8 = "",
    host: []const []const u8 = &.{},
    timeout_ms: u64 = default_timeout_ms,
    stdout_limit: usize = 1 << 20,
    stderr_limit: usize = 256 * 1024,

    pub fn enabled(self: HookConfig) bool {
        return self.package.len != 0;
    }
};

/// One completed-tool event handed to the hook. All fields are caller-owned and
/// only read; they are turn-arena lifetime and must not be retained.
pub const Event = struct {
    kind: audit.EventKind,
    session_id: []const u8,
    action: []const u8,
    input: []const u8,
    observation: []const u8,
    mode: []const u8,
};

/// Run-scoped, best-effort delivery sink. `post` swallows every error into the
/// failure counter so a misbehaving hook can never abort the agent; callers
/// inspect `hadFailures`/`lastErrorReason` at flush to surface problems.
pub const Sink = struct {
    cfg: HookConfig,
    io: std.Io,
    delivered: u64 = 0,
    failed: u64 = 0,
    last_error: ?anyerror = null,

    /// Delivers one event. No-op when unconfigured (no spawn). Any failure is
    /// recorded and surfaced at flush, never propagated to the run.
    pub fn post(self: *Sink, arena: std.mem.Allocator, ev: Event) void {
        if (!self.cfg.enabled()) return;
        deliver(arena, self.io, self.cfg, ev) catch |err| {
            self.failed += 1;
            self.last_error = err;
            return;
        };
        self.delivered += 1;
    }

    pub fn hadFailures(self: Sink) bool {
        return self.failed != 0;
    }

    /// Human-readable reason for the most recent delivery failure, or "" if none.
    pub fn lastErrorReason(self: Sink) []const u8 {
        return if (self.last_error) |err| reasonForError(err) else "";
    }
};

const RunResult = struct {
    stdout: []const u8,
    stderr: []const u8,
};

fn deliver(arena: std.mem.Allocator, io: std.Io, cfg: HookConfig, ev: Event) !void {
    if (cfg.package.len == 0) return error.HookMissingPackage;

    const validation = try wasm_tool.validatePackage(arena, io, cfg.package);
    const summary = switch (validation) {
        .valid => |s| s,
        .invalid => return error.HookInvalidPackage,
    };
    if (!std.mem.eql(u8, summary.kind, manifest_kind)) return error.HookWrongKind;
    try requireComputeOnly(summary);

    const request = try buildRequest(arena, ev);
    const argv = try buildArgv(arena, cfg, summary);
    // Stdout/stderr are intentionally discarded: the hook is observational and
    // returns no decision. Only spawn success and a zero exit confirm delivery.
    _ = try runHook(arena, io, argv, request, cfg);
}

/// An audit hook is a pure data transform, so its declared policy capabilities
/// must be exactly `compute`. Any network/filesystem/etc. grant is rejected, so
/// the hook cannot become an ambient-authority exfiltration path.
fn requireComputeOnly(summary: wasm_tool.Summary) !void {
    if (summary.policy_capabilities.len == 0) return error.HookPolicyDenied;
    for (summary.policy_capabilities) |cap| {
        if (!std.mem.eql(u8, cap, "compute")) return error.HookPolicyDenied;
    }
}

fn buildRequest(arena: std.mem.Allocator, ev: Event) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"version\":1,\"kind\":\"");
    try w.writeAll(@tagName(ev.kind));
    try w.writeAll("\",\"session_id\":");
    try jsonio.writeString(w, ev.session_id);
    try w.writeAll(",\"action\":");
    try jsonio.writeString(w, ev.action);
    try w.writeAll(",\"input\":");
    try jsonio.writeString(w, ev.input);
    try w.writeAll(",\"observation\":");
    try jsonio.writeString(w, ev.observation);
    try w.writeAll(",\"mode\":");
    try jsonio.writeString(w, ev.mode);
    try w.writeAll("}\n");
    return aw.written();
}

fn buildArgv(arena: std.mem.Allocator, cfg: HookConfig, summary: wasm_tool.Summary) ![]const []const u8 {
    if (cfg.host.len == 0) {
        const exe = try std.fs.path.join(arena, &.{ cfg.package, summary.entry });
        return try arena.dupe([]const u8, &.{exe});
    }
    var argv: std.ArrayList([]const u8) = .empty;
    const component = try std.fs.path.join(arena, &.{ cfg.package, summary.component });
    for (cfg.host) |arg| {
        try argv.append(arena, try expandArg(arena, arg, cfg.package, summary.entry, component));
    }
    return argv.items;
}

fn expandArg(
    arena: std.mem.Allocator,
    arg: []const u8,
    package: []const u8,
    entry: []const u8,
    component: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < arg.len) {
        const rest = arg[i..];
        if (std.mem.startsWith(u8, rest, "{package}")) {
            try out.appendSlice(arena, package);
            i += "{package}".len;
        } else if (std.mem.startsWith(u8, rest, "{entry}")) {
            try out.appendSlice(arena, entry);
            i += "{entry}".len;
        } else if (std.mem.startsWith(u8, rest, "{component}")) {
            try out.appendSlice(arena, component);
            i += "{component}".len;
        } else {
            try out.append(arena, arg[i]);
            i += 1;
        }
    }
    return out.items;
}

fn runHook(
    arena: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    stdin: []const u8,
    cfg: HookConfig,
) !RunResult {
    if (argv.len == 0 or argv[0].len == 0) return error.HookMissingHost;

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    const effective_timeout_ms = proc.effectiveTimeoutMs(cfg.timeout_ms, default_timeout_ms);
    proc.writeStreamingAllWithTimeout(io, child.stdin.?, stdin, effective_timeout_ms) catch |err| switch (err) {
        error.Timeout => return error.Timeout,
        else => return error.HookWriteFailed,
    };
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(arena, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const timeout = deadline(io, effective_timeout_ms);
    while (multi_reader.fill(64, timeout)) |_| {
        if (cfg.stdout_limit != 0 and stdout_reader.buffered().len > cfg.stdout_limit)
            return error.HookOutputTooLarge;
        if (cfg.stderr_limit != 0 and stderr_reader.buffered().len > cfg.stderr_limit)
            return error.HookOutputTooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return error.Timeout,
        else => |e| return e,
    }
    try multi_reader.checkAnyError();
    const term = child.wait(io) catch return error.HookFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.HookFailed,
        else => return error.HookFailed,
    }
    return .{
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
    };
}

fn deadline(io: std.Io, timeout_ms: u64) std.Io.Timeout {
    const base: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
    } };
    return base.toDeadline(io);
}

fn reasonForError(err: anyerror) []const u8 {
    return switch (err) {
        error.HookMissingPackage => "audit hook: package is not configured",
        error.HookInvalidPackage => "audit hook: package failed manifest/policy/schema/component validation",
        error.HookWrongKind => "audit hook: package manifest kind must be \"audit\"",
        error.HookPolicyDenied => "audit hook: package policy must grant only the compute capability",
        error.HookMissingHost => "audit hook: host argv is empty",
        error.HookWriteFailed => "audit hook: failed to send the event to the hook",
        error.Timeout => "audit hook: timed out (event dropped)",
        error.HookOutputTooLarge => "audit hook: output exceeded the configured limit",
        error.HookFailed => "audit hook: exited non-zero or was killed (event dropped)",
        error.OutOfMemory => "audit hook: out of memory while delivering (event dropped)",
        else => "audit hook: delivery failed (event dropped)",
    };
}

test "buildRequest emits a stable, escaped JSON schema reusing audit fields" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const req = try buildRequest(a, .{
        .kind = .observation,
        .session_id = "cli-1",
        .action = "bash",
        .input = "echo \"hi\"",
        .observation = "hi\nthere",
        .mode = "guarded",
    });

    // The payload must be one parseable JSON object (newlines/quotes escaped).
    const Line = struct {
        version: u32,
        kind: []const u8,
        session_id: []const u8,
        action: []const u8,
        input: []const u8,
        observation: []const u8,
        mode: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Line, a, std.mem.trim(u8, req, "\n"), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqualStrings("observation", parsed.value.kind);
    try std.testing.expectEqualStrings("cli-1", parsed.value.session_id);
    try std.testing.expectEqualStrings("bash", parsed.value.action);
    try std.testing.expectEqualStrings("echo \"hi\"", parsed.value.input);
    try std.testing.expectEqualStrings("hi\nthere", parsed.value.observation);
    try std.testing.expectEqualStrings("guarded", parsed.value.mode);
}

test "Sink: unconfigured sink is a no-op with no failures" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var sink: Sink = .{ .cfg = .{}, .io = std.testing.io };
    sink.post(arena_state.allocator(), .{
        .kind = .observation,
        .session_id = "s",
        .action = "bash",
        .input = "ls",
        .observation = "ok",
        .mode = "guarded",
    });
    try std.testing.expectEqual(@as(u64, 0), sink.delivered);
    try std.testing.expectEqual(@as(u64, 0), sink.failed);
    try std.testing.expect(!sink.hadFailures());
}

test "Sink: a missing package is non-fatal and surfaced at flush" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    // Configured but pointing at a non-existent package: delivery must fail
    // without panicking, increment the failure counter, and record a reason.
    var sink: Sink = .{ .cfg = .{ .package = "/nonexistent/scoot-audit-hook" }, .io = std.testing.io };
    sink.post(arena_state.allocator(), .{
        .kind = .policy_deny,
        .session_id = "s",
        .action = "bash",
        .input = "rm -rf /",
        .observation = "denied",
        .mode = "guarded",
    });
    try std.testing.expectEqual(@as(u64, 0), sink.delivered);
    try std.testing.expectEqual(@as(u64, 1), sink.failed);
    try std.testing.expect(sink.hadFailures());
    try std.testing.expect(sink.lastErrorReason().len != 0);
}

test {
    std.testing.refAllDecls(@This());
}
