//! Opt-in PreToolUse-style policy hook (issue #136).
//!
//! After the built-in `guard()` checks allow a pending tool action, an optional
//! external hook may further restrict it. The hook reuses the same data-transform
//! plugin boundary as `wasm_tool.zig` and the compressor plugin (`manifest.toml`
//! + argv host template + realpath-validated package) rather than a raw
//! `/bin/sh` callout, so determinism and the small attack surface are preserved.
//!
//! Posture (deliberately one-directional and fail-closed):
//!   - The hook is consulted ONLY for actions the built-in policy already
//!     allowed. It can turn an `allow` into a `deny`, never relax a built-in
//!     `deny`. The caller (`agent.guard`) enforces this short-circuit.
//!   - Any operational failure — missing/invalid package, wrong kind, non-compute
//!     capability, spawn failure, timeout, non-zero exit, oversized or malformed
//!     output — is treated as `deny`, consistent with `Mode.fromString` falling
//!     back to `guarded`.
const std = @import("std");
const policy = @import("policy.zig");
const wasm_tool = @import("wasm_tool.zig");
const jsonio = @import("jsonio.zig");
const proc = @import("tools/proc.zig");

pub const default_timeout_ms: u64 = 30_000;
pub const manifest_kind = "policy";

/// Trusted runtime configuration for the policy hook. `package` is a local Wasm
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

/// The pending decision context handed to the hook. All fields are caller-owned
/// and only read.
pub const Context = struct {
    action: []const u8,
    input: []const u8,
    mode: []const u8,
    cwd: []const u8,
};

const HookResponse = struct {
    decision: []const u8 = "",
    reason: []const u8 = "",
};

const RunResult = struct {
    stdout: []const u8,
    stderr: []const u8,
};

/// Consults the configured hook for an already-allowed action. Returns `.allow`
/// only when the hook explicitly allows; every other path (including all errors)
/// returns `.deny`. The returned reason is static or arena-owned.
pub fn consult(arena: std.mem.Allocator, io: std.Io, cfg: HookConfig, ctx: Context) policy.Decision {
    return evaluate(arena, io, cfg, ctx) catch |err| .{ .deny = reasonForError(err) };
}

fn evaluate(arena: std.mem.Allocator, io: std.Io, cfg: HookConfig, ctx: Context) !policy.Decision {
    if (cfg.package.len == 0) return error.HookMissingPackage;

    const validation = try wasm_tool.validatePackage(arena, io, cfg.package);
    const summary = switch (validation) {
        .valid => |s| s,
        .invalid => return error.HookInvalidPackage,
    };
    if (!std.mem.eql(u8, summary.kind, manifest_kind)) return error.HookWrongKind;
    try requireComputeOnly(summary);

    const request = try buildRequest(arena, ctx);
    const argv = try buildArgv(arena, cfg, summary);
    const result = try runHook(arena, io, argv, request, cfg);
    return try parseResponse(arena, result.stdout);
}

/// A policy hook is a pure data transform, so its declared policy capabilities
/// must be exactly `compute`. Any network/filesystem/etc. grant is rejected.
fn requireComputeOnly(summary: wasm_tool.Summary) !void {
    if (summary.policy_capabilities.len == 0) return error.HookPolicyDenied;
    for (summary.policy_capabilities) |cap| {
        if (!std.mem.eql(u8, cap, "compute")) return error.HookPolicyDenied;
    }
}

fn buildRequest(arena: std.mem.Allocator, ctx: Context) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"version\":1,\"kind\":\"policy\",\"action\":");
    try jsonio.writeString(w, ctx.action);
    try w.writeAll(",\"input\":");
    try jsonio.writeString(w, ctx.input);
    try w.writeAll(",\"mode\":");
    try jsonio.writeString(w, ctx.mode);
    try w.writeAll(",\"cwd\":");
    try jsonio.writeString(w, ctx.cwd);
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

/// Parses the hook's stdout. Only an explicit `{"decision":"allow"}` allows;
/// `{"decision":"deny","reason":...}` denies with the reason; anything else
/// (unknown decision, missing field, malformed JSON) fails closed to deny.
fn parseResponse(arena: std.mem.Allocator, stdout: []const u8) !policy.Decision {
    const json = jsonio.firstJsonObject(stdout) orelse return error.HookMalformedOutput;
    const resp = std.json.parseFromSliceLeaky(HookResponse, arena, json, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HookMalformedOutput,
    };
    if (std.mem.eql(u8, resp.decision, "allow")) return .allow;
    if (std.mem.eql(u8, resp.decision, "deny")) {
        const reason = std.mem.trim(u8, resp.reason, " \t\r\n");
        if (reason.len == 0) return .{ .deny = "policy hook denied the action" };
        return .{ .deny = try std.fmt.allocPrint(arena, "policy hook: {s}", .{reason}) };
    }
    return error.HookMalformedOutput;
}

fn reasonForError(err: anyerror) []const u8 {
    return switch (err) {
        error.HookMissingPackage => "policy hook: package is not configured",
        error.HookInvalidPackage => "policy hook: package failed manifest/policy/schema/component validation",
        error.HookWrongKind => "policy hook: package manifest kind must be \"policy\"",
        error.HookPolicyDenied => "policy hook: package policy must grant only the compute capability",
        error.HookMissingHost => "policy hook: host argv is empty",
        error.HookWriteFailed => "policy hook: failed to send the request to the hook",
        error.Timeout => "policy hook: timed out (fail-closed deny)",
        error.HookOutputTooLarge => "policy hook: output exceeded the configured limit",
        error.HookFailed => "policy hook: exited non-zero or was killed (fail-closed deny)",
        error.HookMalformedOutput => "policy hook: output was not a valid allow/deny decision",
        error.OutOfMemory => "policy hook: out of memory while evaluating (fail-closed deny)",
        else => "policy hook: evaluation failed (fail-closed deny)",
    };
}

test "parseResponse: explicit allow" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(policy.Decision.allow, try parseResponse(a, "{\"decision\":\"allow\"}\n"));
}

test "parseResponse: deny carries the reason" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try parseResponse(a, "{\"decision\":\"deny\",\"reason\":\"org denylist\"}");
    switch (d) {
        .deny => |r| try std.testing.expect(std.mem.indexOf(u8, r, "org denylist") != null),
        .allow => return error.ExpectedDeny,
    }
}

test "parseResponse: unknown decision and garbage fail closed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.HookMalformedOutput, parseResponse(a, "{\"decision\":\"maybe\"}"));
    try std.testing.expectError(error.HookMalformedOutput, parseResponse(a, "not json"));
    try std.testing.expectError(error.HookMalformedOutput, parseResponse(a, "{\"decision\":\"deny\""));
}

test "consult: unconfigured package denies fail-closed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = consult(a, std.testing.io, .{}, .{ .action = "bash", .input = "ls", .mode = "guarded", .cwd = "." });
    try std.testing.expect(d == .deny);
}

test {
    std.testing.refAllDecls(@This());
}
