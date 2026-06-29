//! Wasm tool runner: validates a local Wasm tool package and executes it
//! through a configured host argv without going through `/bin/sh -c`.
const std = @import("std");
const proc = @import("proc.zig");
const wasm_tool = @import("../wasm_tool.zig");
const Result = @import("tools.zig").Result;

pub const default_host = &.{ "scoot-wasm", "wasi", "{component}" };
pub const default_timeout_ms: u64 = 30_000;

pub const Options = struct {
    host: []const []const u8 = default_host,
    timeout_ms: u64 = default_timeout_ms,
    stdout_limit: usize = 1 << 20,
    stderr_limit: usize = 256 * 1024,
};

pub fn validateComputePackage(
    arena: std.mem.Allocator,
    io: std.Io,
    package: []const u8,
) !wasm_tool.Summary {
    const validation = try wasm_tool.validatePackage(arena, io, package);
    const summary = switch (validation) {
        .valid => |s| s,
        .invalid => return error.WasmToolInvalidPackage,
    };
    if (!std.mem.eql(u8, summary.entry, "_start")) return error.WasmToolUnsupportedEntry;
    if (summary.policy_capabilities.len == 0) return error.WasmToolPolicyDenied;
    for (summary.policy_capabilities) |cap| {
        if (!std.mem.eql(u8, cap, "compute")) return error.WasmToolPolicyDenied;
    }
    return summary;
}

pub fn safePackagePath(path: []const u8) bool {
    const p = std.mem.trim(u8, path, " \t\r\n");
    if (p.len == 0) return false;
    if (std.fs.path.isAbsolute(p)) return false;
    if (p[0] == '~' or std.mem.indexOfScalar(u8, p, '$') != null) return false;
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    var saw_segment = false;
    while (it.next()) |part| {
        saw_segment = true;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return saw_segment;
}

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    package: []const u8,
    stdin: []const u8,
    opts: Options,
) !Result {
    const summary = try validateComputePackage(arena, io, package);
    const argv = try hostArgv(arena, opts.host, package, summary);
    return runHost(arena, io, argv, stdin, opts);
}

fn hostArgv(
    arena: std.mem.Allocator,
    host: []const []const u8,
    package: []const u8,
    summary: wasm_tool.Summary,
) ![]const []const u8 {
    if (host.len == 0) return error.WasmToolMissingHost;
    const component = try std.fs.path.join(arena, &.{ package, summary.component });
    var argv: std.ArrayList([]const u8) = .empty;
    for (host) |arg| {
        try argv.append(arena, try expandHostArg(arena, arg, package, summary.entry, component));
    }
    return argv.items;
}

fn expandHostArg(
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

fn runHost(
    arena: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    stdin: []const u8,
    opts: Options,
) !Result {
    if (argv.len == 0 or argv[0].len == 0) return error.WasmToolMissingHost;

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    const effective_timeout_ms = proc.effectiveTimeoutMs(opts.timeout_ms, default_timeout_ms);
    proc.writeStreamingAllWithTimeout(io, child.stdin.?, stdin, effective_timeout_ms) catch |err| switch (err) {
        error.Timeout => return .{ .timed_out = true },
        else => return error.WasmToolWriteFailed,
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
        if (opts.stdout_limit != 0 and stdout_reader.buffered().len > opts.stdout_limit)
            return error.WasmToolOutputTooLarge;
        if (opts.stderr_limit != 0 and stderr_reader.buffered().len > opts.stderr_limit)
            return error.WasmToolOutputTooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return .{ .timed_out = true },
        else => |e| return e,
    }
    try multi_reader.checkAnyError();
    const term = child.wait(io) catch return error.WasmToolFailed;
    return .{
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
        .exit_code = termToCode(term),
    };
}

fn deadline(io: std.Io, timeout_ms: u64) std.Io.Timeout {
    const base: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
    } };
    return base.toDeadline(io);
}

fn termToCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        else => -1,
    };
}

test "safePackagePath rejects shell-like and escaping paths" {
    try std.testing.expect(safePackagePath("examples/wasm-plugin-template"));
    try std.testing.expect(!safePackagePath(""));
    try std.testing.expect(!safePackagePath("/tmp/tool"));
    try std.testing.expect(!safePackagePath("../tool"));
    try std.testing.expect(!safePackagePath("~/tool"));
    try std.testing.expect(!safePackagePath("$HOME/tool"));
}

test "runHost bounds stdin writes when child does not drain" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try arena.alloc(u8, 8 * 1024 * 1024);
    @memset(input, 'x');

    const result = try runHost(arena, std.testing.io, &.{ "/bin/sh", "-c", "sleep 5" }, input, .{ .timeout_ms = 200 });
    try std.testing.expect(result.timed_out);
}

test {
    std.testing.refAllDecls(@This());
}
