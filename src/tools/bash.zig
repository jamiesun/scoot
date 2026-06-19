//! Bash tool: runs shell commands in subprocesses with hard timeout and output
//! limits. `std.process.run` provides the timeout; this module converts it to
//! an absolute deadline. On timeout, `error.Timeout` is returned and the child
//! is force-killed, so one command cannot stall the main loop.
const std = @import("std");
const Result = @import("tools.zig").Result;

/// Bash execution options. Defaults are sandbox guardrails: bounded time and output.
pub const Options = struct {
    /// Hard timeout in milliseconds. 0 disables it, which is not recommended.
    timeout_ms: u64 = 30_000,
    /// Stdout byte limit; exceeding it terminates with an error.
    stdout_limit: usize = 1 << 20,
    /// Stderr byte limit.
    stderr_limit: usize = 1 << 20,
    /// Working directory; null inherits the current process cwd.
    cwd: ?[]const u8 = null,
};

/// Runs one shell command and returns a unified result. On success, `stdout` and
/// `stderr` are owned by `gpa`. Forced timeouts return
/// `Result{ .timed_out = true }` with no stdout/stderr ownership. Output-limit
/// failures use `exit_code = -1`. Real lower-level I/O failures propagate.
pub fn run(gpa: std.mem.Allocator, io: std.Io, command: []const u8, opts: Options) !Result {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };

    // Convert to an absolute deadline so every read in std.process.run shares
    // the same wall-clock cap. Use the .awake monotonic clock so clock changes
    // cannot disable the timeout.
    const timeout: std.Io.Timeout = if (opts.timeout_ms == 0) blk: {
        break :blk .none;
    } else blk: {
        const base: std.Io.Timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromMilliseconds(@intCast(opts.timeout_ms)),
        } };
        break :blk base.toDeadline(io);
    };

    const cwd: std.process.Child.Cwd = if (opts.cwd) |p| .{ .path = p } else .inherit;

    const res = std.process.run(gpa, io, .{
        .argv = &argv,
        .timeout = timeout,
        .stdout_limit = .limited(opts.stdout_limit),
        .stderr_limit = .limited(opts.stderr_limit),
        .cwd = cwd,
    }) catch |err| switch (err) {
        error.Timeout => return .{ .timed_out = true },
        error.StreamTooLong => return .{ .exit_code = -1, .stderr = "[scoot] command output exceeded the limit and was terminated" },
        else => return err,
    };

    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = termToCode(res.term),
    };
}

/// Maps child termination to an integer exit code. Normal exits keep their code;
/// signal termination, stop, and unknown cases collapse to -1 because signal
/// numbers vary by platform and only the abnormal-exit meaning is exposed.
fn termToCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        else => -1,
    };
}

test "bash: normal command returns exit_code" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, "printf 'hi world'", .{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqualStrings("hi world", r.stdout);
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
    try std.testing.expect(!r.timed_out);
}

test "bash: failed command returns nonzero exit_code" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, "exit 3", .{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 3), r.exit_code);
    try std.testing.expect(!r.timed_out);
}

test "bash: hard timeout force-terminates and returns quickly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    // sleep 5 far exceeds the 200ms deadline and should be force-terminated.
    const r = try run(gpa, io, "sleep 5", .{ .timeout_ms = 200 });
    const elapsed_ms = start.untilNow(io).raw.toMilliseconds();
    try std.testing.expect(r.timed_out);
    try std.testing.expect(elapsed_ms < 3000); // Much earlier than sleep's 5s.
    // Timeout results return string literals, so there is no ownership to free.
}

test {
    std.testing.refAllDecls(@This());
}
