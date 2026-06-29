//! Shared subprocess helpers for built-in tools.
//!
//! Tool and extension subprocesses must always have a hard timeout. A configured
//! timeout of 0 is treated by callers as "use the module default", never as
//! "run forever".
const std = @import("std");

pub fn effectiveTimeoutMs(timeout_ms: u64, default_timeout_ms: u64) u64 {
    return if (timeout_ms == 0) default_timeout_ms else timeout_ms;
}

const StdinWriteAttempt = union(enum) {
    ok: void,
    err: anyerror,
};

fn writeStreamingAll(io: std.Io, file: std.Io.File, input: []const u8) !void {
    file.writeStreamingAll(io, input) catch |err| switch (err) {
        // The child exited early or closed stdin. That is not itself a timeout;
        // callers can still read stdout/stderr and inspect the child exit status.
        error.BrokenPipe => {},
        else => return err,
    };
}

fn writeStreamingAllAttempt(io: std.Io, file: std.Io.File, input: []const u8) StdinWriteAttempt {
    writeStreamingAll(io, file, input) catch |err| return .{ .err = err };
    return .{ .ok = {} };
}

/// Writes a complete stdin payload under a hard deadline. If async task setup is
/// unavailable, fail closed instead of falling back to a potentially unbounded
/// blocking write.
pub fn writeStreamingAllWithTimeout(io: std.Io, file: std.Io.File, input: []const u8, timeout_ms: u64) !void {
    if (timeout_ms == 0) return error.TimeoutRequired;

    const Outcome = union(enum) { done: StdinWriteAttempt, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.done, writeStreamingAllAttempt, .{ io, file, input }) catch |err| return err;
    sel.concurrent(.timed_out, sleepDeadline, .{ io, timeout_ms }) catch |err| {
        sel.cancelDiscard();
        return err;
    };

    const winner = sel.await() catch |err| {
        sel.cancelDiscard();
        return err;
    };
    sel.cancelDiscard();
    return switch (winner) {
        .done => |r| switch (r) {
            .ok => {},
            .err => |err| err,
        },
        .timed_out => error.Timeout,
    };
}

fn sleepDeadline(io: std.Io, timeout_ms: u64) void {
    const d: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    };
    d.sleep(io) catch {};
}

test "effectiveTimeoutMs treats 0 as module default" {
    try std.testing.expectEqual(@as(u64, 30_000), effectiveTimeoutMs(0, 30_000));
    try std.testing.expectEqual(@as(u64, 5), effectiveTimeoutMs(5, 30_000));
}

test {
    std.testing.refAllDecls(@This());
}
